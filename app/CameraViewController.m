/*
 * VirtualCamDemo v0.2
 * Pick an MP4 -> show it as virtual camera preview inside this app.
 *
 * NOT a system-wide camera replace without jailbreak.
 */

#import "CameraViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurfaceRef.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "video_to_iosurface.h"

static NSString *const kVideoFileName = @"demo.mp4";
static NSString *const kPrefsVideoPathKey = @"MFTVideoPath";

@interface CameraViewController () <
	AVCaptureVideoDataOutputSampleBufferDelegate,
	UIDocumentPickerDelegate,
	PHPickerViewControllerDelegate
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
@property (nonatomic, strong) UIButton *modeButton;
@property (nonatomic, strong) dispatch_queue_t frameQueue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, strong) AVCaptureSession *session;
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
	self.titleLabel.text = @"Virtual Camera";
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

	self.pickButton = [self makeButton:@"1) Choose MP4" color:[UIColor systemBlueColor] action:@selector(onPickVideo)];
	self.startButton = [self makeButton:@"2) Start Virtual Cam" color:[UIColor systemGreenColor] action:@selector(onStart)];
	self.stopButton = [self makeButton:@"Stop" color:[UIColor systemRedColor] action:@selector(onStop)];
	self.modeButton = [self makeButton:@"Mode: Video-only (recommended)" color:[UIColor systemGrayColor] action:@selector(onToggleMode)];

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
		self.pickButton, self.startButton, self.stopButton, self.modeButton
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
		[self.modeButton.heightAnchor constraintEqualToConstant:40],
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
	NSString *mode = self.useRealCameraClock ? @"Real camera clock + replace frames" : @"Video-only (no camera permission needed)";
	if (path) {
		unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
		[self setStatus:[NSString stringWithFormat:
			@"Video ready:\n%@\nSize: %.1f MB\nMode: %@\n\n"
			@"This app will show the MP4 as camera preview.\n"
			@"Other apps (WeChat etc.) need jailbreak + tweak.",
			path, sz / 1024.0 / 1024.0, mode]];
	} else {
		[self setStatus:[NSString stringWithFormat:
			@"No video yet.\nTap \"1) Choose MP4\" to import from Files or Photos.\n\nMode: %@\n\n"
			@"Without jailbreak, virtual camera works ONLY inside this app.",
			mode]];
	}
}

#pragma mark - Actions

- (void)onPickVideo {
	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Choose MP4 source"
								       message:nil
								preferredStyle:UIAlertControllerStyleActionSheet];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Files / Browse" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		[self pickFromDocuments];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Photo Library" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		[self pickFromPhotos];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	if (sheet.popoverPresentationController) {
		sheet.popoverPresentationController.sourceView = self.pickButton;
		sheet.popoverPresentationController.sourceRect = self.pickButton.bounds;
	}
	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)pickFromDocuments {
	NSArray<UTType *> *types = @[ UTTypeMovie, UTTypeMPEG4Movie, UTTypeQuickTimeMovie ];
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)pickFromPhotos {
	PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
	config.filter = [PHPickerFilter videosFilter];
	config.selectionLimit = 1;
	PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)onStart {
	NSString *path = [self storedVideoPath];
	if (!path) {
		[self setStatus:@"Please choose an MP4 first."];
		[self onPickVideo];
		return;
	}
	[self startVirtualCameraWithPath:path];
}

- (void)onStop {
	[self stopVirtualCamera];
	[self refreshStatus];
	NSString *cur = self.statusLabel.text ?: @"";
	[self setStatus:[cur stringByAppendingString:@"\n\nVirtual camera stopped."]];
}

- (void)onToggleMode {
	self.useRealCameraClock = !self.useRealCameraClock;
	NSString *t = self.useRealCameraClock ? @"Mode: Real camera clock" : @"Mode: Video-only (recommended)";
	[self.modeButton setTitle:t forState:UIControlStateNormal];
	[self refreshStatus];
	if (_virtualRunning) {
		NSString *path = [self storedVideoPath];
		[self stopVirtualCamera];
		if (path) {
			[self startVirtualCameraWithPath:path];
		}
	}
}

#pragma mark - Import

- (void)importVideoFromURL:(NSURL *)url {
	if (!url) {
		[self setStatus:@"Invalid video URL"];
		return;
	}
	[self setStatus:@"Importing video..."];

	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *dest = [self targetDemoPath];
		NSError *err = nil;
		BOOL access = [url startAccessingSecurityScopedResource];

		NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&err];
		NSURL *tmpCopy = nil;
		if (!data) {
			NSFileCoordinator *coord = [[NSFileCoordinator alloc] init];
			__block NSError *coordErr = nil;
			__block NSURL *local = nil;
			[coord coordinateReadingItemAtURL:url
						 options:0
						   error:&coordErr
					      byAccessor:^(NSURL *newURL) {
						      NSString *tmp = [NSTemporaryDirectory()
							      stringByAppendingPathComponent:
								      [NSString stringWithFormat:@"import_%@.mp4",
												[[NSUUID UUID] UUIDString]]];
						      [fm removeItemAtPath:tmp error:nil];
						      if ([fm copyItemAtURL:newURL
								      toURL:[NSURL fileURLWithPath:tmp]
								      error:nil]) {
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
				[self setStatus:[NSString stringWithFormat:@"Import failed: %@",
								 err.localizedDescription ?: @"empty"]];
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
				[self setStatus:[NSString stringWithFormat:@"Write failed: %@", err.localizedDescription]];
				return;
			}
			[[NSUserDefaults standardUserDefaults] setObject:dest forKey:kPrefsVideoPathKey];
			[[NSUserDefaults standardUserDefaults] synchronize];
			[self refreshStatus];
			[self setStatus:[NSString stringWithFormat:
					 @"Import OK (%.1f MB)\n%@\n\nTap \"2) Start Virtual Cam\"",
					 data.length / 1024.0 / 1024.0, dest]];
		});
	});
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	[self importVideoFromURL:urls.firstObject];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	[self setStatus:@"File pick cancelled"];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
	[picker dismissViewControllerAnimated:YES completion:nil];
	PHPickerResult *result = results.firstObject;
	if (!result) {
		[self setStatus:@"No photo video selected"];
		return;
	}
	NSItemProvider *provider = result.itemProvider;
	NSString *type = UTTypeMovie.identifier;
	if (![provider hasItemConformingToTypeIdentifier:type]) {
		type = @"public.movie";
	}
	[self setStatus:@"Exporting from Photos..."];
	[provider loadFileRepresentationForTypeIdentifier:type
				     completionHandler:^(NSURL *url, NSError *error) {
					     if (!url || error) {
						     dispatch_async(dispatch_get_main_queue(), ^{
							     [self setStatus:[NSString stringWithFormat:@"Photos export failed: %@",
									      error.localizedDescription ?: @"?"]];
						     });
						     return;
					     }
					     NSString *tmp = [NSTemporaryDirectory()
						     stringByAppendingPathComponent:
							     [NSString stringWithFormat:@"photo_%@.mp4",
											[[NSUUID UUID] UUIDString]]];
					     NSError *copyErr = nil;
					     [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
					     BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:url
											       toURL:[NSURL fileURLWithPath:tmp]
											       error:&copyErr];
					     dispatch_async(dispatch_get_main_queue(), ^{
						     if (!ok) {
							     [self setStatus:[NSString stringWithFormat:@"Copy failed: %@",
									      copyErr.localizedDescription]];
							     return;
						     }
						     [self importVideoFromURL:[NSURL fileURLWithPath:tmp]];
					     });
				     }];
}

#pragma mark - Pipeline

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
		if (s0) {
			CFRelease(s0);
		}
		if (s1) {
			CFRelease(s1);
		}
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
	if (!_vti) {
		return NO;
	}
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
	if (!front) {
		return;
	}
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
					 @"Virtual cam RUNNING\nVideo: %@\nFrame: #%llu\n\n"
					 @"* Preview is virtual inside THIS app only\n"
					 @"* Other apps need jailbreak tweak",
					 base, (unsigned long long)gen]];
		}
	});
}

- (void)startVirtualCameraWithPath:(NSString *)path {
	[self stopVirtualCamera];
	if (![self openPipelineAtPath:path]) {
		[self setStatus:[NSString stringWithFormat:@"Cannot open video (unsupported?):\n%@", path]];
		return;
	}
	_virtualRunning = YES;
	[self setStatus:@"Virtual camera started..."];

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
	dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC / 30),
				  (uint64_t)(NSEC_PER_SEC / 100));
	__weak typeof(self) weakSelf = self;
	dispatch_source_set_event_handler(t, ^{
		__strong typeof(weakSelf) self = weakSelf;
		if (!self || !self->_virtualRunning) {
			return;
		}
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
				[self setStatus:@"Camera denied; fallback to video-only mode"];
				self.useRealCameraClock = NO;
				[self.modeButton setTitle:@"Mode: Video-only (recommended)" forState:UIControlStateNormal];
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
	if (self.session) {
		return;
	}
	self.session = [[AVCaptureSession alloc] init];
	if ([self.session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
		self.session.sessionPreset = AVCaptureSessionPreset1280x720;
	}
	AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
	if (!device) {
		return;
	}
	NSError *err = nil;
	AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
	if (!input) {
		return;
	}
	if ([self.session canAddInput:input]) {
		[self.session addInput:input];
	}
	self.dataOutput = [[AVCaptureVideoDataOutput alloc] init];
	self.dataOutput.alwaysDiscardsLateVideoFrames = YES;
	self.dataOutput.videoSettings = @{
		(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
	};
	[self.dataOutput setSampleBufferDelegate:self queue:self.camQueue];
	if ([self.session canAddOutput:self.dataOutput]) {
		[self.session addOutput:self.dataOutput];
	}
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
		ctx = [CIContext contextWithOptions:@{ kCIContextWorkingColorSpace : [NSNull null] }];
	});
	CVPixelBufferLockBaseAddress(dst, 0);
	[ctx render:image toCVPixelBuffer:dst bounds:CGRectMake(0, 0, dw, dh) colorSpace:nil];
	CVPixelBufferUnlockBaseAddress(dst, 0);
}

- (void)captureOutput:(AVCaptureOutput *)output
	didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
	       fromConnection:(AVCaptureConnection *)connection {
	(void)output;
	(void)connection;
	if (!_virtualRunning || !self.useRealCameraClock) {
		return;
	}
	__block IOSurfaceRef front = NULL;
	dispatch_sync(self.frameQueue, ^{
		if (![self advanceFrame]) {
			return;
		}
		front = _surfaces[_frontIdx];
		if (front) {
			CFRetain(front);
		}
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
		self.videoLayer.contents = (__bridge id)front;
		[CATransaction commit];
		CFRelease(front);
	});
}

@end
