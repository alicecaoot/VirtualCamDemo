/*
 * 演示 App：AVCaptureSession + PreviewLayer + VideoDataOutput。
 * - 安装 MyFirstTweak 后：由 tweak 单一时钟 hook 成视频画面
 * - 未安装时：kEmbedLocalVirtualPreview 在本进程内用视频帧盖预览（自测）
 *
 * 视频：Documents/demo.mp4（Files 文件共享已打开）
 */

#import "CameraViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurfaceRef.h>

#import "video_to_iosurface.h"

static const BOOL kEmbedLocalVirtualPreview = YES;
static NSString *const kVideoFileName = @"demo.mp4";

@interface CameraViewController () <AVCaptureVideoDataOutputSampleBufferDelegate> {
	VTIContext *_vti;
	IOSurfaceRef _surfaces[2];
	int _frontIdx;
	uint64_t _gen;
}
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property (nonatomic, strong) AVCaptureVideoDataOutput *dataOutput;
@property (nonatomic, strong) dispatch_queue_t camQueue;
@property (nonatomic, strong) dispatch_queue_t frameQueue;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) CALayer *localOverlay;
@property (nonatomic, assign) BOOL sessionStarted;
@end

@implementation CameraViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	_frontIdx = 0;
	_gen = 0;
	_surfaces[0] = NULL;
	_surfaces[1] = NULL;
	_vti = NULL;
	self.frameQueue = dispatch_queue_create("com.yourname.virtualcamdemo.frame", DISPATCH_QUEUE_SERIAL);
	self.camQueue = dispatch_queue_create("com.yourname.virtualcamdemo.cam", DISPATCH_QUEUE_SERIAL);

	[self buildUI];
	[self setupCapture];
	[self setupLocalVirtualIfNeeded];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	self.previewLayer.frame = self.view.bounds;
	self.localOverlay.frame = self.view.bounds;
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	[self startSession];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self stopSession];
}

- (void)dealloc {
	[self teardownLocalVirtual];
}

#pragma mark - UI

- (void)buildUI {
	self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
	self.statusLabel.textColor = UIColor.whiteColor;
	self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.text = @"VirtualCamDemo\nPut demo.mp4 into Files → On My iPhone → VirtualCamDemo";
	self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.statusLabel];

	self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
	[self.toggleButton setTitle:@"Stop" forState:UIControlStateNormal];
	self.toggleButton.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.85];
	[self.toggleButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	self.toggleButton.layer.cornerRadius = 8;
	self.toggleButton.translatesAutoresizingMaskIntoConstraints = NO;
	[self.toggleButton addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
	[self.view addSubview:self.toggleButton];

	UILayoutGuide *g = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[self.statusLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:12],
		[self.statusLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-12],
		[self.statusLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
		[self.toggleButton.centerXAnchor constraintEqualToAnchor:g.centerXAnchor],
		[self.toggleButton.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-16],
		[self.toggleButton.widthAnchor constraintEqualToConstant:120],
		[self.toggleButton.heightAnchor constraintEqualToConstant:44],
	]];
}

- (void)setStatus:(NSString *)text {
	dispatch_async(dispatch_get_main_queue(), ^{
		self.statusLabel.text = text;
	});
}

- (void)onToggle {
	if (self.sessionStarted) {
		[self stopSession];
		[self.toggleButton setTitle:@"Start" forState:UIControlStateNormal];
	} else {
		[self startSession];
		[self.toggleButton setTitle:@"Stop" forState:UIControlStateNormal];
	}
}

#pragma mark - Capture

- (void)setupCapture {
	self.session = [[AVCaptureSession alloc] init];
	if ([self.session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
		self.session.sessionPreset = AVCaptureSessionPreset1280x720;
	}

	AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	if (!device) {
		[self setStatus:@"No camera device"];
		return;
	}

	NSError *err = nil;
	AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
	if (!input) {
		[self setStatus:[NSString stringWithFormat:@"Camera input error: %@", err.localizedDescription]];
		return;
	}
	if ([self.session canAddInput:input]) {
		[self.session addInput:input];
	}

	self.previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
	self.previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
	self.previewLayer.frame = self.view.bounds;
	[self.view.layer insertSublayer:self.previewLayer atIndex:0];

	self.dataOutput = [[AVCaptureVideoDataOutput alloc] init];
	self.dataOutput.alwaysDiscardsLateVideoFrames = YES;
	self.dataOutput.videoSettings = @{
		(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
	};
	[self.dataOutput setSampleBufferDelegate:self queue:self.camQueue];
	if ([self.session canAddOutput:self.dataOutput]) {
		[self.session addOutput:self.dataOutput];
	}

	[self.view bringSubviewToFront:self.statusLabel];
	[self.view bringSubviewToFront:self.toggleButton];
}

- (void)startSession {
	[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
		dispatch_async(dispatch_get_main_queue(), ^{
			if (!granted) {
				[self setStatus:@"Camera permission denied"];
				return;
			}
			dispatch_async(self.camQueue, ^{
				if (!self.session.running) {
					[self.session startRunning];
				}
				dispatch_async(dispatch_get_main_queue(), ^{
					self.sessionStarted = YES;
					[self setStatus:[self statusHelpText]];
				});
			});
		});
	}];
}

- (void)stopSession {
	dispatch_async(self.camQueue, ^{
		if (self.session.running) {
			[self.session stopRunning];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			self.sessionStarted = NO;
		});
	});
}

- (NSString *)statusHelpText {
	NSString *path = [self resolveVideoPath];
	BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
	return [NSString stringWithFormat:
		@"VirtualCamDemo\n"
		@"video: %@\n"
		@"exists: %@\n"
		@"localVirtual: %@\n"
		@"With MyFirstTweak installed, preview is hooked.\n"
		@"Without tweak, embedded local virtual still works.",
		path, exists ? @"YES" : @"NO",
		kEmbedLocalVirtualPreview ? @"ON" : @"OFF"];
}

- (NSString *)resolveVideoPath {
	NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
	NSString *path = [doc stringByAppendingPathComponent:kVideoFileName];
	if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
		return path;
	}
	NSString *bundled = [[NSBundle mainBundle] pathForResource:@"demo" ofType:@"mp4"];
	return bundled.length ? bundled : path;
}

#pragma mark - Local virtual pipeline

- (void)setupLocalVirtualIfNeeded {
	if (!kEmbedLocalVirtualPreview) {
		return;
	}

	self.localOverlay = [CALayer layer];
	self.localOverlay.frame = self.view.bounds;
	self.localOverlay.contentsGravity = kCAGravityResizeAspectFill;
	self.localOverlay.actions = @{
		@"contents" : [NSNull null],
		@"frame" : [NSNull null],
		@"bounds" : [NSNull null],
		@"position" : [NSNull null],
	};
	[self.previewLayer addSublayer:self.localOverlay];

	NSString *path = [self resolveVideoPath];
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		[self setStatus:[NSString stringWithFormat:@"Missing video:\n%@\nCopy demo.mp4 via Finder / Files app", path]];
		return;
	}

	VTIContext *vti = vti_open(path.fileSystemRepresentation, true);
	if (!vti) {
		[self setStatus:@"vti_open failed"];
		return;
	}
	int w = vti_width(vti);
	int h = vti_height(vti);
	IOSurfaceRef s0 = isb_create(w, h, false);
	IOSurfaceRef s1 = isb_create(w, h, false);
	if (!s0 || !s1) {
		if (s0) {
			CFRelease(s0);
		}
		if (s1) {
			CFRelease(s1);
		}
		vti_close(vti);
		[self setStatus:@"IOSurface create failed"];
		return;
	}
	_vti = vti;
	_surfaces[0] = s0;
	_surfaces[1] = s1;
}

- (void)teardownLocalVirtual {
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

- (BOOL)advanceLocalFrame {
	if (!_vti || !_surfaces[0] || !_surfaces[1]) {
		return NO;
	}
	int back = (_frontIdx + 1) % 2;
	IOSurfaceRef backSurf = _surfaces[back];
	bool eof = false;
	if (!vti_copy_next_frame(_vti, backSurf, &eof)) {
		return NO;
	}
	_frontIdx = back;
	_gen++;
	return YES;
}

- (void)paintSurface:(IOSurfaceRef)src into:(CVPixelBufferRef)dst {
	if (!src || !dst) {
		return;
	}
	CIImage *image = [[CIImage alloc] initWithIOSurface:src];
	if (!image) {
		return;
	}
	size_t dw = CVPixelBufferGetWidth(dst);
	size_t dh = CVPixelBufferGetHeight(dst);
	size_t sw = IOSurfaceGetWidth(src);
	size_t sh = IOSurfaceGetHeight(src);
	if (!dw || !dh || !sw || !sh) {
		return;
	}
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
		ctx = [CIContext contextWithOptions:@{
			kCIContextWorkingColorSpace : [NSNull null],
		}];
	});
	CVPixelBufferLockBaseAddress(dst, 0);
	[ctx render:image
 toCVPixelBuffer:dst
	  bounds:CGRectMake(0, 0, (CGFloat)dw, (CGFloat)dh)
      colorSpace:nil];
	CVPixelBufferUnlockBaseAddress(dst, 0);
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	       fromConnection:(AVCaptureConnection *)connection {
	(void)output;
	(void)connection;

	if (!kEmbedLocalVirtualPreview || !_vti) {
		return;
	}

	__block IOSurfaceRef front = NULL;
	__block uint64_t gen = 0;
	dispatch_sync(self.frameQueue, ^{
		if (![self advanceLocalFrame]) {
			return;
		}
		front = _surfaces[_frontIdx];
		if (front) {
			CFRetain(front);
		}
		gen = _gen;
	});
	if (!front) {
		return;
	}

	CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
	if (pb) {
		[self paintSurface:front into:pb];
	}

	dispatch_async(dispatch_get_main_queue(), ^{
		[CATransaction begin];
		[CATransaction setDisableActions:YES];
		self.localOverlay.contents = (__bridge id)front;
		[CATransaction commit];
		CFRelease(front);
		if ((gen % 30) == 1) {
			[self setStatus:[NSString stringWithFormat:@"local virtual frame #%llu\n%@",
							 (unsigned long long)gen, [self statusHelpText]]];
		}
	});
}

@end
