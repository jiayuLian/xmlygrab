//
//  HIDTouch.h
//  全局触摸注入（TrollStore 私有 entitlement）
//  作用：不启用无障碍、不 hook 进程，直接在 HID 层合成触摸事件。
//        官方喜马 App 收不到任何"自动化"信号，只能看到一次真实点击。
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface HIDTouch : NSObject
+ (BOOL)available;                       // 私有符号是否齐全
+ (void)tapPoint:(CGPoint)p;             // 逻辑坐标（point），内部换算成归一化
+ (void)tapPoint:(CGPoint)p hold:(NSTimeInterval)sec;
@end
