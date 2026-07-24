#import <AppKit/AppKit.h>

@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TerminalProductSection) {
    TerminalProductSectionProject = 0,
    TerminalProductSectionEnvironments,
    TerminalProductSectionMonitor,
    TerminalProductSectionRunbooks,
    TerminalProductSectionWorkspaces,
    TerminalProductSectionSettings,
    TerminalProductSectionOnboarding,
};

@interface TerminalProductStore : NSObject

@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *runbooks;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *workspaces;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *monitors;

+ (instancetype)sharedStore;
- (NSDictionary *)saveRunbookNamed:(NSString *)name
                           command:(NSString *)command
                         directory:(NSString *)directory;
- (void)deleteRunbookWithIdentifier:(NSString *)identifier;
- (NSDictionary *)saveWorkspaceNamed:(NSString *)name
                           directory:(NSString *)directory
                      accountLabel:(nullable NSString *)accountLabel
                          chatTitle:(nullable NSString *)chatTitle;
- (void)deleteWorkspaceWithIdentifier:(NSString *)identifier;
- (NSString *)beginMonitoringCommand:(NSString *)command
                           directory:(NSString *)directory
                         environment:(NSString *)environment;
- (void)finishMonitorWithIdentifier:(NSString *)identifier
                           exitCode:(NSInteger)exitCode
                             output:(NSString *)output;
- (void)removeMonitorWithIdentifier:(NSString *)identifier;
- (BOOL)runSelfTests;

@end

@interface TerminalProductWindowController : NSWindowController

@property(nonatomic, copy, nullable) void (^runCommandHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^pasteCommandHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^restoreWorkspaceHandler)(
    NSDictionary *workspace);
@property(nonatomic, copy, nullable) void (^openAPISettingsHandler)(void);
@property(nonatomic, copy, nullable) void (^newAIChatHandler)(void);
@property(nonatomic, copy, nullable) void (^showHistoryHandler)(void);
@property(nonatomic, copy, nullable) void (^askAIHandler)(
    NSDictionary *context, NSString *prompt);

- (instancetype)initWithTheme:(TerminalTheme *)theme
                         store:(TerminalProductStore *)store;
- (void)showSection:(TerminalProductSection)section
          directory:(NSString *)directory
       accountLabel:(nullable NSString *)accountLabel;
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
