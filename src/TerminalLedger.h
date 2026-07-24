#import <AppKit/AppKit.h>

@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

extern NSNotificationName const TerminalLedgerDidChangeNotification;

@interface TerminalLedgerStore : NSObject

@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *records;

+ (instancetype)sharedStore;
+ (BOOL)runPrivacyAndEnvironmentSelfTests;
- (NSDictionary *)addCommand:(NSString *)command
                    directory:(NSString *)directory
                       output:(NSString *)output
                     exitCode:(NSInteger)exitCode
                     duration:(NSTimeInterval)duration;
- (nullable NSDictionary *)recordWithIdentifier:(NSString *)identifier;
- (void)updateRecord:(NSString *)identifier
              values:(NSDictionary *)values;
- (void)toggleBookmarkForRecord:(NSString *)identifier;
- (void)addAnnotation:(NSString *)annotation
             toRecord:(NSString *)identifier;
- (NSArray<NSDictionary *> *)recordsMatching:(nullable NSString *)query;
- (NSArray<NSDictionary *> *)recordsMatching:(nullable NSString *)query
                                      filters:(nullable NSDictionary *)filters;
- (BOOL)exportRecords:(NSArray<NSDictionary *> *)records
                toURL:(NSURL *)url
               format:(NSString *)format
                error:(NSError **)error;
- (void)clearHistory;

@end

@interface TerminalLedgerBar : NSView

@property(nonatomic, copy, nullable) void (^askHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^pasteHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^historyHandler)(void);
@property(nonatomic, copy, nullable) void (^detailsHandler)(
    NSDictionary *record);
@property(nonatomic, copy, nullable) void (^rerunHandler)(
    NSDictionary *record);
@property(nonatomic, copy, nullable) void (^bookmarkHandler)(
    NSDictionary *record);
@property(nonatomic, copy, nullable) void (^runbookHandler)(
    NSDictionary *record);

- (instancetype)initWithFrame:(NSRect)frame theme:(TerminalTheme *)theme;
- (void)showReadyInDirectory:(NSString *)directory;
- (void)beginCommand:(NSString *)command directory:(NSString *)directory;
- (void)displayRecord:(NSDictionary *)record;
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
@property(nonatomic, copy, nullable) void (^rerunHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^runbookHandler)(
    NSDictionary *record);

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme;
- (void)reload;

@end

@interface TerminalCommandInspectorWindowController : NSWindowController

@property(nonatomic, copy, nullable) void (^pasteHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^rerunHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^askHandler)(NSDictionary *record);
@property(nonatomic, copy, nullable) void (^runbookHandler)(
    NSDictionary *record);

- (instancetype)initWithStore:(TerminalLedgerStore *)store
                         theme:(TerminalTheme *)theme;
- (void)presentRecord:(NSDictionary *)record
             relativeToWindow:(nullable NSWindow *)parentWindow;

@end

NS_ASSUME_NONNULL_END
