/*
 * VirtualCamDemo v0.3 — TrollStore / 未越狱
 *
 * 能做：在本 App 内选择 MP4，全屏预览（当作「虚拟摄像头画面」自测）
 * 不能做：替换系统「相机」App、微信、抖音等（无越狱 + 注入权限做不到）
 *
 * 巨魔(TrollStore) = 永久签名安装，不等于越狱，不能 hook 其它进程。
 */

#import "CameraViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kVideoFileName = @"demo.mp4";
static NSString *const kPrefsVideoPathKey = @"MFTVideoPath";
static NSString *const kPrefsDidShowLimitKey = @"MFTDidShowLimitAlert";

@interface CameraViewController () <UIDocumentPickerDelegate, PHPickerViewControllerDelegate>
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *warnLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIView *previewHost;
@property (nonatomic, strong) AVPlayer *player;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UIButton *pickButton;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIButton *stopButton;
@property (nonatomic, strong) id loopObserver;
@end

@implementation CameraViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.10 alpha:1.0];
	[self buildUI];
	[self refreshStatus];
	[self showLimitAlertIfNeeded];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	self.playerLayer.frame = self.previewHost.bounds;
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self stopPlayback];
}

- (void)dealloc {
	[self stopPlayback];
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
	self.titleLabel.text = @"虚拟摄像头 (本App)";
	self.titleLabel.textColor = UIColor.whiteColor;
	self.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
	self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.titleLabel];

	self.warnLabel = [[UILabel alloc] init];
	self.warnLabel.numberOfLines = 0;
	self.warnLabel.textColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.35 alpha:1.0];
	self.warnLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	self.warnLabel.text =
		@"重要：手机未越狱时，无法替换系统「相机」或微信摄像头。\n"
		@"巨魔只能安装App，不能注入其它软件。\n"
		@"本App只能在「本页面」播放你选的MP4。";
	self.warnLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.warnLabel];

	self.statusLabel = [[UILabel alloc] init];
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.textColor = [UIColor colorWithWhite:0.88 alpha:1];
	self.statusLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.statusLabel];

	self.previewHost = [[UIView alloc] init];
	self.previewHost.backgroundColor = UIColor.blackColor;
	self.previewHost.layer.cornerRadius = 12;
	self.previewHost.clipsToBounds = YES;
	self.previewHost.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:self.previewHost];

	self.pickButton = [self makeButton:@"1. 选择 / 上传 MP4" color:[UIColor systemBlueColor] action:@selector(onPick)];
	self.startButton = [self makeButton:@"2. 在本App播放虚拟画面" color:[UIColor systemGreenColor] action:@selector(onStart)];
	self.stopButton = [self makeButton:@"停止播放" color:[UIColor systemRedColor] action:@selector(onStop)];

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
		self.pickButton, self.startButton, self.stopButton
	]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 10;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];

	UILayoutGuide *g = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[self.titleLabel.topAnchor constraintEqualToAnchor:g.topAnchor constant:10],
		[self.titleLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[self.titleLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],

		[self.warnLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:8],
		[self.warnLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[self.warnLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],

		[self.statusLabel.topAnchor constraintEqualToAnchor:self.warnLabel.bottomAnchor constant:8],
		[self.statusLabel.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[self.statusLabel.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],

		[self.previewHost.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:10],
		[self.previewHost.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[self.previewHost.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
		[self.previewHost.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:0.40],

		[stack.topAnchor constraintEqualToAnchor:self.previewHost.bottomAnchor constant:14],
		[stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
		[stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
		[self.pickButton.heightAnchor constraintEqualToConstant:50],
		[self.startButton.heightAnchor constraintEqualToConstant:50],
		[self.stopButton.heightAnchor constraintEqualToConstant:44],
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
	if (path) {
		unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
		[self setStatus:[NSString stringWithFormat:
			@"已保存视频:\n%@\n大小: %.2f MB\n\n点「2. 在本App播放虚拟画面」开始。",
			path.lastPathComponent, sz / 1024.0 / 1024.0]];
	} else {
		[self setStatus:@"还没有视频。\n请点「1. 选择 / 上传 MP4」。"];
	}
}

- (void)showLimitAlertIfNeeded {
	NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
	if ([ud boolForKey:kPrefsDidShowLimitKey]) {
		return;
	}
	[ud setBool:YES forKey:kPrefsDidShowLimitKey];
	[ud synchronize];

	UIAlertController *alert =
		[UIAlertController alertControllerWithTitle:@"无法替换系统相机"
						    message:
							    @"你的 iPhone 只有巨魔、没有越狱。\n\n"
							    @"• 巨魔：只能安装 App\n"
							    @"• 越狱：才能 hook 系统相机/微信\n\n"
							    @"因此打开系统「相机」看到的一定还是真实画面，"
							    @"这不是软件坏了，是 iOS 安全限制。\n\n"
							    @"本 App 只能在自己的预览框里播放你上传的 MP4。"
						 preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"我知道了" style:UIAlertActionStyleDefault handler:nil]];
	dispatch_async(dispatch_get_main_queue(), ^{
		[self presentViewController:alert animated:YES completion:nil];
	});
}

#pragma mark - Actions

- (void)onPick {
	UIAlertController *sheet =
		[UIAlertController alertControllerWithTitle:@"选择 MP4"
						    message:nil
					     preferredStyle:UIAlertControllerStyleActionSheet];
	[sheet addAction:[UIAlertAction actionWithTitle:@"文件 / 浏览" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		[self pickFromFiles];
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

- (void)pickFromFiles {
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
		[self setStatus:@"请先选择 MP4"];
		[self onPick];
		return;
	}
	[self startPlaybackWithPath:path];
}

- (void)onStop {
	[self stopPlayback];
	[self refreshStatus];
	NSString *s = self.statusLabel.text ?: @"";
	[self setStatus:[s stringByAppendingString:@"\n\n已停止。"]];
}

#pragma mark - Import

- (void)importVideoFromURL:(NSURL *)url {
	if (!url) {
		[self setStatus:@"无效文件"];
		return;
	}
	[self setStatus:@"正在导入…"];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *dest = [self targetDemoPath];
		NSError *err = nil;
		BOOL scoped = [url startAccessingSecurityScopedResource];

		NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&err];
		if (!data) {
			NSString *tmp = [NSTemporaryDirectory()
				stringByAppendingPathComponent:
					[NSString stringWithFormat:@"imp_%@.mp4", [[NSUUID UUID] UUIDString]]];
			[fm removeItemAtPath:tmp error:nil];
			if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:&err]) {
				data = [NSData dataWithContentsOfFile:tmp options:0 error:&err];
				[fm removeItemAtPath:tmp error:nil];
			}
		}
		if (scoped) {
			[url stopAccessingSecurityScopedResource];
		}

		if (!data || data.length < 64) {
			dispatch_async(dispatch_get_main_queue(), ^{
				[self setStatus:[NSString stringWithFormat:@"导入失败: %@",
								 err.localizedDescription ?: @"文件太小/无法读取"]];
			});
			return;
		}

		[fm createDirectoryAtPath:[self documentsDir] withIntermediateDirectories:YES attributes:nil error:nil];
		[fm removeItemAtPath:dest error:nil];
		BOOL ok = [data writeToFile:dest options:NSDataWritingAtomic error:&err];

		dispatch_async(dispatch_get_main_queue(), ^{
			if (!ok) {
				[self setStatus:[NSString stringWithFormat:@"保存失败: %@", err.localizedDescription]];
				return;
			}
			[[NSUserDefaults standardUserDefaults] setObject:dest forKey:kPrefsVideoPathKey];
			[[NSUserDefaults standardUserDefaults] synchronize];
			[self refreshStatus];
			[self setStatus:[NSString stringWithFormat:
					 @"导入成功 %.2f MB\n%@\n\n请点「2. 在本App播放虚拟画面」",
					 data.length / 1024.0 / 1024.0, dest.lastPathComponent]];
		});
	});
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	[self importVideoFromURL:urls.firstObject];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
	[self setStatus:@"已取消"];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
	[picker dismissViewControllerAnimated:YES completion:nil];
	PHPickerResult *r = results.firstObject;
	if (!r) {
		[self setStatus:@"未选择视频"];
		return;
	}
	NSItemProvider *p = r.itemProvider;
	NSString *type = UTTypeMovie.identifier;
	if (![p hasItemConformingToTypeIdentifier:type]) {
		type = @"public.movie";
	}
	[self setStatus:@"从相册导出…"];
	[p loadFileRepresentationForTypeIdentifier:type
				  completionHandler:^(NSURL *url, NSError *error) {
					  if (!url || error) {
						  dispatch_async(dispatch_get_main_queue(), ^{
							  [self setStatus:[NSString stringWithFormat:@"相册失败: %@",
									   error.localizedDescription ?: @"?"]];
						  });
						  return;
					  }
					  NSString *tmp = [NSTemporaryDirectory()
						  stringByAppendingPathComponent:
							  [NSString stringWithFormat:@"ph_%@.mp4",
										     [[NSUUID UUID] UUIDString]]];
					  NSError *ce = nil;
					  [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
					  BOOL ok = [[NSFileManager defaultManager] copyItemAtURL:url
											    toURL:[NSURL fileURLWithPath:tmp]
											    error:&ce];
					  dispatch_async(dispatch_get_main_queue(), ^{
						  if (!ok) {
							  [self setStatus:[NSString stringWithFormat:@"拷贝失败: %@",
									   ce.localizedDescription]];
							  return;
						  }
						  [self importVideoFromURL:[NSURL fileURLWithPath:tmp]];
					  });
				  }];
}

#pragma mark - Playback (in-app virtual preview)

- (void)stopPlayback {
	if (self.loopObserver) {
		[[NSNotificationCenter defaultCenter] removeObserver:self.loopObserver];
		self.loopObserver = nil;
	}
	[self.player pause];
	self.player = nil;
	[self.playerLayer removeFromSuperlayer];
	self.playerLayer = nil;
}

- (void)startPlaybackWithPath:(NSString *)path {
	[self stopPlayback];

	NSURL *url = [NSURL fileURLWithPath:path];
	AVAsset *asset = [AVAsset assetWithURL:url];
	if (!asset) {
		[self setStatus:@"无法读取视频资源"];
		return;
	}

	AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
	self.player = [AVPlayer playerWithPlayerItem:item];
	self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

	self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
	self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
	self.playerLayer.frame = self.previewHost.bounds;
	[self.previewHost.layer addSublayer:self.playerLayer];

	__weak typeof(self) weakSelf = self;
	self.loopObserver =
		[[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
								  object:item
								   queue:[NSOperationQueue mainQueue]
							      usingBlock:^(NSNotification *note) {
								      __strong typeof(weakSelf) self = weakSelf;
								      [self.player seekToTime:kCMTimeZero];
								      [self.player play];
							      }];

	[self.player play];
	[self setStatus:[NSString stringWithFormat:
			 @"正在本App预览区播放:\n%@\n(循环)\n\n"
			 @"系统「相机」App 不会变——未越狱无法替换。",
			 path.lastPathComponent]];
}

@end
