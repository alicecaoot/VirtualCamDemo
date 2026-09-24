/*
 * MyFirstTweak — iOS 进程内摄像头链路替换（自有 App / 指定 Bundle）
 *
 * ========== 覆盖范围（打包前确认）==========
 *
 * 已覆盖（AVFoundation 常规相机 App）：
 *   [P] AVCaptureVideoPreviewLayer     预览画面 → IOSurface overlay
 *   [V] AVCaptureVideoDataOutput       实时帧回调 → 改 CMSampleBuffer 像素
 *   [S] AVCaptureSession start/stop    启停与 feeder 模式
 *   [H] AVCapturePhotoOutput           拍照 JPEG/HEIF 前替换 pixelBuffer
 *   [H] AVCaptureStillImageOutput      旧版拍照 completion 替换
 *   [C] 单一时钟：有 DataOutput 时 sample 驱动读帧；预览与帧同 gen
 *   [B] 双缓冲 IOSurface，防撕裂
 *
 * 未覆盖 / 有限（不是「系统级全局摄像头驱动替换」）：
 *   - 未越狱：无法注入其它 App；本仓库 IPA 仅演示 App 内嵌虚拟预览
 *   - 系统 Camera.app / 其它进程：需把 Bundle ID 写入 plist Filter
 *   - AVCaptureMovieFileOutput 直接写文件：未改封装器（帧若经 DataOutput 仍可假）
 *   - ReplayKit / WebRTC 自研采集 / Metal 直接读 camera texture：需另接 hook
 *   - UIImagePickerController 系统 UI：部分版本走扩展进程，本 tweak 注入不到
 *   - 内核 / mediad 级替换：越狱内核模块范畴，本项目不做
 *
 * 结论：在「已注入的目标 App」里，对 Preview + VideoDataOutput + Photo 可较全面替换；
 * 不是 iOS 全局所有 App 的摄像头都被替换。
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurfaceRef.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <os/log.h>
#import <stdatomic.h>

#import "video_to_iosurface.h"

#pragma mark - Config

static NSString *const kMFTVideoFileName = @"demo.mp4";

typedef NS_ENUM(NSInteger, MFTClockSource) {
	MFTClockSourceCamera = 0,
	MFTClockSourceFreeRun = 1,
};

static MFTClockSource kMFTClockSource = MFTClockSourceCamera;
static const BOOL kMFTReplacePreviewLayer = YES;
static const BOOL kMFTReplaceSampleBuffer = YES;
static const BOOL kMFTReplacePhotoCapture = YES;
static const int kMFTBufferCount = 2;

static const void *kMFTDriverKey = &kMFTDriverKey;
static const void *kMFTShimKey = &kMFTShimKey;
static const void *kMFTPhotoShimKey = &kMFTPhotoShimKey;

#pragma mark - Log

static os_log_t MFTLog(void) {
	static os_log_t log;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		log = os_log_create("com.yourname.myfirsttweak", "camera");
	});
	return log;
}

#pragma mark - Forward decls

@class MFTPreviewDriver;
static void MFTRegisterPreviewDriver(MFTPreviewDriver *driver);
static void MFTUnregisterPreviewDriver(MFTPreviewDriver *driver);
static void MFTPublishFrontToAllPreviews(void);
static BOOL MFTEnsurePipeline(void);
static BOOL MFTAdvanceOneVideoFrame(void);
static IOSurfaceRef MFTCopyFrontSurface(uint64_t *out_gen);
static void MFTStartFreeRunFeeder(void);
static void MFTStopFreeRunFeeder(void);
static void MFTEvaluateFeederMode(void);
static void MFTRefreshAllDisplayLinkState(void);
static BOOL MFTRenderSurfaceToPixelBuffer(IOSurfaceRef src, CVPixelBufferRef dst);
static void MFTOnCameraSample(CMSampleBufferRef sampleBuffer);
static void MFTPaintExistingSampleOnly(CMSampleBufferRef sampleBuffer);

#pragma mark - Frame store

typedef struct {
	IOSurfaceRef surfaces[kMFTBufferCount];
	atomic_int front;
	atomic_uint_fast64_t gen;
	int width;
	int height;
	BOOL ready;
} MFTFrameStore;

static os_unfair_lock g_store_lock = OS_UNFAIR_LOCK_INIT;
static MFTFrameStore g_store;
static VTIContext *g_vti = NULL;
static dispatch_queue_t g_frame_queue;
static atomic_bool g_freerun_running = false;
static atomic_bool g_session_running = false;
static atomic_bool g_has_data_output = false;

static NSString *MFTResolveVideoPath(void) {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSMutableArray<NSString *> *candidates = [NSMutableArray array];

	/* 1) App 偏好里自定义路径 */
	NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:@"MFTVideoPath"];
	if (custom.length) {
		[candidates addObject:custom];
	}

	/* 2) Documents / Caches / tmp */
	NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
	NSString *tmp = NSTemporaryDirectory();
	if (doc) {
		[candidates addObject:[doc stringByAppendingPathComponent:kMFTVideoFileName]];
		[candidates addObject:[doc stringByAppendingPathComponent:@"virtual.mp4"]];
	}
	if (caches) {
		[candidates addObject:[caches stringByAppendingPathComponent:kMFTVideoFileName]];
	}
	if (tmp) {
		[candidates addObject:[tmp stringByAppendingPathComponent:kMFTVideoFileName]];
	}

	/* 3) Bundle */
	NSString *bundled = [[NSBundle mainBundle] pathForResource:@"demo" ofType:@"mp4"];
	if (bundled) {
		[candidates addObject:bundled];
	}
	bundled = [[NSBundle mainBundle] pathForResource:@"virtual" ofType:@"mp4"];
	if (bundled) {
		[candidates addObject:bundled];
	}

	/* 4) 共享媒体目录（越狱设备常见，需进程有读权限） */
	[candidates addObject:[@"/var/mobile/Media/Downloads" stringByAppendingPathComponent:kMFTVideoFileName]];
	[candidates addObject:[@"/var/mobile/Documents" stringByAppendingPathComponent:kMFTVideoFileName]];

	for (NSString *path in candidates) {
		if ([fm fileExistsAtPath:path]) {
			os_log(MFTLog(), "video path hit: %{public}@", path);
			return path;
		}
	}
	return candidates.firstObject ?: kMFTVideoFileName;
}

static void MFTFrameStoreResetUnlocked(void) {
	for (int i = 0; i < kMFTBufferCount; i++) {
		if (g_store.surfaces[i]) {
			CFRelease(g_store.surfaces[i]);
			g_store.surfaces[i] = NULL;
		}
	}
	atomic_store(&g_store.front, 0);
	atomic_store(&g_store.gen, 0);
	g_store.width = 0;
	g_store.height = 0;
	g_store.ready = NO;
}

static BOOL MFTEnsurePipelineUnlocked(void) {
	if (g_store.ready && g_vti) {
		return YES;
	}
	MFTFrameStoreResetUnlocked();
	if (g_vti) {
		vti_close(g_vti);
		g_vti = NULL;
	}

	NSString *path = MFTResolveVideoPath();
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		os_log_error(MFTLog(), "no video file. tried resolve → %{public}@", path);
		return NO;
	}

	VTIContext *vti = vti_open(path.fileSystemRepresentation, true);
	if (!vti) {
		os_log_error(MFTLog(), "vti_open failed: %{public}@", path);
		return NO;
	}

	int w = vti_width(vti);
	int h = vti_height(vti);
	if (w <= 0 || h <= 0) {
		vti_close(vti);
		return NO;
	}

	for (int i = 0; i < kMFTBufferCount; i++) {
		IOSurfaceRef s = isb_create(w, h, false);
		if (!s) {
			MFTFrameStoreResetUnlocked();
			vti_close(vti);
			return NO;
		}
		g_store.surfaces[i] = s;
	}

	g_vti = vti;
	g_store.width = w;
	g_store.height = h;
	g_store.ready = YES;
	atomic_store(&g_store.front, 0);
	atomic_store(&g_store.gen, 0);
	os_log(MFTLog(), "pipeline ready %{public}@ %dx%d", path, w, h);
	return YES;
}

static BOOL MFTEnsurePipeline(void) {
	os_unfair_lock_lock(&g_store_lock);
	BOOL ok = MFTEnsurePipelineUnlocked();
	os_unfair_lock_unlock(&g_store_lock);
	return ok;
}

static IOSurfaceRef MFTCopyFrontSurface(uint64_t *out_gen) {
	os_unfair_lock_lock(&g_store_lock);
	if (!g_store.ready || atomic_load(&g_store.gen) == 0) {
		os_unfair_lock_unlock(&g_store_lock);
		if (out_gen) {
			*out_gen = 0;
		}
		return NULL;
	}
	uint64_t gen = atomic_load(&g_store.gen);
	int idx = atomic_load(&g_store.front);
	if (idx < 0 || idx >= kMFTBufferCount) {
		idx = 0;
	}
	IOSurfaceRef s = g_store.surfaces[idx];
	if (s) {
		CFRetain(s);
	}
	os_unfair_lock_unlock(&g_store_lock);
	if (out_gen) {
		*out_gen = gen;
	}
	return s;
}

static BOOL MFTAdvanceOneVideoFrame(void) {
	os_unfair_lock_lock(&g_store_lock);
	if (!MFTEnsurePipelineUnlocked()) {
		os_unfair_lock_unlock(&g_store_lock);
		return NO;
	}
	VTIContext *vti = g_vti;
	int front = atomic_load(&g_store.front);
	int back = (front + 1) % kMFTBufferCount;
	IOSurfaceRef backSurf = g_store.surfaces[back];
	if (backSurf) {
		CFRetain(backSurf);
	}
	os_unfair_lock_unlock(&g_store_lock);

	if (!vti || !backSurf) {
		if (backSurf) {
			CFRelease(backSurf);
		}
		return NO;
	}

	bool eof = false;
	bool ok = vti_copy_next_frame(vti, backSurf, &eof);
	CFRelease(backSurf);
	if (!ok) {
		return NO;
	}
	atomic_store(&g_store.front, back);
	atomic_fetch_add(&g_store.gen, 1);
	return YES;
}

#pragma mark - CI

static CIContext *MFTCIContext(void) {
	static CIContext *ctx;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		ctx = [CIContext contextWithOptions:@{
			(__bridge NSString *)kCIContextWorkingColorSpace : [NSNull null],
			(__bridge NSString *)kCIContextCacheIntermediates : @NO,
		}];
	});
	return ctx;
}

static BOOL MFTRenderSurfaceToPixelBuffer(IOSurfaceRef src, CVPixelBufferRef dst) {
	if (!src || !dst) {
		return NO;
	}
	size_t dw = CVPixelBufferGetWidth(dst);
	size_t dh = CVPixelBufferGetHeight(dst);
	size_t sw = IOSurfaceGetWidth(src);
	size_t sh = IOSurfaceGetHeight(src);
	if (!dw || !dh || !sw || !sh) {
		return NO;
	}

	uint32_t seed = 0;
	const bool locked = (IOSurfaceLock(src, kIOSurfaceLockReadOnly, &seed) == 0);
	CIImage *image = [[CIImage alloc] initWithIOSurface:src];
	if (!image) {
		if (locked) {
			IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, &seed);
		}
		return NO;
	}

	CGFloat scale = MAX((CGFloat)dw / (CGFloat)sw, (CGFloat)dh / (CGFloat)sh);
	image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
	CGRect extent = image.extent;
	CGFloat cropX = extent.origin.x + (extent.size.width - (CGFloat)dw) * 0.5;
	CGFloat cropY = extent.origin.y + (extent.size.height - (CGFloat)dh) * 0.5;
	CGRect crop = CGRectMake(cropX, cropY, (CGFloat)dw, (CGFloat)dh);
	image = [image imageByCroppingToRect:crop];
	image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];

	CVPixelBufferLockBaseAddress(dst, 0);
	[MFTCIContext() render:image
	       toCVPixelBuffer:dst
			bounds:CGRectMake(0, 0, (CGFloat)dw, (CGFloat)dh)
		    colorSpace:nil];
	CVPixelBufferUnlockBaseAddress(dst, 0);
	if (locked) {
		IOSurfaceUnlock(src, kIOSurfaceLockReadOnly, &seed);
	}
	return YES;
}

/* 拍照：把 front 渲成 UIImage（JPEG 回调路径） */
static UIImage *MFTUIImageFromFrontSurface(void) {
	uint64_t gen = 0;
	IOSurfaceRef front = MFTCopyFrontSurface(&gen);
	if (!front) {
		if (MFTAdvanceOneVideoFrame()) {
			front = MFTCopyFrontSurface(&gen);
		}
	}
	if (!front) {
		return nil;
	}

	size_t w = IOSurfaceGetWidth(front);
	size_t h = IOSurfaceGetHeight(front);
	CVPixelBufferRef pb = NULL;
	NSDictionary *attrs = @{
		(id)kCVPixelBufferIOSurfacePropertiesKey : @{},
		(id)kCVPixelBufferCGImageCompatibilityKey : @YES,
		(id)kCVPixelBufferCGBitmapContextCompatibilityKey : @YES,
	};
	if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
				(__bridge CFDictionaryRef)attrs, &pb) != kCVReturnSuccess || !pb) {
		CFRelease(front);
		return nil;
	}
	MFTRenderSurfaceToPixelBuffer(front, pb);
	CFRelease(front);

	CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
	CGImageRef cg = [MFTCIContext() createCGImage:ci fromRect:CGRectMake(0, 0, w, h)];
	UIImage *img = nil;
	if (cg) {
		img = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
		CGImageRelease(cg);
	}
	CVPixelBufferRelease(pb);
	return img;
}

#pragma mark - Preview drivers

@interface MFTPreviewDriver : NSObject
@property (nonatomic, weak) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic, strong) CALayer *overlay;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) uint64_t lastGen;
@property (nonatomic, assign) BOOL useDisplayLink;
- (void)attachToPreview:(AVCaptureVideoPreviewLayer *)preview;
- (void)layout;
- (void)applyFrontSurface:(IOSurfaceRef)surface gen:(uint64_t)gen;
- (void)mft_updateDisplayLinkState;
- (void)tick:(CADisplayLink *)link;
- (void)teardown;
@end

static os_unfair_lock g_drivers_lock = OS_UNFAIR_LOCK_INIT;
static NSHashTable<MFTPreviewDriver *> *g_drivers;

static void MFTRegisterPreviewDriver(MFTPreviewDriver *driver) {
	os_unfair_lock_lock(&g_drivers_lock);
	if (!g_drivers) {
		g_drivers = [NSHashTable weakObjectsHashTable];
	}
	[g_drivers addObject:driver];
	os_unfair_lock_unlock(&g_drivers_lock);
}

static void MFTUnregisterPreviewDriver(MFTPreviewDriver *driver) {
	os_unfair_lock_lock(&g_drivers_lock);
	[g_drivers removeObject:driver];
	os_unfair_lock_unlock(&g_drivers_lock);
}

static NSArray<MFTPreviewDriver *> *MFTCopyDrivers(void) {
	os_unfair_lock_lock(&g_drivers_lock);
	NSArray *arr = g_drivers.allObjects;
	os_unfair_lock_unlock(&g_drivers_lock);
	return arr ?: @[];
}

static void MFTPublishFrontToAllPreviews(void) {
	uint64_t gen = 0;
	IOSurfaceRef front = MFTCopyFrontSurface(&gen);
	if (!front) {
		return;
	}
	NSArray<MFTPreviewDriver *> *drivers = MFTCopyDrivers();
	dispatch_async(dispatch_get_main_queue(), ^{
		for (MFTPreviewDriver *d in drivers) {
			[d applyFrontSurface:front gen:gen];
		}
		CFRelease(front);
	});
}

static void MFTEnsureFrameQueue(void) {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		if (!g_frame_queue) {
			g_frame_queue = dispatch_queue_create("com.yourname.myfirsttweak.frame", DISPATCH_QUEUE_SERIAL);
		}
	});
}

static void MFTOnCameraSample(CMSampleBufferRef sampleBuffer) {
	if (!sampleBuffer) {
		return;
	}
	MFTEnsureFrameQueue();
	dispatch_sync(g_frame_queue, ^{
		if (kMFTClockSource == MFTClockSourceCamera) {
			if (!MFTAdvanceOneVideoFrame()) {
				return;
			}
		}
		if (!kMFTReplaceSampleBuffer) {
			MFTPublishFrontToAllPreviews();
			return;
		}
		CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
		uint64_t gen = 0;
		IOSurfaceRef front = MFTCopyFrontSurface(&gen);
		if (pb && front) {
			MFTRenderSurfaceToPixelBuffer(front, pb);
			NSArray<MFTPreviewDriver *> *drivers = MFTCopyDrivers();
			IOSurfaceRef retained = (IOSurfaceRef)CFRetain(front);
			dispatch_async(dispatch_get_main_queue(), ^{
				for (MFTPreviewDriver *d in drivers) {
					[d applyFrontSurface:retained gen:gen];
				}
				CFRelease(retained);
			});
			CFRelease(front);
		} else {
			if (front) {
				CFRelease(front);
			}
			MFTPublishFrontToAllPreviews();
		}
	});
}

/* 拍照路径：不强制 advance，尽量用当前 front；没有则 advance 一帧 */
static void MFTPaintExistingSampleOnly(CMSampleBufferRef sampleBuffer) {
	if (!sampleBuffer || !kMFTReplacePhotoCapture) {
		return;
	}
	MFTEnsureFrameQueue();
	dispatch_sync(g_frame_queue, ^{
		uint64_t gen = 0;
		IOSurfaceRef front = MFTCopyFrontSurface(&gen);
		if (!front) {
			if (!MFTAdvanceOneVideoFrame()) {
				return;
			}
			front = MFTCopyFrontSurface(&gen);
		}
		if (!front) {
			return;
		}
		CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
		if (pb) {
			MFTRenderSurfaceToPixelBuffer(front, pb);
		}
		CFRelease(front);
	});
}

#pragma mark - FreeRun

static void MFTFreeRunLoop(void) {
	while (atomic_load(&g_freerun_running)) {
		__block BOOL ok = NO;
		MFTEnsureFrameQueue();
		dispatch_sync(g_frame_queue, ^{
			ok = MFTAdvanceOneVideoFrame();
		});
		if (!ok) {
			break;
		}
		MFTPublishFrontToAllPreviews();
		os_unfair_lock_lock(&g_store_lock);
		VTIContext *vti = g_vti;
		os_unfair_lock_unlock(&g_store_lock);
		if (vti) {
			vti_sleep_for_frame_interval(vti);
		} else {
			usleep(33333);
		}
	}
	atomic_store(&g_freerun_running, false);
}

static void MFTStartFreeRunFeeder(void) {
	static dispatch_queue_t freerun_q;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		freerun_q = dispatch_queue_create("com.yourname.myfirsttweak.freerun", DISPATCH_QUEUE_SERIAL);
		MFTEnsureFrameQueue();
	});
	if (!MFTEnsurePipeline()) {
		return;
	}
	bool expected = false;
	if (!atomic_compare_exchange_strong(&g_freerun_running, &expected, true)) {
		return;
	}
	dispatch_async(freerun_q, ^{
		MFTFreeRunLoop();
	});
}

static void MFTStopFreeRunFeeder(void) {
	atomic_store(&g_freerun_running, false);
}

static void MFTEvaluateFeederMode(void) {
	BOOL sessionOn = atomic_load(&g_session_running);
	BOOL hasDO = atomic_load(&g_has_data_output);
	if (!sessionOn) {
		MFTStopFreeRunFeeder();
		return;
	}
	if (kMFTClockSource == MFTClockSourceCamera && hasDO) {
		MFTStopFreeRunFeeder();
		MFTEnsurePipeline();
		return;
	}
	MFTStartFreeRunFeeder();
}

#pragma mark - Preview driver impl

@implementation MFTPreviewDriver

- (void)attachToPreview:(AVCaptureVideoPreviewLayer *)preview {
	if (!kMFTReplacePreviewLayer || !preview) {
		return;
	}
	self.preview = preview;
	if (!self.overlay) {
		CALayer *overlay = [CALayer layer];
		overlay.contentsGravity = kCAGravityResizeAspectFill;
		overlay.masksToBounds = YES;
		overlay.actions = @{
			@"contents" : [NSNull null],
			@"bounds" : [NSNull null],
			@"frame" : [NSNull null],
			@"position" : [NSNull null],
			@"opacity" : [NSNull null],
		};
		self.overlay = overlay;
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	[self.overlay removeFromSuperlayer];
	self.overlay.frame = preview.bounds;
	[preview addSublayer:self.overlay];
	[CATransaction commit];

	MFTRegisterPreviewDriver(self);
	[self mft_updateDisplayLinkState];
	MFTEnsurePipeline();
	MFTEvaluateFeederMode();

	uint64_t gen = 0;
	IOSurfaceRef front = MFTCopyFrontSurface(&gen);
	if (front) {
		[self applyFrontSurface:front gen:gen];
		CFRelease(front);
	}
	os_log(MFTLog(), "preview attached dl=%d", (int)self.useDisplayLink);
}

- (void)mft_updateDisplayLinkState {
	BOOL needDL = (kMFTClockSource == MFTClockSourceFreeRun) || !atomic_load(&g_has_data_output);
	self.useDisplayLink = needDL;
	if (needDL) {
		if (!self.link) {
			self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
			if (@available(iOS 15.0, *)) {
				self.link.preferredFrameRateRange = CAFrameRateRangeMake(24, 60, 30);
			} else {
				self.link.preferredFramesPerSecond = 30;
			}
			[self.link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
		}
		self.link.paused = NO;
	} else {
		self.link.paused = YES;
	}
}

- (void)layout {
	if (!self.preview || !self.overlay) {
		return;
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.overlay.frame = self.preview.bounds;
	[self.preview addSublayer:self.overlay];
	[CATransaction commit];
}

- (void)applyFrontSurface:(IOSurfaceRef)surface gen:(uint64_t)gen {
	if (!self.overlay || !surface) {
		return;
	}
	if (gen != 0 && gen == self.lastGen) {
		return;
	}
	self.lastGen = gen;
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	self.overlay.contents = (__bridge id)surface;
	if (self.preview) {
		self.overlay.frame = self.preview.bounds;
	}
	[CATransaction commit];
}

- (void)tick:(CADisplayLink *)link {
	(void)link;
	if (!self.useDisplayLink) {
		return;
	}
	uint64_t gen = 0;
	IOSurfaceRef front = MFTCopyFrontSurface(&gen);
	if (!front) {
		return;
	}
	[self applyFrontSurface:front gen:gen];
	CFRelease(front);
}

- (void)teardown {
	MFTUnregisterPreviewDriver(self);
	[self.link invalidate];
	self.link = nil;
	[self.overlay removeFromSuperlayer];
	self.overlay.contents = nil;
	self.overlay = nil;
	self.preview = nil;
	self.lastGen = 0;
}

@end

static MFTPreviewDriver *MFTDriverForPreview(AVCaptureVideoPreviewLayer *preview, BOOL create) {
	if (!preview) {
		return nil;
	}
	MFTPreviewDriver *driver = objc_getAssociatedObject(preview, kMFTDriverKey);
	if (!driver && create) {
		driver = [[MFTPreviewDriver alloc] init];
		objc_setAssociatedObject(preview, kMFTDriverKey, driver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	return driver;
}

static void MFTEnsurePreviewOverlay(AVCaptureVideoPreviewLayer *preview) {
	if (!kMFTReplacePreviewLayer || !preview) {
		return;
	}
	[[MFTDriverForPreview(preview, YES)] attachToPreview:preview];
}

static void MFTRefreshAllDisplayLinkState(void) {
	for (MFTPreviewDriver *d in MFTCopyDrivers()) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[d mft_updateDisplayLinkState];
		});
	}
}

#pragma mark - VideoDataOutput shim

@interface MFTSampleBufferShim : NSProxy
@property (nonatomic, weak) id realDelegate;
@property (nonatomic, weak) AVCaptureVideoDataOutput *output;
@end

@implementation MFTSampleBufferShim
+ (instancetype)shimWithDelegate:(id)delegate output:(AVCaptureVideoDataOutput *)output {
	MFTSampleBufferShim *shim = [MFTSampleBufferShim alloc];
	shim.realDelegate = delegate;
	shim.output = output;
	return shim;
}
- (BOOL)respondsToSelector:(SEL)aSelector {
	if (aSelector == @selector(captureOutput:didOutputSampleBuffer:fromConnection:) ||
	    aSelector == @selector(captureOutput:didDropSampleBuffer:fromConnection:)) {
		return YES;
	}
	return [self.realDelegate respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
	return self.realDelegate;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
	NSMethodSignature *sig = [self.realDelegate methodSignatureForSelector:sel];
	return sig ?: [NSObject instanceMethodSignatureForSelector:@selector(init)];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
	if (self.realDelegate) {
		[invocation invokeWithTarget:self.realDelegate];
	}
}
- (void)captureOutput:(AVCaptureOutput *)output
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	       fromConnection:(AVCaptureConnection *)connection {
	MFTOnCameraSample(sampleBuffer);
	id real = self.realDelegate;
	if ([real respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
		[real captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
	}
}
- (void)captureOutput:(AVCaptureOutput *)output
	didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
	     fromConnection:(AVCaptureConnection *)connection {
	id real = self.realDelegate;
	if ([real respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
		[real captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
	}
}
@end

#pragma mark - PhotoOutput shim

@interface MFTPhotoShim : NSProxy
@property (nonatomic, weak) id realDelegate;
@end

@implementation MFTPhotoShim
+ (instancetype)shimWithDelegate:(id)delegate {
	MFTPhotoShim *shim = [MFTPhotoShim alloc];
	shim.realDelegate = delegate;
	return shim;
}
- (BOOL)respondsToSelector:(SEL)sel {
	return [self.realDelegate respondsToSelector:sel] ||
	       sel == @selector(captureOutput:didFinishProcessingPhoto:error:) ||
	       sel == @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:);
}
- (id)forwardingTargetForSelector:(SEL)sel {
	return self.realDelegate;
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
	NSMethodSignature *sig = [self.realDelegate methodSignatureForSelector:sel];
	return sig ?: [NSObject instanceMethodSignatureForSelector:@selector(init)];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
	if (self.realDelegate) {
		[invocation invokeWithTarget:self.realDelegate];
	}
}

/* iOS 11+ */
- (void)captureOutput:(AVCapturePhotoOutput *)output
	didFinishProcessingPhoto:(AVCapturePhoto *)photo
			   error:(NSError *)error {
	(void)output;
	id real = self.realDelegate;
	if (error || !kMFTReplacePhotoCapture) {
		if ([real respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
			[real captureOutput:output didFinishProcessingPhoto:photo error:error];
		}
		return;
	}

	/* 优先改 photo 内 pixelBuffer */
	CVPixelBufferRef pb = photo.pixelBuffer;
	if (pb) {
		MFTEnsureFrameQueue();
		dispatch_sync(g_frame_queue, ^{
			uint64_t gen = 0;
			IOSurfaceRef front = MFTCopyFrontSurface(&gen);
			if (!front && MFTAdvanceOneVideoFrame()) {
				front = MFTCopyFrontSurface(&gen);
			}
			if (front) {
				MFTRenderSurfaceToPixelBuffer(front, pb);
				CFRelease(front);
			}
		});
	}

	if ([real respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
		[real captureOutput:output didFinishProcessingPhoto:photo error:error];
	}
}

/* 旧 bracket API：替换 sampleBuffer 像素后再转发 */
- (void)captureOutput:(AVCapturePhotoOutput *)output
	didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer
		previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer
		       resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
			bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings
				  error:(NSError *)error {
	if (!error && kMFTReplacePhotoCapture) {
		if (photoSampleBuffer) {
			MFTPaintExistingSampleOnly(photoSampleBuffer);
		}
		if (previewPhotoSampleBuffer) {
			MFTPaintExistingSampleOnly(previewPhotoSampleBuffer);
		}
	}
	id real = self.realDelegate;
	SEL sel = @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:);
	if ([real respondsToSelector:sel]) {
		[real captureOutput:output
			didFinishProcessingPhotoSampleBuffer:photoSampleBuffer
				previewPhotoSampleBuffer:previewPhotoSampleBuffer
				       resolvedSettings:resolvedSettings
					bracketSettings:bracketSettings
						  error:error];
	}
}
@end

#pragma mark - Hooks

%hook AVCaptureSession

- (void)startRunning {
	%orig;
	atomic_store(&g_session_running, true);
	MFTEnsurePipeline();
	MFTEvaluateFeederMode();
	os_log(MFTLog(), "session startRunning");
}

- (void)stopRunning {
	%orig;
	atomic_store(&g_session_running, false);
	MFTStopFreeRunFeeder();
	os_log(MFTLog(), "session stopRunning");
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate
			  queue:(dispatch_queue_t)sampleBufferCallbackQueue {
	id delegate = (id)sampleBufferDelegate;
	if (delegate && kMFTReplaceSampleBuffer && ![delegate isKindOfClass:[MFTSampleBufferShim class]]) {
		MFTSampleBufferShim *shim = [MFTSampleBufferShim shimWithDelegate:delegate output:self];
		objc_setAssociatedObject(self, kMFTShimKey, shim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		delegate = shim;
		atomic_store(&g_has_data_output, true);
		MFTEnsurePipeline();
		MFTEvaluateFeederMode();
		MFTRefreshAllDisplayLinkState();
		os_log(MFTLog(), "VideoDataOutput wrapped %{public}@", NSStringFromClass([(id)sampleBufferDelegate class]));
	}
	%orig(delegate, sampleBufferCallbackQueue);
}

%end

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
	AVCaptureVideoPreviewLayer *layer = %orig;
	if (layer) {
		MFTEnsurePreviewOverlay(layer);
	}
	return layer;
}

- (instancetype)initWithSessionWithNoConnection:(AVCaptureSession *)session {
	AVCaptureVideoPreviewLayer *layer = %orig;
	if (layer) {
		MFTEnsurePreviewOverlay(layer);
	}
	return layer;
}

- (void)setSession:(AVCaptureSession *)session {
	%orig;
	MFTEnsurePreviewOverlay(self);
}

- (void)setSessionWithNoConnection:(AVCaptureSession *)session {
	%orig;
	MFTEnsurePreviewOverlay(self);
}

- (void)layoutSublayers {
	%orig;
	MFTPreviewDriver *driver = MFTDriverForPreview(self, NO);
	if (driver) {
		[driver layout];
	} else if (self.session) {
		MFTEnsurePreviewOverlay(self);
	}
}

%end

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings
			delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
	id del = (id)delegate;
	if (kMFTReplacePhotoCapture && del && ![del isKindOfClass:[MFTPhotoShim class]]) {
		MFTPhotoShim *shim = [MFTPhotoShim shimWithDelegate:del];
		objc_setAssociatedObject(self, kMFTPhotoShimKey, shim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		del = shim;
		MFTEnsurePipeline();
		os_log(MFTLog(), "PhotoOutput delegate wrapped");
	}
	%orig(settings, del);
}

%end

%hook AVCaptureStillImageOutput

- (void)captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection
				     completionHandler:(void (^)(CMSampleBufferRef imageDataSampleBuffer, NSError *error))handler {
	if (!kMFTReplacePhotoCapture || !handler) {
		%orig;
		return;
	}
	MFTEnsurePipeline();
	void (^wrapped)(CMSampleBufferRef, NSError *) = ^(CMSampleBufferRef buf, NSError *err) {
		if (!err && buf) {
			MFTPaintExistingSampleOnly(buf);
		}
		handler(buf, err);
	};
	%orig(connection, wrapped);
}

%end

#pragma mark - ctor

%ctor {
	MFTEnsureFrameQueue();
	NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
	NSLog(@"[MyFirstTweak] camera replace loaded in %@ clock=%ld photo=%d",
	      bid, (long)kMFTClockSource, (int)kMFTReplacePhotoCapture);
	os_log(MFTLog(), "coverage: preview+videoData+photo still=on; movieFile/ReplayKit/UIImagePicker=limited");
}
