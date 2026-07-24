#import <AppKit/AppKit.h>

@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const TerminalLedgerDidChangeNotification;

@interface TerminalLedgerStore : NSObject

@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *records;

+ (instancetype)sharedStore;
+ (BOOL)runPrivacyAndEnvironmentSelfTests;
- (void)addCommand:(NSString *)command
          directory:(NSString *)directory
             output:(NSString *)output
           exitCode:(NSInteger)exitCode
           duration:(NSTimeInterval)duration;
- (NSArray<NSDictionary *> *)recordsMatching:(nullable NSString *)query;
- (void)clearHistory;

@end

@interface TerminalLedgerBar : NSView

@property(nonatomic, copy, nullable) void (^askHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^pasteHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^historyHandler)(void);

- (instancetype)initWithFrame:(NSRect)frame theme:(TerminalTheme *)theme;
- (void)showReadyInDirectory:(NSString *)directory;
- (void)beginCommand:(NSString *)command directory:(NSString *)directory;
- (void)finishCommand:(NSString *)command
             directory:(NSString *)directory
              exitCode:(NSInteger)exitCode
              duration:(NSTimeInterval)duration;

@end

@interface TerminalLedgerWindowController
    : NSWindowController <NSTableViewDataSource, NSTableViewDelegate,
                          NSSearchFieldDelegate>

@property(nonatomic, copy, nullable) void (^pasteHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^askHandler)(NSString *command);

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme;
- (void)reload;

@end

NS_ASSUME_NONNULL_END
