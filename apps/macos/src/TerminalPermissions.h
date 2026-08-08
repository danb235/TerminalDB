#import <AppKit/AppKit.h>

@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TerminalCommandRisk) {
    TerminalCommandRiskReadOnly = 0,
    TerminalCommandRiskUnknown = 1,
    TerminalCommandRiskWrite = 2,
    TerminalCommandRiskDestructive = 3,
    TerminalCommandRiskProduction = 4,
};

typedef NS_ENUM(NSInteger, TerminalCommandPermissionDecision) {
    TerminalCommandPermissionCancel = 0,
    TerminalCommandPermissionRunOnce = 1,
    TerminalCommandPermissionAllowSimilarThisSession = 2,
};

@interface TerminalPermissionCenter : NSObject

@property(nonatomic, readonly) NSUInteger sessionApprovalCount;

- (instancetype)initWithTheme:(TerminalTheme *)theme;
+ (TerminalCommandRisk)riskForCommand:(NSString *)command
                          environment:(NSString *)environment;
+ (NSString *)titleForRisk:(TerminalCommandRisk)risk;
+ (NSString *)explanationForCommand:(NSString *)command
                               risk:(TerminalCommandRisk)risk;
- (void)requestPermissionForCommand:(NSString *)command
                           directory:(NSString *)directory
                                host:(NSString *)host
                         environment:(NSString *)environment
                        parentWindow:(nullable NSWindow *)parentWindow
                          completion:(void (^)(TerminalCommandPermissionDecision
                                                   decision))completion;
- (void)resetSessionApprovals;
+ (BOOL)runSelfTests;

@end

NS_ASSUME_NONNULL_END
