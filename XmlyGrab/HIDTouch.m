//
//  HIDTouch.m
//  用 IOKit 私有 API 合成 digitizer 事件。所有符号走 dlsym，避免链接期找不到。
//
//  iOS 15 上要跨 App 生效，三件事缺一不可：
//    1. entitlement com.apple.private.hid.client.event-dispatch
//    2. client 用 Admin 类型（Monitor 只能监听不能派发）
//    3. 给 client 打开 AddDigitizerUsagePage，否则事件被当成外接数位板丢掉
//
#import "HIDTouch.h"
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;

#define kTransducerHand       3
#define kMaskRange            0x1
#define kMaskTouch            0x2
#define kClientTypeAdmin      2

typedef IOHIDEventRef (*FingerEventFn)(
    CFAllocatorRef, AbsoluteTime, uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, uint32_t options);

typedef IOHIDEventRef (*DigitizerEventFn)(
    CFAllocatorRef, AbsoluteTime, int type, uint32_t index, uint32_t identifier,
    uint32_t eventMask, uint32_t options,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
    Boolean range, Boolean touch, uint32_t options2);

typedef void (*SetIntegerValueFn)(IOHIDEventRef, int field, CFTypeRef value);
typedef IOHIDEventSystemClientRef (*CreateClientFn)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*CreateClientTypeFn)(CFAllocatorRef, int, CFDictionaryRef);
typedef void (*SetPropertyFn)(IOHIDEventSystemClientRef, CFTypeRef, CFTypeRef);
typedef void (*DispatchEventFn)(IOHIDEventSystemClientRef, IOHIDEventRef);

static FingerEventFn    pFinger    = NULL;
static DigitizerEventFn pDigitizer = NULL;
static SetIntegerValueFn pSetInt   = NULL;
static CreateClientTypeFn pCreateT = NULL;
static CreateClientFn   pCreate    = NULL;
static SetPropertyFn    pSetProp   = NULL;
static DispatchEventFn  pDispatch  = NULL;
static IOHIDEventSystemClientRef gClient = NULL;
static dispatch_once_t gOnce;
static uint32_t gFingerId = 1;

@implementation HIDTouch

+ (void)load {
    dispatch_once(&gOnce, ^{
        void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) h = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!h) { NSLog(@"[HID] IOKit 打不开: %s", dlerror()); return; }

        pFinger    = (FingerEventFn)dlsym(h, "IOHIDEventCreateDigitizerFingerEvent");
        pDigitizer = (DigitizerEventFn)dlsym(h, "IOHIDEventCreateDigitizerEvent");
        pSetInt    = (SetIntegerValueFn)dlsym(h, "IOHIDEventSetIntegerValue");
        pCreateT   = (CreateClientTypeFn)dlsym(h, "IOHIDEventSystemClientCreateWithType");
        pCreate    = (CreateClientFn)dlsym(h, "IOHIDEventSystemClientCreate");
        pSetProp   = (SetPropertyFn)dlsym(h, "IOHIDEventSystemClientSetProperty");
        pDispatch  = (DispatchEventFn)dlsym(h, "IOHIDEventSystemClientDispatchEvent");

        NSLog(@"[HID] finger=%p digitizer=%p createT=%p dispatch=%p",
              pFinger, pDigitizer, pCreateT, pDispatch);

        if (pCreateT) {
            gClient = pCreateT(kCFAllocatorDefault, kClientTypeAdmin, NULL);
        }
        if (!gClient && pCreate) {
            gClient = pCreate(kCFAllocatorDefault);
        }
        if (gClient && pSetProp) {
            pSetProp(gClient, CFSTR("AddDigitizerUsagePage"), kCFBooleanTrue);
        }
        if (!gClient) NSLog(@"[HID] client 创建失败");
    });
}

+ (BOOL)available {
    [self load];
    return ((pFinger || pDigitizer) && pDispatch && gClient) ? YES : NO;
}

// mach_absolute_time() 给的是 uint64，但 IOHID 接口要 AbsoluteTime（struct UnsignedWide）。
// 直接强转在 arm64 上会因类型不兼容编译失败，必须拆成 hi/lo。
static AbsoluteTime absTimeNow(void) {
    uint64_t t = mach_absolute_time();
    AbsoluteTime a;
    a.hi = (UInt32)(t >> 32);
    a.lo = (UInt32)(t & 0xFFFFFFFFu);
    return a;
}

// 归一化坐标：iOS digitizer 要求 0~1
static void emit(double nx, double ny, BOOL down) {
    if (!pDispatch || !gClient) return;
    AbsoluteTime t = absTimeNow();
    IOHIDEventRef ev = NULL;

    if (pFinger) {
        ev = pFinger(kCFAllocatorDefault, t, 0, gFingerId,
                     kMaskRange | kMaskTouch,
                     nx, ny, 0, 0, 0,
                     down ? 1 : 0, down ? 1 : 0, 0);
    }
    if (!ev && pDigitizer) {
        ev = pDigitizer(kCFAllocatorDefault, t, kTransducerHand, 0, gFingerId,
                        kMaskRange | kMaskTouch, 0,
                        nx, ny, 0, 0, 0,
                        down ? 1 : 0, down ? 1 : 0, 0);
    }
    if (!ev) { NSLog(@"[HID] 事件创建失败"); return; }

    pDispatch(gClient, ev);
    CFRelease(ev);
}

+ (void)tapPoint:(CGPoint)p {
    [self tapPoint:p hold:0.05];
}

+ (void)tapPoint:(CGPoint)p hold:(NSTimeInterval)sec {
    if (![self available]) { NSLog(@"[HID] 不可用，检查 entitlement"); return; }
    CGSize s = [UIScreen mainScreen].bounds.size;
    double nx = p.x / s.width;
    double ny = p.y / s.height;
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) {
        NSLog(@"[HID] 坐标越界 %@ / %.0fx%.0f", NSStringFromCGPoint(p), s.width, s.height);
        return;
    }
    // 每次用新 identity，避免系统把连续点击当成同一个手指
    gFingerId++;
    if (gFingerId == 0) gFingerId = 1;

    emit(nx, ny, YES);
    if (sec > 0.01) usleep((useconds_t)(sec * 1e6));
    emit(nx, ny, NO);
    NSLog(@"[HID] tap %.0f,%.0f id=%u", p.x, p.y, gFingerId);
}

@end
