//
//  RootVC.m — 喜马抢兑 iOS 端
//
//  核心思路：不伪造任何网络请求。官方 App 自己发，盾/票/指纹全原生。
//  本 App 只做两件事：到点拉起官方 App、用 HID 层触摸把按钮按顺序点下去。
//
//  为什么不用无障碍 / 不 hook：喜马带 rewardShieldAccessibilityClick（屏蔽无障碍点击）
//  和 tme::detect::Frida / Xposed 检测。IOHIDEventSystemClientDispatchEvent 走的是
//  系统输入层，App 侧收到的事件和真人手指完全一样。
//
#import "RootVC.h"
#import "HIDTouch.h"
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>

#pragma mark - 步骤模型

typedef NS_ENUM(NSInteger, StepKind) {
    StepKindLaunch = 0,   // 拉起喜马
    StepKindTap,          // 点一下坐标
    StepKindWait,         // 干等 N 秒（看广告就靠它）
    StepKindUntil,        // 等到当天某个时刻（时:分:秒）
};

@interface GrabStep : NSObject
@property (nonatomic, assign) StepKind kind;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, assign) CGFloat x, y;
@property (nonatomic, assign) double wait;        // Tap 后延迟 / Wait 秒数
@property (nonatomic, assign) NSInteger untilSec; // 当天第几秒
@property (nonatomic, assign) BOOL recorded;
@end

@implementation GrabStep

- (NSString *)kindName {
    switch (self.kind) {
        case StepKindLaunch: return @"拉起";
        case StepKindTap:    return @"点击";
        case StepKindWait:   return @"等待";
        case StepKindUntil:  return @"等到";
    }
    return @"?";
}

- (NSString *)desc {
    switch (self.kind) {
        case StepKindLaunch: return @"打开喜马";
        case StepKindTap:
            if (!self.recorded) return @"未录坐标";
            return [NSString stringWithFormat:@"(%.0f,%.0f) 后等 %.1fs", self.x, self.y, self.wait];
        case StepKindWait:
            return [NSString stringWithFormat:@"%.0f 秒", self.wait];
        case StepKindUntil:
            return [NSString stringWithFormat:@"%02ld:%02ld:%02ld",
                    (long)(self.untilSec / 3600), (long)(self.untilSec % 3600 / 60),
                    (long)(self.untilSec % 60)];
    }
    return @"";
}

- (NSDictionary *)dict {
    return @{@"k": @(self.kind), @"n": self.name ?: @"", @"x": @(self.x), @"y": @(self.y),
             @"w": @(self.wait), @"u": @(self.untilSec), @"r": @(self.recorded)};
}

+ (instancetype)fromDict:(NSDictionary *)m {
    GrabStep *s = [GrabStep new];
    s.kind = [m[@"k"] integerValue];
    s.name = m[@"n"] ?: @"";
    s.x = [m[@"x"] doubleValue];
    s.y = [m[@"y"] doubleValue];
    s.wait = [m[@"w"] doubleValue];
    s.untilSec = [m[@"u"] integerValue];
    s.recorded = [m[@"r"] boolValue];
    return s;
}

@end

#pragma mark - 图示录坐标（在相册截图上点）

@interface ShotPickerVC : UIViewController <PHPickerViewControllerDelegate>
@property (nonatomic, copy) void (^onPoint)(CGPoint p, CGSize screenSize);
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) UIImageView *imgView;
@property (nonatomic, copy) NSString *hint;
@end

@implementation ShotPickerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    UIButton *pick = [UIButton buttonWithType:UIButtonTypeSystem];
    pick.frame = CGRectMake(20, 50, self.view.bounds.size.width - 40, 40);
    [pick setTitle:@"① 从相册选一张喜马截图" forState:UIControlStateNormal];
    [pick setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    pick.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
    pick.layer.cornerRadius = 8;
    [pick addTarget:self action:@selector(doPick) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:pick];

    UILabel *tip = [[UILabel alloc] initWithFrame:CGRectMake(20, 96, self.view.bounds.size.width - 40, 40)];
    tip.numberOfLines = 2;
    tip.textColor = [UIColor lightGrayColor];
    tip.font = [UIFont systemFontOfSize:12];
    tip.text = @"② 在图上点一下你要按的按钮位置\n（截图坐标会按屏幕比例换算，跨机型也准）";
    [self.view addSubview:tip];

    self.imgView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 145,
                        self.view.bounds.size.width, self.view.bounds.size.height - 145)];
    self.imgView.contentMode = UIViewContentModeScaleAspectFit;
    self.imgView.userInteractionEnabled = YES;
    [self.view addSubview:self.imgView];

    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
    [self.imgView addGestureRecognizer:g];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(self.view.bounds.size.width - 70, 40, 60, 34);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeSelf) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
}

- (void)closeSelf { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)doPick {
    PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
    cfg.filter = PHPickerFilter.imagesFilter;
    cfg.selectionLimit = 1;
    PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:cfg];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (!results.count) return;
    NSItemProvider *prov = results.firstObject.itemProvider;
    if (![prov canLoadObjectOfClass:UIImage.class]) return;
    __weak typeof(self) ws = self;
    [prov loadObjectOfClass:UIImage.class completionHandler:^(id<NSItemProviderReading> obj, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([obj isKindOfClass:UIImage.class]) ws.imgView.image = (UIImage *)obj;
        });
    }];
}

- (void)onTap:(UITapGestureRecognizer *)g {
    if (!self.imgView.image) { return; }
    CGPoint p = [g locationInView:self.imgView];
    // imageView 是 aspectFit，先扣掉黑边，再按图片原始比例换算成"逻辑屏幕点"
    CGSize viewSize = self.imgView.bounds.size;
    CGSize imgSize = self.imgView.image.size;
    if (imgSize.width <= 0 || imgSize.height <= 0) return;
    CGFloat scale = MIN(viewSize.width / imgSize.width, viewSize.height / imgSize.height);
    CGFloat dw = imgSize.width * scale, dh = imgSize.height * scale;
    CGFloat ox = (viewSize.width - dw) / 2.0, oy = (viewSize.height - dh) / 2.0;
    if (p.x < ox || p.x > ox + dw || p.y < oy || p.y > oy + dh) return;   // 点在黑边上忽略
    CGFloat rx = (p.x - ox) / dw;      // 0~1
    CGFloat ry = (p.y - oy) / dh;
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGPoint logical = CGPointMake(rx * scr.width, ry * scr.height);
    void (^cb)(CGPoint, CGSize) = self.onPoint;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(logical, scr); }];
}

@end

#pragma mark - 全屏直接点（调试用）

@interface RawTapVC : UIViewController
@property (nonatomic, copy) void (^onPoint)(CGPoint p);
@end

@implementation RawTapVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(0, 90, self.view.bounds.size.width, 50)];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 2;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    l.text = @"在你自己 App 的界面上点一下\n（看不到喜马界面时用相册模式）";
    [self.view addSubview:l];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    CGPoint p = [[touches anyObject] locationInView:self.view];
    void (^cb)(CGPoint) = self.onPoint;
    [self dismissViewControllerAnimated:YES completion:^{ if (cb) cb(p); }];
}
@end

#pragma mark - 主界面

@interface RootVC () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) NSMutableArray<GrabStep *> *steps;
@property (nonatomic, strong) NSMutableArray<NSString *> *times;   // "HH:mm"
@property (nonatomic, strong) NSMutableSet<NSString *> *fired;    // 本轮已触发的时刻
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UITextView  *logView;
@property (nonatomic, strong) UILabel     *status;
@property (nonatomic, strong) NSTimer     *ticker;
@property (nonatomic, assign) BOOL        running;
@property (nonatomic, assign) UIBackgroundTaskIdentifier bgTask;
@property (nonatomic, strong) AVAudioPlayer *silent;

// 声明在这，避免调用点看不到定义
- (void)log:(NSString *)fmt, ...;
- (void)saveState;
- (void)loadState;
- (void)buildUI;
- (void)startKeepAlive;
- (void)defaultSteps;
- (void)onBtn:(UIButton *)b;
- (void)onTick;
- (void)performGrab:(NSString *)why;
- (void)finishGrab;
- (void)runStep:(NSInteger)i;
- (void)after:(double)sec then:(void (^)(void))blk;
- (void)launchXimalaya;
- (void)recordWithShot:(NSInteger)i;
- (void)recordRaw:(NSInteger)i;
- (void)editWait:(NSInteger)i;
- (void)editUntil:(NSInteger)i;
- (void)editTimes;
- (NSInteger)secondOfDay:(NSDate *)d;
- (NSInteger)timeStrToSec:(NSString *)t;
- (NSString *)nextTimeDesc;
@end

@implementation RootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.fired = [NSMutableSet set];
    self.bgTask = UIBackgroundTaskInvalid;
    [self loadState];
    [self buildUI];
    [self startKeepAlive];

    // 0.2 秒一跑，抢兑要的是秒级准头
    self.ticker = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self
                                                 selector:@selector(onTick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.ticker forMode:NSRunLoopCommonModes];

    [self log:[NSString stringWithFormat:@"HID 注入 %@",
               [HIDTouch available] ? @"就绪" : @"不可用 —— 检查 TrollStore 是否保留 entitlements"]];
    [self log:[NSString stringWithFormat:@"屏幕 %.0fx%.0f",
               [UIScreen mainScreen].bounds.size.width, [UIScreen mainScreen].bounds.size.height]];
}

- (BOOL)prefersStatusBarHidden { return NO; }

#pragma mark 静音保活
// 切到后台后 NSTimer 会停、dispatch_after 会漂。开 audio 后台模式播一段静音，
// 让进程一直活着，HID 事件在后台也能发出去。
- (void)startKeepAlive {
    AVAudioSession *s = [AVAudioSession sharedInstance];
    [s setCategory:AVAudioSessionCategoryPlayback
       withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [s setActive:YES error:nil];

    // 生成 1 秒静音 WAV（8kHz 单声道 16bit）
    NSMutableData *d = [NSMutableData data];
    uint32_t chunk = 8000 * 2;
    uint32_t riff = 36 + chunk;
    uint32_t fmtLen = 16, sr = 8000, br = 16000;
    uint16_t pcm = 1, ch = 1, ba = 2, bits = 16;
    [d appendBytes:"RIFF" length:4];
    [d appendBytes:&riff length:4];
    [d appendBytes:"WAVEfmt " length:8];
    [d appendBytes:&fmtLen length:4];
    [d appendBytes:&pcm length:2];
    [d appendBytes:&ch length:2];
    [d appendBytes:&sr length:4];
    [d appendBytes:&br length:4];
    [d appendBytes:&ba length:2];
    [d appendBytes:&bits length:2];
    [d appendBytes:"data" length:4];
    [d appendBytes:&chunk length:4];
    [d appendData:[NSMutableData dataWithLength:chunk]];   // 全 0 = 静音

    NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"silent.wav"];
    [d writeToFile:p atomically:YES];
    self.silent = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:p] error:nil];
    self.silent.numberOfLoops = -1;
    self.silent.volume = 0.0;
    [self.silent prepareToPlay];
    [self.silent play];
}

#pragma mark 状态

- (void)loadState {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *raw = [d arrayForKey:@"steps_v2"];
    self.steps = [NSMutableArray array];
    if (raw.count) {
        for (NSDictionary *m in raw) [self.steps addObject:[GrabStep fromDict:m]];
    } else {
        [self defaultSteps];
    }
    self.times = [NSMutableArray arrayWithArray:[d arrayForKey:@"times_v2"]];
    if (!self.times.count) {
        self.times = [@[@"00:00", @"08:00", @"12:00", @"16:00", @"20:00"] mutableCopy];
    }
}

- (void)defaultSteps {
    // 顺序照着真实链路排：拉到提现页 -> 选好档位 -> 停在"到账方式"弹窗前
    // -> 等整点 -> 点"普通到账"（这一步服务端会 reserveQuota 锁额）-> 广告 -> 确认
    NSArray *def = @[
        @[@(StepKindLaunch), @"拉起喜马",        @6.0],
        @[@(StepKindTap),    @"我的",            @2.5],
        @[@(StepKindTap),    @"金币",            @3.0],
        @[@(StepKindTap),    @"提现",            @3.5],
        @[@(StepKindTap),    @"选档位(3/5/10元)", @1.8],
        @[@(StepKindUntil),  @"等到整点",         @0.0],
        @[@(StepKindTap),    @"普通到账(看1广告)", @2.0],
        @[@(StepKindWait),   @"等广告播完",       @35.0],
        @[@(StepKindTap),    @"关广告",          @2.5],
        @[@(StepKindTap),    @"确认提现",        @2.0],
    ];
    for (NSArray *a in def) {
        GrabStep *s = [GrabStep new];
        s.kind = [a[0] integerValue];
        s.name = a[1];
        s.wait = [a[2] doubleValue];
        s.untilSec = 1;                 // 默认 00:00:01
        s.recorded = (s.kind == StepKindLaunch || s.kind == StepKindWait || s.kind == StepKindUntil);
        [self.steps addObject:s];
    }
    [self saveState];
}

- (void)saveState {
    NSMutableArray *arr = [NSMutableArray array];
    for (GrabStep *s in self.steps) [arr addObject:[s dict]];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:arr forKey:@"steps_v2"];
    [d setObject:self.times forKey:@"times_v2"];
    [d synchronize];
}

#pragma mark UI

- (void)buildUI {
    CGFloat W = self.view.bounds.size.width, H = self.view.bounds.size.height;
    CGFloat top = 54;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, top, W - 32, 30)];
    title.font = [UIFont systemFontOfSize:21 weight:UIFontWeightBold];
    title.text = @"喜马抢兑";
    [self.view addSubview:title];

    self.status = [[UILabel alloc] initWithFrame:CGRectMake(16, top + 30, W - 32, 18)];
    self.status.font = [UIFont systemFontOfSize:12];
    self.status.textColor = [UIColor secondaryLabelColor];
    self.status.text = @"待机";
    [self.view addSubview:self.status];

    NSArray *names = @[@"全录坐标", @"执行一次", @"定时开关"];
    CGFloat bw = (W - 32 - 2 * 8) / 3.0;
    for (int i = 0; i < names.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(16 + i * (bw + 8), top + 54, bw, 36);
        b.tag = i;
        b.backgroundColor = [UIColor secondarySystemBackgroundColor];
        b.layer.cornerRadius = 9;
        b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        [b setTitle:names[i] forState:UIControlStateNormal];
        [b addTarget:self action:@selector(onBtn:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:b];
    }

    CGFloat ty = top + 98;
    CGFloat logH = 132;
    self.table = [[UITableView alloc] initWithFrame:CGRectMake(0, ty, W, H - ty - logH - 30)
                                              style:UITableViewStylePlain];
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.rowHeight = 46;
    [self.view addSubview:self.table];

    self.logView = [[UITextView alloc] initWithFrame:CGRectMake(8, H - logH - 24, W - 16, logH)];
    self.logView.editable = NO;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    self.logView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    self.logView.layer.cornerRadius = 8;
    [self.view addSubview:self.logView];
}

- (void)log:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], s];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *old = self.logView.text ?: @"";
        // 只留最近 200 行，防止跑一晚上内存涨
        NSString *all = [line stringByAppendingString:old];
        NSArray *ls = [all componentsSeparatedByString:@"\n"];
        if (ls.count > 200) {
            all = [[ls subarrayWithRange:NSMakeRange(0, 200)] componentsJoinedByString:@"\n"];
        }
        self.logView.text = all;
    });
}

#pragma mark 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? (NSInteger)self.steps.count : (NSInteger)self.times.count;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"流程（点某行可改）" : @"定时点（点一行编辑）";
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                                reuseIdentifier:nil];
    if (ip.section == 0) {
        GrabStep *s = self.steps[ip.row];
        c.textLabel.font = [UIFont systemFontOfSize:14];
        c.textLabel.text = [NSString stringWithFormat:@"%ld. [%@] %@",
                            (long)ip.row + 1, [s kindName], s.name];
        c.detailTextLabel.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
        c.detailTextLabel.text = [s desc];
        BOOL ok = s.recorded || s.kind == StepKindLaunch || s.kind == StepKindWait || s.kind == StepKindUntil;
        c.detailTextLabel.textColor = ok ? [UIColor systemGreenColor] : [UIColor systemOrangeColor];
        c.accessoryType = (s.kind == StepKindTap) ? UITableViewCellAccessoryDisclosureIndicator
                                                  : UITableViewCellAccessoryNone;
    } else {
        c.textLabel.text = @"刷新时刻";
        c.textLabel.font = [UIFont systemFontOfSize:14];
        c.detailTextLabel.text = self.times[ip.row];
        c.detailTextLabel.font = [UIFont fontWithName:@"Menlo" size:12] ?: [UIFont systemFontOfSize:12];
        c.detailTextLabel.textColor = [UIColor labelColor];
    }
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) { [self editTimes]; return; }
    GrabStep *s = self.steps[ip.row];
    if (s.kind == StepKindTap) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:s.name
                                                                  message:@"选坐标录入方式"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
        [a addAction:[UIAlertAction actionWithTitle:@"看截图点（推荐）" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [self recordWithShot:ip.row]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"直接点本机屏幕" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [self recordRaw:ip.row]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"改延迟秒数" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [self editWait:ip.row]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = t;
        a.popoverPresentationController.sourceRect = [t rectForRowAtIndexPath:ip];
        [self presentViewController:a animated:YES completion:nil];
    } else if (s.kind == StepKindWait) {
        [self editWait:ip.row];
    } else if (s.kind == StepKindUntil) {
        [self editUntil:ip.row];
    }
}

- (void)editWait:(NSInteger)i {
    GrabStep *s = self.steps[i];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"延迟秒数"
                                                              message:s.name
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.keyboardType = UIKeyboardTypeDecimalPad;
        tf.text = [NSString stringWithFormat:@"%.1f", s.wait];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        s.wait = [a.textFields.firstObject.text doubleValue];
        [self saveState]; [self.table reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)editUntil:(NSInteger)i {
    GrabStep *s = self.steps[i];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"等到几点几分几秒"
                                                              message:@"格式 HH:mm:ss，跨天自动顺延"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.font = [UIFont fontWithName:@"Menlo" size:14];
        tf.text = [s desc];
        tf.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSArray *p = [a.textFields.firstObject.text componentsSeparatedByString:@":"];
        if (p.count == 3) {
            s.untilSec = [p[0] integerValue] * 3600 + [p[1] integerValue] * 60 + [p[2] integerValue];
            [self saveState]; [self.table reloadData];
        }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)editTimes {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"定时点"
                                                              message:@"HH:mm，逗号分隔。脚本会在整点前 20 秒启动"
                                                       preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = [self.times componentsJoinedByString:@","];
        tf.font = [UIFont fontWithName:@"Menlo" size:13];
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *p in [a.textFields.firstObject.text componentsSeparatedByString:@","]) {
            NSString *t = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length == 5 && [t characterAtIndex:2] == ':') {
                NSInteger h = [[t substringToIndex:2] integerValue];
                NSInteger m = [[t substringFromIndex:3] integerValue];
                if (h >= 0 && h < 24 && m >= 0 && m < 60) {
                    [out addObject:[NSString stringWithFormat:@"%02ld:%02ld", (long)h, (long)m]];
                }
            }
        }
        if (out.count) { self.times = out; [self saveState]; [self.table reloadData]; }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark 录坐标

- (void)recordWithShot:(NSInteger)i {
    GrabStep *s = self.steps[i];
    ShotPickerVC *v = [[ShotPickerVC alloc] init];
    v.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak typeof(self) ws = self;
    v.onPoint = ^(CGPoint p, CGSize scr) {
        s.x = p.x; s.y = p.y; s.recorded = YES;
        [ws saveState];
        [ws.table reloadData];
        [ws log:@"%@ → (%.0f, %.0f) / 屏幕 %.0fx%.0f", s.name, p.x, p.y, scr.width, scr.height];
    };
    [self presentViewController:v animated:YES completion:nil];
}

- (void)recordRaw:(NSInteger)i {
    GrabStep *s = self.steps[i];
    RawTapVC *v = [[RawTapVC alloc] init];
    v.modalPresentationStyle = UIModalPresentationOverFullScreen;
    __weak typeof(self) ws = self;
    v.onPoint = ^(CGPoint p) {
        s.x = p.x; s.y = p.y; s.recorded = YES;
        [ws saveState]; [ws.table reloadData];
        [ws log:@"%@ → (%.0f, %.0f)", s.name, p.x, p.y];
    };
    [self presentViewController:v animated:YES completion:nil];
}

#pragma mark 按钮

- (void)onBtn:(UIButton *)b {
    if (b.tag == 0) {
        for (NSInteger i = 0; i < (NSInteger)self.steps.count; i++) {
            if (self.steps[i].kind == StepKindTap && !self.steps[i].recorded) {
                [self recordWithShot:i];
                return;
            }
        }
        [self log:@"所有点击步都已录过坐标"];
    } else if (b.tag == 1) {
        if (self.running) { [self log:@"正在跑，先等它结束"]; return; }
        [self performGrab:@"手动"];
    } else {
        BOOL on = ![[NSUserDefaults standardUserDefaults] boolForKey:@"auto_v2"];
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"auto_v2"];
        self.fired = [NSMutableSet set];
        [self log:@"定时%@", on ? @"已开" : @"已关"];
    }
}

#pragma mark 时间工具

- (NSInteger)secondOfDay:(NSDate *)d {
    NSDateComponents *c = [[NSCalendar currentCalendar]
        components:NSCalendarUnitHour | NSCalendarUnitMinute | NSCalendarUnitSecond fromDate:d];
    return c.hour * 3600 + c.minute * 60 + c.second;
}

- (NSInteger)timeStrToSec:(NSString *)t {
    NSArray *p = [t componentsSeparatedByString:@":"];
    if (p.count < 2) return -1;
    return [p[0] integerValue] * 3600 + [p[1] integerValue] * 60;
}

- (NSString *)nextTimeDesc {
    NSInteger now = [self secondOfDay:[NSDate date]];
    NSInteger best = 86400, bi = -1;
    for (NSInteger i = 0; i < (NSInteger)self.times.count; i++) {
        NSInteger t = [self timeStrToSec:self.times[i]];
        NSInteger d = t - now;
        if (d <= 0) d += 86400;
        if (d < best) { best = d; bi = i; }
    }
    if (bi < 0) return nil;
    NSInteger d = best;
    return [NSString stringWithFormat:@"%@（%ld 分 %ld 秒后）",
            self.times[bi], (long)(d / 60), (long)(d % 60)];
}

#pragma mark 定时

- (void)onTick {
    NSDate *now = [NSDate date];
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"HH:mm:ss";
    BOOL autoOn = [[NSUserDefaults standardUserDefaults] boolForKey:@"auto_v2"];

    if (!autoOn) {
        self.status.text = [NSString stringWithFormat:@"定时关闭 · %@", [f stringFromDate:now]];
        return;
    }
    self.status.text = [NSString stringWithFormat:@"监控中 %@ · 下一个 %@",
                        [f stringFromDate:now], [self nextTimeDesc] ?: @"-"];

    NSInteger nowSec = [self secondOfDay:now];
    for (NSString *t in self.times) {
        NSInteger target = [self timeStrToSec:t];
        if (target < 0) continue;
        NSInteger left = target - nowSec;
        if (left < -43200) left += 86400;        // 只处理半天内的跨天，避免凌晨算成明天
        // 提前 20 秒启动，走完前 4 步刚好卡在整点；过了 5 秒内仍补跑一次
        if (left <= 20 && left >= -5 && ![self.fired containsObject:t]) {
            [self.fired addObject:t];
            [self log:@"命中 %@（提前 %ld 秒）", t, (long)left];
            [self performGrab:t];
            break;
        }
    }
    // 过点的时刻从集合里清掉，第二天还能再触发
    if (self.fired.count && nowSec % 300 < 1) {
        [self.fired removeAllObjects];
    }
}

#pragma mark 执行引擎

- (void)performGrab:(NSString *)why {
    if (self.running) return;
    self.running = YES;
    self.curIndex = 0;
    [self log:@"==== 开始（%@）====", why];

    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self log:@"注意：App 不在前台，定时器可能不准"];
    }

    self.bgTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{}];
    [self runStep:0];
}

- (void)finishGrab {
    [self log:@"==== 流程结束 ===="];
    self.running = NO;
    if (self.bgTask != UIBackgroundTaskInvalid) {
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
    }
}

- (void)runStep:(NSInteger)i {
    if (i >= (NSInteger)self.steps.count) { [self finishGrab]; return; }
    GrabStep *s = self.steps[i];
    __weak typeof(self) ws = self;

    switch (s.kind) {
        case StepKindLaunch: {
            [self launchXimalaya];
            [self after:s.wait > 0 ? s.wait : 5.0 then:^{ [ws runStep:i + 1]; }];
            break;
        }
        case StepKindTap: {
            if (!s.recorded) {
                [self log:@"跳过未录坐标：%@", s.name];
                [self after:0.3 then:^{ [ws runStep:i + 1]; }];
                break;
            }
            [self log:@"点 %@ (%.0f,%.0f)", s.name, s.x, s.y];
            [HIDTouch tapPoint:CGPointMake(s.x, s.y)];
            [self after:s.wait > 0 ? s.wait : 1.5 then:^{ [ws runStep:i + 1]; }];
            break;
        }
        case StepKindWait: {
            [self log:@"等 %.0f 秒（%@）", s.wait, s.name];
            [self after:s.wait then:^{ [ws runStep:i + 1]; }];
            break;
        }
        case StepKindUntil: {
            NSInteger nowSec = [self secondOfDay:[NSDate date]];
            NSInteger left = s.untilSec - nowSec;
            if (left < -600) left += 86400;
            if (left > 12 * 3600) {
                // 手动执行时不该傻等到明天
                [self log:@"%@ 距今超过 12 小时，跳过", [s desc]];
                [ws runStep:i + 1];
            } else if (left <= 0) {
                [self log:@"已过 %@，直接继续", [s desc]];
                [ws runStep:i + 1];
            } else {
                [self log:@"等到 %@（还有 %ld 秒）", [s desc], (long)left];
                [self after:(double)left then:^{ [ws runStep:i + 1]; }];
            }
            break;
        }
    }
}

- (void)after:(double)sec then:(void (^)(void))blk {
    if (sec <= 0) sec = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), blk);
}

- (void)launchXimalaya {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    Class LSApp = NSClassFromString(@"LSApplicationWorkspace");
    if (LSApp) {
        id ws = [LSApp performSelector:@selector(defaultWorkspace)];
        SEL sel = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (ws && [ws respondsToSelector:sel]) {
            NSMethodSignature *sig = [ws methodSignatureForSelector:sel];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:ws];
                [inv setSelector:sel];
                id arg = @"com.gemd.iting";
                [inv setArgument:&arg atIndex:2];
                [inv invoke];
                [self log:@"拉起喜马（bundle id）"];
                return;
            }
        }
    }
#pragma clang diagnostic pop
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"ting://"]
                                       options:@{}
                             completionHandler:^(BOOL ok) {
        [self log:ok ? @"拉起喜马（scheme）" : @"拉起失败：权限或 scheme 不对"];
    }];
}

@end
