/*
 * VirtualCamDemo — 选择 MP4 → 作为「虚拟摄像头」预览
 *
 * 说明（重要）：
 * - 本 App 在「本应用内」用你选的 MP4 代替相机画面（预览 + 帧回调模拟）。
 * - 未越狱时，无法替换微信/系统相机等其它 App 的摄像头（iOS 沙盒限制）。
 * - 其它 App 需要越狱安装 MyFirstTweak，并把 Bundle ID 写入 Filter。
 *
 * 使用：点「选择视频」→ 选 mp4 → 点「开启虚拟摄像头」。
 */

#import "CameraViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurfaceRef.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <MobileCoreServices/MobileCoreServices.h>

#import "video_to_iosurface.h"

static NSString *const kVideoFileName = @"demo.mp4";
static NSString *const kPrefsVideoPathKey = @"MFTVideoPath";

@interface CameraViewController () <
	AVCaptureVideoDataOutputSampleBufferDelegate,
	UIDocumentPickerDelegate,
	PHPickerViewControllerDelegate,
	UIImagePickerControllerDelegate,
	UINavigationControllerDelegate
> {
	VTIContext *_vti;
	IOSurfaceRef _surfaces[2];
	int _frontIdx;
	uint64_t _gen;
	BOOL _virtualRunning;
}
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *previewHost;
@property (nonatomic, strong) CALayer *videoLayer;

@property (nonatomic, strong) UIButton *pickButton;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) UIButton *realCamButton;

@property (nonatomic, strong) dispatch_queue_t frameQueue;
@property (nonatomic, strong) dispatch_source_t timer;

/* 可选：真实相机对比（默认不强制） */
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureVideoDataOutput *dataOutput;
@property (nonatomic, strong) dispatch_queue_t camQueue;
@property (nonatomic, assign) BOOL useRealCameraClock;
@end

@implementation CameraViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.12 alpha:1.0];
	_frontIdx = 0;
	_gen = 0;
	_surfaces[0] = NULL;
	_surfaces[1] = NULL;
	_vti = NULL;
	_virtualRunning = NO;
	self.useRealCameraClock = NO;
	self.frameQueue = dispatch_queue_create("com.yourname.virtualcamdemo.frame", DISPATCH_QUEUE_SERIAL);
	self.camQueue = dispatch_queue_create("com.yourname.virtualcamdemo.cam", DISPATCH_QUEUE_SERIAL);

	[self buildUI];
	[self refreshStatus];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	self.videoLayer.frame = self.previewHost.bounds;
	self.previewLayer.frame = self.previewHost.bounds;
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self stopVirtualCamera];
}

- (void)dealloc {
	[self stopVirtualCamera];
	[self teardownPipeline];
}

#pragma mark - Paths

- (NSString *)documentsDir {
	return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

- (NSString *)storedVideoPath {
	NSString *custom = [[NSUserDefaults standardUserDefaults] stringForKey:kPrefsVideoPathKey];
	if (custom.length && [[NSFileManager defaultManager] fileExistsAtPath:custom]) {
		return custom;
	}
	NSString *doc = [[self documentsDir] stringByAppendingPathComponent:kVideoFileName];
	if ([[NSFileManager defaultManager] fileExistsAtPath:doc]) {
		return doc;
	}
	return nil;
}

- (NSString *)targetDemoPath {
	return [[self documentsDir] stringByAppendingPathComponent:kVideoFileName];
}

#pragma mark - UI

- (void)buildUI {
	self.titleLabel = [[UILabel alloc] init];
	self.titleLabel.text = @"虚拟摄像头";
	self.titleLabel.textColor = UIColor.whiteColor;
	self.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
	self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.titleLabel];

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
	self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.statusLabel];

	self.previewHost = [[UIView alloc] init];
	self.previewHost.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1];
	self.previewHost.layer.cornerRadius = 12;
	self.previewHost.clipsToBounds = YES;
	self.previewHost.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.previewHost];

	self.videoLayer = [CALayer layer];
	self.videoLayer.contentsGravity = kCAGravityResizeAspect;
	self.videoLayer.actions = @{ @"contents" : [NSNull null], @"bounds" : [NSNull null] };
	[self.previewHost.layer addSublayer:self.videoLayer];

	self.pickButton = [self makeButton:@"① 选择 MP4 视频" color:[UIColor systemBlueColor] action:@selector(onPickVideo)];
	self.startButton = [self makeButton:@"② 开启虚拟摄像头" color:[UIColor systemGreenColor] action:@selector(onStart)];
	self.stopButton = [self makeButton:@"停止" color:[UIColor systemRedColor] action:@selector(onStop)];
	self.realCamButton = [self makeButton:@"模式: 纯视频(推荐)" color:[UIColor systemGrayColor] action:@selector(onToggleMode)];

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
		self.pickButton, self.startButton, self.stopButton, self.realCamButton
	]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 10;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];

	UILayoutGuide *g = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[self.titleLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:12],
		[self.titleLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],

		[self.statusLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
		[self.statusLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[self.statusLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],

		[self.previewHost.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:12],
		[self.previewHost.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[self.previewHost.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
		[self.previewHost.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.42],

		[stack.topAnchor constraintEqualToAnchor:self.previewHost.bottomAnchor constant:16],
		[stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
		[self.pickButton.heightAnchor constraintEqualToConstant:48],
		[self.startButton.heightAnchor constraintEqualToConstant:48],
		[self.stopButton.heightAnchor constraintEqualToConstant:44],
		[self.realCamButton.heightAnchor constraintEqualToConstant:40],
	]];
}

- (UIButton *)makeButton:(NSString *)title color:(UIColor *)color action:(SEL)sel {
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
	b.backgroundColor = color;
	b.layer.cornerRadius = 10;
	[b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
	return b;
}

- (void)setStatus:(NSString *)text {
	dispatch_async(dispatch_get_main_queue(), ^{
		self.statusLabel.text = text;
	});
}

- (void)refreshStatus {
	NSString *path = [self storedVideoPath];
	NSString *mode = self.useRealCameraClock ? @"真实相机时钟+替换画面" : @"纯视频预览(不需相机权限)";
	if (path) {
		unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
		[self setStatus:[NSString stringWithFormat:
			@"已选视频:\n%@\n大小: %.1f MB\n模式: %@\n\n"
			@"本 App 内会显示该视频作为摄像头画面。\n"
			@"若要替换微信等其它 App：需要越狱 + 安装 tweak。",
			path, sz / 1024.0 / 1024.0, mode]];
	} else {
		[self setStatus:[NSString stringWithFormat:
			@"尚未选择视频。\n请点「① 选择 MP4 视频」从文件/相册导入。\n\n模式: %@\n\n"
			@"注意: 未越狱时只能在本 App 内虚拟摄像头，\n不能直接替换系统/其它 App 摄像头。",
			mode]];
	}
}

#pragma mark - Actions

- (void)onPickVideo {
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择 MP4 来源"
								       message:nil
									preferredStyle:UIAlertControllerStyleActionSheet];
	[sheet addAction:[UIAlertAction actionWithTitle:@"文件 App / 浏览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		[self pickFromDocuments];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"相册视频" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		[self pickFromPhotos];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
	if (sheet.popoverPresentationController) {
		sheet.popoverPresentationController.sourceView = self.pickButton;
		sheet.popoverPresentationController.sourceRect = self.pickButton.bounds;
	}
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickFromDocuments {
	NSArray *types = nil;
	if (@available(iOS 14.0, *)) {
		types = @[ UTTypeMovie, UTTypeMPEG4Movie, UTTypeQuickTimeMovie ];
	} else {
		types = @[ (NSString *)kUTTypeMovie, (NSString *)kUTTypeMPEG4 ];
	}
	UIDocumentPickerViewController *picker = nil;
	if (@available(iOS 14.0, *)) {
		picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
	} else {
		picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:types inMode:UIDocumentPickerModeImport];
	}
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)pickFromPhotos {
	if (@available(iOS 14.0, *)) {
		PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
		config.filter = [PHPickerFilter videosFilter];
		config.selectionLimit = 1;
		PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
		picker.delegate = self;
		[self presentViewController:picker animated:YES completion:nil];
	} else {
		UIImagePickerController *picker = [[UIImagePickerController alloc] init];
		picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
		picker.mediaTypes = @[ (NSString *)kUTTypeMovie ];
		picker.delegate = self;
		[self presentViewController:picker animated:YES completion:nil];
	}
}

- (void)onStart {
	NSString *path = [self storedVideoPath];
	if (!path) {
		[self setStatus:@"请先选择 MP4 视频"];
		[self onPickVideo];
		return;
	}
	[self startVirtualCameraWithPath:path];
}

- (void)onStop {
	[self stopVirtualCamera];
	[self refreshStatus];
	[self setStatus:[[self.statusLabel.text ?: @""] stringByAppendingString:@"\n\n已停止虚拟摄像头。"]];
}

- (void)onToggleMode {
	self.useRealCameraClock = !self.useRealCameraClock;
	NSString *t = self.useRealCameraClock ? @"模式: 真实相机时钟" : @"模式: 纯视频(推荐)";
	[self.realCamButton setTitle:t forState:UIControlStateNormal];
	[self refreshStatus];
	if (_virtualRunning) {
		NSString *path = [self storedVideoPath];
		[self stopVirtualCamera];
		if (path) {
			[self startVirtualCameraWithPath:path];
		}
	}
}

#pragma mark - Import video → Documents/demo.mp4

- (void)importVideoFromURL:(NSURL *)url {
	if (!url) {
		[self setStatus:@"无效的视频 URL"];
		return;
	}
	[self setStatus:@"正在导入视频…"];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *dest = [self targetDemoPath];
		NSError *err = nil;

		BOOL access = [url startAccessingSecurityScopedResource];
		NSURL *tmpCopy = nil;

		/* 若是相册临时文件，先协调读 */
		NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&err];
		if (!data) {
			/* try file copy via coordinator */
			NSFileCoordinator *coord = [[NSFileCoordinator alloc] init];
			__block NSError *coordErr = nil;
			__block NSURL *local = nil;
			[coord coordinateReadingItemAtURL:url options:0 error:&coordErr byAccessor:^(NSURL *newURL) {
				NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
						 [NSString stringWithFormat:@"import_%@.mp4", NSUUID.UUID.UUIDString]];
				[[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
				if ([[NSFileManager defaultManager] copyItemAtURL:newURL toURL:[NSURL fileURLWithPath:tmp] error:nil]) {
					local = [NSURL fileURLWithPath:tmp];
				}
			}];
			if (local) {
				tmpCopy = local;
				data = [NSData dataWithContentsOfURL:local options:0 error:&err];
			}
		}

		if (access) {
			[url stopAccessingSecurityScopedResource];
		}

		if (!data || data.length < 32) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[self setStatus:[NSString stringWithFormat:@"导入失败: %@", err.localizedDescription ?: @"空文件"]];
			});
			return;
		}

		[fm createDirectoryAtPath:[self documentsDir] withIntermediateDirectories:YES attributes:nil error:nil];
		[fm removeItemAtPath:dest error:nil];
		BOOL ok = [data writeToFile:dest options:NSDataWritingAtomic error:&err];
		if (tmpCopy) {
			[fm removeItemAtURL:tmpCopy error:nil];
		}

		dispatch_async(dispatch_get_main_queue(), ^{
			if (!ok) {
				[self setStatus:[NSString stringWithFormat:@"写入失败: %@", err.localizedDescription]];
				return;
			}
			[[NSUserDefaults standardUserDefaults] setObject:dest forKey:kPrefsVideoPathKey];
			[[NSUserDefaults standardUserDefaults] synchronize];
			[self refreshStatus];
			[self setStatus:[NSString stringWithFormat:
					 @"导入成功 (%.1f MB)\n%@\n\n请点「② 开启虚拟摄像头」",
					 data.length / 1024.0 / 1024.0, dest]];
		});
	});
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	[self importVideoFromURL:urls.firstObject];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	[self setStatus:@"已取消选择文件"];
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results API_AVAILABLE(ios(14.0)) {
	[picker dismissViewControllerAnimated:YES completion:nil];
	PHPickerResult *result = results.firstObject;
	if (!result) {
		[self setStatus:@"未选择相册视频"];
		return;
	}
	NSItemProvider *provider = result.itemProvider;
	NSString *type = UTTypeMovie.identifier;
	if (![provider hasItemConformingToTypeIdentifier:type]) {
		type = @"public.movie";
	}
	[self setStatus:@"正在从相册导出…"];
	[provider loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
		if (!url || error) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[self setStatus:[NSString stringWithFormat:@"相册导出失败: %@", error.localizedDescription ?: @"?"]];
			});
			return;
		}
		/* loadFileRepresentation 回调结束后文件可能删除，必须立刻拷贝 */
		NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
				 [NSString stringWithFormat:@"photo_%@.mp4", NSUUID.UUID.UUIDString]];
		NSError *copyErr = nil;
		[[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
		BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&copyErr];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!ok) {
				[self setStatus:[NSString stringWithFormat:@"拷贝失败: %@", copyErr.localizedDescription]];
				return;
			}
			[self importVideoFromURL:[NSURL fileURLWithPath:tmp]];
		});
	}];
}

#pragma mark - UIImagePickerController (iOS 13 fallback)

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
	[picker dismissViewControllerAnimated:YES completion:nil];
	NSURL *url = info[UIImagePickerControllerMediaURL];
	[self importVideoFromURL:url];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
	[picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Virtual camera pipeline

- (void)teardownPipeline {
	if (_surfaces[0]) {
		CFRelease(_surfaces[0]);
		_surfaces[0] = NULL;
	}
	if (_surfaces[1]) {
		CFRelease(_surfaces[1]);
		_surfaces[1] = NULL;
	}
	if (_vti) {
		vti_close(_vti);
		_vti = NULL;
	}
}

- (BOOL)openPipelineAtPath:(NSString *)path {
	[self teardownPipeline];
	VTIContext *vti = vti_open(path.fileSystemRepresentation, true);
	if (!vti) {
		return NO;
	}
	int w = vti_width(vti);
	int h = vti_height(vti);
	if (w <= 0 || h <= 0) {
		vti_close(vti);
		return NO;
	}
	IOSurfaceRef s0 = isb_create(w, h, false);
	IOSurfaceRef s1 = isb_create(w, h, false);
	if (!s0 || !s1) {
		if (s0) CFRelease(s0);
		if (s1) CFRelease(s1);
		vti_close(vti);
		return NO;
	}
	_vti = vti;
	_surfaces[0] = s0;
	_surfaces[1] = s1;
	_frontIdx = 0;
	_gen = 0;
	return YES;
}

- (BOOL)advanceFrame {
	if (!_vti) return NO;
	int back = (_frontIdx + 1) % 2;
	bool eof = false;
	if (!vti_copy_next_frame(_vti, _surfaces[back], &eof)) {
		return NO;
	}
	_frontIdx = back;
	_gen++;
	return YES;
}

- (void)presentFrontOnMain {
	IOSurfaceRef front = _surfaces[_frontIdx];
	if (!front) return;
	CFRetain(front);
	uint64_t gen = _gen;
	dispatch_async(dispatch_get_main_queue(), ^{
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		self.videoLayer.frame = self.previewHost.bounds;
		self.videoLayer.contents = (__bridge id)front;
		[CATransaction commit];
		CFRelease(front);
		if ((gen % 30) == 1) {
			NSString *base = [self storedVideoPath].lastPathComponent ?: @"video";
			[self setStatus:[NSString stringWithFormat:
					 @"虚拟摄像头运行中\n视频: %@\n帧: #%llu\n分辨率由视频决定\n\n"
					 @"※ 仅本 App 预览区为虚拟画面\n※ 其它 App 需越狱 tweak",
					 base, (unsigned long long)gen]];
		}
	});
}

- (void)startVirtualCameraWithPath:(NSString *)path {
	[self stopVirtualCamera];

	if (![self openPipelineAtPath:path]) {
		[self setStatus:[NSString stringWithFormat:
				 @"无法打开视频（格式可能不支持）:\n%@", path]];
		return;
	}

	_virtualRunning = YES;
	[self setStatus:@"虚拟摄像头已开启，正在出帧…"];

	/* 先推一帧，保证立刻有画面 */
	dispatch_sync(self.frameQueue, ^{
		if ([self advanceFrame]) {
			[self presentFrontOnMain];
		}
	});

	if (self.useRealCameraClock) {
		[self startRealCameraClock];
	} else {
		[self startTimerClock];
	}
}

- (void)startTimerClock {
	[self stopTimer];
	dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.frameQueue);
	/* ~30fps */
	dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC / 30), (uint64_t)(NSEC_PER_SEC / 100));
	__weak typeof(self) weakSelf = self;
	dispatch_source_set_event_handler(t, ^{
		__strong typeof(weakSelf) self = weakSelf;
		if (!self || !self->_virtualRunning) return;
		if ([self advanceFrame]) {
			[self presentFrontOnMain];
		}
	});
	self.timer = t;
	dispatch_resume(t);
}

- (void)stopTimer {
	if (self.timer) {
		dispatch_source_cancel(self.timer);
		self.timer = nil;
	}
}

- (void)stopVirtualCamera {
	_virtualRunning = NO;
	[self stopTimer];
	[self stopRealCameraClock];
	dispatch_sync(self.frameQueue, ^{
		/* drain */
	});
	dispatch_async(dispatch_get_main_queue(), ^{
		self.videoLayer.contents = nil;
	});
	[self teardownPipeline];
}

#pragma mark - Optional real camera clock

- (void)startRealCameraClock {
	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!granted) {
				[self setStatus:@"未授权相机，已回退纯视频模式"];
				self.useRealCameraClock = NO;
				[self.realCamButton setTitle:@"模式: 纯视频(推荐)" forState:UIControlStateNormal];
				[self startTimerClock];
				return;
			}
			[self setupCaptureIfNeeded];
			dispatch_async(self.camQueue, ^{
				if (!self.session.running) {
					[self.session startRunning];
				}
			});
		});
	}];
}

- (void)stopRealCameraClock {
	dispatch_async(self.camQueue, ^{
		if (self.session.running) {
			[self.session stopRunning];
		}
	});
}

- (void)setupCaptureIfNeeded {
	if (self.session) return;

	self.session = [[AVCaptureSession alloc] init];
	if ([self.session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
		self.session.sessionPreset = AVCaptureSessionPreset1280x720;
	}
	AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	if (!device) return;
	NSError *err = nil;
	AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
	if (!input) return;
	if ([self.session canAddInput:input]) [self.session addInput:input];

	self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
	self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
	/* 不显示真相机层，只用其时钟；画面走 videoLayer */
	self.previewLayer.opacity = 0;

	self.dataOutput = [[AVCaptureVideoDataOutput alloc] init];
	self.dataOutput.alwaysDiscardsLateVideoFrames = YES;
	self.dataOutput.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
	[self.dataOutput setSampleBufferDelegate:self queue:self.camQueue];
	if ([self.session canAddOutput:self.dataOutput]) [self.session addOutput:self.dataOutput];
}

- (void)paintSurface:(IOSurfaceRef)src into:(CVPixelBufferRef)dst {
	if (!src || !dst) return;
	CIImage *image = [[CIImage alloc] initWithIOSurface:src];
	if (!image) return;
	size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
	size_t sw = IOSurfaceGetWidth(src), sh = IOSurfaceGetHeight(src);
	if (!dw || !dh || !sw || !sh) return;
	CGFloat scale = MAX((CGFloat)dw / (CGFloat)sw, (CGFloat)dh / (CGFloat)sh);
	image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
	CGRect extent = image.extent;
	CGFloat cropX = extent.origin.x + (extent.size.width - (CGFloat)dw) * 0.5;
	CGFloat cropY = extent.origin.y + (extent.size.height - (CGFloat)dh) * 0.5;
	CGRect crop = CGRectMake(cropX, cropY, (CGFloat)dw, (CGFloat)dh);
	image = [image imageByCroppingToRect:crop];
	image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-crop.origin.x, -crop.origin.y)];
	static CIContext *ctx;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		ctx = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace : [NSNull null] }];
	});
	CVPixelBufferLockBaseAddress(dst, 0);
	[ctx render:image toCVPixelBuffer:dst bounds:CGRectMake(0, 0, dw, dh) colorSpace:nil];
	CVPixelBufferUnlockBaseAddress(dst, 0);
}

- (void)captureOutput:(AVCaptureOutput *)output
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	       fromConnection:(AVCaptureConnection *)connection {
	(void)output; (void)connection;
	if (!_virtualRunning || !self.useRealCameraClock) return;

	__block IOSurfaceRef front = NULL;
	dispatch_sync(self.frameQueue, ^{
		if (![self advanceFrame]) return;
		front = _surfaces[_frontIdx];
		if (front) CFRetain(front);
	});
	if (!front) return;

	CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
	if (pb) [self paintSurface:front into:pb];

	dispatch_async(dispatch_get_main_queue(), ^{
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		self.videoLayer.contents = (__bridge id)front;
		[CATransaction commit];
		CFRelease(front);
	});
}

@end
