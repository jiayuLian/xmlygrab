#import "AppDelegate.h"
#import "RootVC.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[RootVC alloc] init];
    [self.window makeKeyAndVisible];
    // 挂机必备：别让屏幕睡
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    return YES;
}

@end
