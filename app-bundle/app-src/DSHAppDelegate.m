/*
 * DSHLauncher — the real SpringBoard app for DeepSeek Harness on iOS.
 *
 * Same "form" as the official desktop APP:
 *   official desktop = native shell + bundled DSH Web UI + managed Harness host
 *   this iOS app     = native app shell + the official DSH Web UI, served by the
 *                      on-device Harness host (kept alive by launchd)
 *
 * Why SFSafariViewController instead of WKWebView:
 *   On iOS 16 rootless, a hand-signed jailbreak app's WKWebView cannot launch
 *   its WebContent XPC process ("Invalid connection identifier"), independent
 *   of entitlements.  SFSafariViewController runs the page in the system's own
 *   Safari view service, so the exact same Web UI (workspace + plugins
 *   untouched) renders reliably.  barCollapsingEnabled gives the near
 *   full-screen feel of the official app; the bar collapses on scroll.
 *
 * No Apple developer certificate: postinst re-signs this Mach-O with ldid.
 */
#import "DSHAppDelegate.h"
#import <SafariServices/SafariServices.h>
#import <spawn.h>

extern char **environ;

static NSString *const kDSHHomeDefault = @"/var/jb/var/mobile/.dsh";
static NSString *const kDSHDefaultURL = @"http://127.0.0.1:3080/";

static BOOL DSHIsLocalHost(NSString *host) {
    if (host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    return [h isEqualToString:@"127.0.0.1"] ||
           [h isEqualToString:@"localhost"] ||
           [h isEqualToString:@"::1"] ||
           [h isEqualToString:@"[::1]"];
}

static BOOL DSHIsLocalURLString(NSString *s) {
    if (s.length == 0) return NO;
    NSURLComponents *c = [NSURLComponents componentsWithString:s];
    if (!c || c.scheme.length == 0 || c.host.length == 0) return NO;
    NSString *scheme = c.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    return DSHIsLocalHost(c.host);
}

static NSString *DSHLogPath(void) {
    const char *env = getenv("DSH_HOME");
    NSString *home = (env && *env) ? [NSString stringWithUTF8String:env] : kDSHHomeDefault;
    return [home stringByAppendingPathComponent:@"logs/app.log"];
}

static void DSHLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *path = DSHLogPath();
    @try {
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSString *full = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], line];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [full writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (__unused NSException *e) {
    }
}

@interface DSHAppDelegate () <SFSafariViewControllerDelegate>
@property (nonatomic, strong) NSURLSession *probeSession;
@property (nonatomic, strong) SFSafariViewController *safari;
@property (nonatomic, strong) NSURL *resolvedURL;
@end

@implementation DSHAppDelegate

#pragma mark - lifecycle

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1.0];
    self.window.rootViewController = root;

    [self buildSplashIn:root.view];
    [self.window makeKeyAndVisible];

    self.candidates = [NSMutableArray array];
    self.tried = [NSMutableSet set];
    self.candidateIndex = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self ensureDaemon];
        [self reloadCandidatesAndProbe];
    });

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    DSHLog(@"didFinishLaunching done");
    return YES;
}

- (void)ensureDaemon {
    /* The app runs as mobile and cannot bootstrap a system LaunchDaemon.
       A root:wheel 4755 helper runs exactly one fixed command:
       `dsh-app-ctl ensure`.  It loads/kickstarts the keepalive daemon, which
       then starts `dsh web` (no terminal needed) and writes the launch token
       into its stdout log; this app reads that token. */
    if (self.didEnsureDaemon) return;
    self.didEnsureDaemon = YES;
    const char *path = "/var/jb/usr/bin/dsh-app-helper";
    char *const argv[] = {(char *)path, NULL};
    pid_t pid = 0;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    DSHLog(@"ensureDaemon rc=%d pid=%d", rc, (int)pid);
}

- (void)appDidBecomeActive {
    if (!self.safari && !self.pageLoaded) {
        if (self.retryTimer == nil) [self reloadCandidatesAndProbe];
    }
}

- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    if ([url.scheme.lowercaseString isEqualToString:@"dsh"]) {
        [self reloadCandidatesAndProbe];
        return YES;
    }
    if (DSHIsLocalURLString(url.absoluteString)) {
        [self presentSafariWithURL:url];
        return YES;
    }
    return NO;
}

#pragma mark - splash

- (void)buildSplashIn:(UIView *)parent {
    self.splash = [[UIView alloc] initWithFrame:parent.bounds];
    self.splash.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.splash.backgroundColor = [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1.0];
    [parent addSubview:self.splash];

    UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"Icon1024"]];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.layer.cornerRadius = 20;
    logo.layer.cornerCurve = kCACornerCurveContinuous;
    logo.clipsToBounds = YES;
    logo.layer.borderWidth = 0.5;
    logo.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;

    self.splashTitle = [[UILabel alloc] init];
    self.splashTitle.text = @"DeepSeek Harness";
    self.splashTitle.textColor = [UIColor whiteColor];
    self.splashTitle.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
    self.splashTitle.textAlignment = NSTextAlignmentCenter;

    self.splashDetail = [[UILabel alloc] init];
    self.splashDetail.text = @"正在连接本机 DSH…";
    self.splashDetail.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    self.splashDetail.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    self.splashDetail.textAlignment = NSTextAlignmentCenter;
    self.splashDetail.numberOfLines = 0;
    self.splashDetail.preferredMaxLayoutWidth = 300;

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = [UIColor colorWithWhite:0.8 alpha:1.0];
    [self.spinner startAnimating];

    self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.retryButton setTitle:@"重新打开 DSH" forState:UIControlStateNormal];
    self.retryButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.retryButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    self.retryButton.layer.cornerRadius = 10;
    self.retryButton.contentEdgeInsets = UIEdgeInsetsMake(10, 26, 10, 26);
    [self.retryButton addTarget:self action:@selector(manualRetry) forControlEvents:UIControlEventTouchUpInside];
    self.retryButton.hidden = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[logo, self.splashTitle,
                                                                          self.splashDetail, self.spinner,
                                                                          self.retryButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:22 afterView:logo];
    [stack setCustomSpacing:20 afterView:self.spinner];
    [self.splash addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [logo.widthAnchor constraintEqualToConstant:88],
        [logo.heightAnchor constraintEqualToConstant:88],
        [stack.centerXAnchor constraintEqualToAnchor:self.splash.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.splash.centerYAnchor constant:-30],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.splash.leadingAnchor constant:32],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.splash.trailingAnchor constant:-32],
    ]];
}

- (void)showConnectingWithText:(NSString *)text {
    self.spinner.hidden = NO;
    [self.spinner startAnimating];
    self.splashDetail.text = text ?: @"正在连接本机 DSH…";
    self.retryButton.hidden = YES;
    self.splash.hidden = NO;
    self.splash.alpha = 1;
}

- (void)showFailureWithText:(NSString *)text {
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.splashDetail.text = text;
    self.retryButton.hidden = NO;
    self.splash.hidden = NO;
    self.splash.alpha = 1;
}

- (void)hideSplash {
    [UIView animateWithDuration:0.2 animations:^{
        self.splash.alpha = 0;
    } completion:^(__unused BOOL done) {
        self.splash.hidden = YES;
    }];
}

#pragma mark - URL discovery

- (NSString *)dshHome {
    const char *env = getenv("DSH_HOME");
    if (env && *env) return [NSString stringWithUTF8String:env];
    return kDSHHomeDefault;
}

- (NSString *)firstLineOfFile:(NSString *)path {
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (s.length == 0) return nil;
    for (NSString *line in [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) return t;
    }
    return nil;
}

- (NSArray<NSString *> *)urlsFromLogTail:(NSString *)path {
    NSMutableArray *out = [NSMutableArray array];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return out;
    @try {
        unsigned long long size = [fh seekToEndOfFile];
        unsigned long long window = 256 * 1024;
        [fh seekToFileOffset:(size > window ? size - window : 0)];
        NSData *tail = [fh readDataToEndOfFile];
        [fh closeFile];
        NSString *text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
        if (text.length == 0) return out;
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"dsh web:\\s*(https?://[^\\s\"']+)"
                                                                           options:0 error:NULL];
        NSArray<NSTextCheckingResult *> *matches = [re matchesInString:text options:0 range:NSMakeRange(0, text.length)];
        for (NSTextCheckingResult *m in matches) {
            NSString *u = [text substringWithRange:[m rangeAtIndex:1]];
            if (DSHIsLocalURLString(u)) [out addObject:u];
        }
    } @catch (__unused NSException *e) {
    }
    return out;
}

- (void)collectCandidates {
    [self.candidates removeAllObjects];
    NSString *home = [self dshHome];

    NSString *webUrlFile = [home stringByAppendingPathComponent:@"web-url"];
    NSString *line = [self firstLineOfFile:webUrlFile];
    if (DSHIsLocalURLString(line)) [self.candidates addObject:line];

    NSArray *logs = @[
        [home stringByAppendingPathComponent:@"logs/dsh-daemon.out.log"],
        [home stringByAppendingPathComponent:@"logs/web.log"],
        [home stringByAppendingPathComponent:@"logs/dsh.log"],
    ];
    for (NSString *log in logs) {
        NSArray *urls = [self urlsFromLogTail:log];
        for (NSString *u in [urls reverseObjectEnumerator]) {
            if (![self.candidates containsObject:u]) [self.candidates addObject:u];
        }
    }

    if (![self.candidates containsObject:kDSHDefaultURL]) [self.candidates addObject:kDSHDefaultURL];
    NSString *localhost = @"http://localhost:3080/";
    if (![self.candidates containsObject:localhost]) [self.candidates addObject:localhost];
}

#pragma mark - probing / presenting

- (NSURLSession *)probeSession {
    if (!_probeSession) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 5;
        cfg.timeoutIntervalForResource = 8;
        _probeSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    return _probeSession;
}

- (void)reloadCandidatesAndProbe {
    [self collectCandidates];
    self.candidateIndex = 0;
    [self.tried removeAllObjects];
    [self showConnectingWithText:@"正在连接本机 DSH…"];
    [self probeNextCandidate];
}

- (void)probeNextCandidate {
    if (self.safari) return;
    while (self.candidateIndex < self.candidates.count) {
        NSString *s = self.candidates[self.candidateIndex++];
        if ([self.tried containsObject:s]) continue;
        [self.tried addObject:s];
        NSURL *url = [NSURL URLWithString:s];
        if (!url) continue;
        /* For the bare 3080 URL, SFSafariViewController shares Safari's
           cookie store, so a logged-in Safari works.  Probe only to know
           whether the port answers at all: any HTTP status (incl. 401) is
           fine, a connection error means DSH is still starting. */
        BOOL bare = [s isEqualToString:kDSHDefaultURL] || [s hasPrefix:@"http://localhost:3080"];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:5];
        req.HTTPMethod = @"GET";
        __weak typeof(self) weakSelf = self;
        NSURLSessionDataTask *task = [self.probeSession dataTaskWithRequest:req
                                                          completionHandler:^(__unused NSData *data,
                                                                              NSURLResponse *response,
                                                                              __unused NSError *error) {
            NSInteger code = 0;
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                code = ((NSHTTPURLResponse *)response).statusCode;
            }
            BOOL ok = bare ? (code > 0) : (code >= 200 && code < 400);
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self.safari) return;
                if (ok) {
                    [self presentSafariWithURL:url];
                } else {
                    [self probeNextCandidate];
                }
            });
        }];
        [task resume];
        return;
    }
    [self failWithText:@"没有找到正在运行的 DSH。\n\n请确认后台服务已启动：\n终端执行 dsh-app-ctl ensure，\n或稍等自动重试。"];
}

- (void)presentSafariWithURL:(NSURL *)url {
    if (self.safari) return;
    self.resolvedURL = url;
    self.pageLoaded = YES;
    if (self.retryTimer) { [self.retryTimer invalidate]; self.retryTimer = nil; }

    SFSafariViewControllerConfiguration *cfg = [[SFSafariViewControllerConfiguration alloc] init];
    cfg.barCollapsingEnabled = YES;
    SFSafariViewController *safari = [[SFSafariViewController alloc] initWithURL:url configuration:cfg];
    safari.delegate = self;
    safari.preferredBarTintColor = [UIColor colorWithRed:0.043 green:0.055 blue:0.078 alpha:1.0];
    safari.preferredControlTintColor = [UIColor whiteColor];
    safari.dismissButtonStyle = SFSafariViewControllerDismissButtonStyleClose;
    safari.modalPresentationStyle = UIModalPresentationFullScreen;
    self.safari = safari;
    DSHLog(@"present %@", url.absoluteString);
    [self.window.rootViewController presentViewController:safari animated:YES completion:nil];
    [self hideSplash];
}

- (void)failWithText:(NSString *)text {
    [self showFailureWithText:text];
    if (self.retryTimer) return;
    self.retryTicks = 0;
    __weak typeof(self) weakSelf = self;
    self.retryTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) { [timer invalidate]; return; }
        self.retryTicks++;
        [self collectCandidates];
        for (NSString *u in self.candidates) {
            if (![self.tried containsObject:u]) {
                [self showConnectingWithText:@"发现新的 DSH 实例，正在连接…"];
                self.candidateIndex = 0;
                [self probeNextCandidate];
                return;
            }
        }
        if (self.retryTicks >= 60) {
            [timer invalidate];
            self.retryTimer = nil;
            [self showFailureWithText:@"等待 DSH 启动超时（2 分钟）。\n\n请确认 dsh-app-ctl status 中 daemon 在运行；\n再点「重新打开 DSH」重试。"];
        }
    }];
}

- (void)manualRetry {
    if (self.retryTimer) { [self.retryTimer invalidate]; self.retryTimer = nil; }
    self.didEnsureDaemon = NO;
    [self ensureDaemon];
    [self reloadCandidatesAndProbe];
}

#pragma mark - SFSafariViewControllerDelegate

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    self.safari = nil;
    self.pageLoaded = NO;
    DSHLog(@"safari closed");
    [self showFailureWithText:@"DSH 页面已关闭。\n点「重新打开 DSH」继续，或按 Home 退出 APP。"];
}

@end
