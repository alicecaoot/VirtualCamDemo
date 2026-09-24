#import "AppDelegate.h"
#import "CameraViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	(void)application;
	(void)launchOptions;

	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.backgroundColor = UIColor.blackColor;
	self.window.rootViewController = [[CameraViewController alloc] init];
	[self.window makeKeyAndVisible];
	return YES;
}

@end
