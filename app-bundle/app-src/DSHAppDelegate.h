#import <UIKit/UIKit.h>

@interface DSHAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIView *splash;
@property (nonatomic, strong) UILabel *splashTitle;
@property (nonatomic, strong) UILabel *splashDetail;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *retryButton;
@property (nonatomic, strong) NSMutableArray<NSString *> *candidates;
@property (nonatomic, assign) NSUInteger candidateIndex;
@property (nonatomic, strong) NSMutableSet<NSString *> *tried;
@property (nonatomic, strong) NSString *pendingURL;
@property (nonatomic, assign) BOOL pageLoaded;
@property (nonatomic, assign) NSInteger retryTicks;
@property (nonatomic, assign) BOOL didEnsureDaemon;
@property (nonatomic, strong) NSTimer *retryTimer;
@end
