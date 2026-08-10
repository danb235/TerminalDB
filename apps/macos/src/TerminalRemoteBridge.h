#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class TerminalRemoteBridge;

@protocol TerminalRemoteBridgeDelegate <NSObject>
- (NSDictionary *)terminalRemoteInventoryForBridge:(TerminalRemoteBridge *)bridge;
- (nullable NSDictionary *)terminalRemoteViewportForTabIdentifier:(NSString *)tabIdentifier;
- (BOOL)terminalRemoteBridge:(TerminalRemoteBridge *)bridge
                  writeInput:(NSString *)input
             toTabIdentifier:(NSString *)tabIdentifier
                       error:(NSError **)error;
- (BOOL)terminalRemoteBridge:(TerminalRemoteBridge *)bridge
 resizeTerminalTabIdentifier:(NSString *)tabIdentifier
                     columns:(NSUInteger)columns
                        rows:(NSUInteger)rows
                      active:(BOOL)active
                       error:(NSError **)error;
- (BOOL)terminalRemoteBridge:(TerminalRemoteBridge *)bridge
     createTabFromIdentifier:(NSString *)tabIdentifier
                       error:(NSError **)error;
- (BOOL)terminalRemoteBridge:(TerminalRemoteBridge *)bridge
         selectTabIdentifier:(NSString *)tabIdentifier
                       error:(NSError **)error;
- (BOOL)terminalRemoteBridge:(TerminalRemoteBridge *)bridge
          closeTabIdentifier:(NSString *)tabIdentifier
                       error:(NSError **)error;
- (BOOL)terminalRemoteBridge:(TerminalRemoteBridge *)bridge
               switchAccount:(NSString *)accountIdentifier
            forTabIdentifier:(NSString *)tabIdentifier
                       error:(NSError **)error;
- (void)terminalRemoteBridgeDidRequestUsageRefresh:
    (TerminalRemoteBridge *)bridge;
@optional
- (void)terminalRemoteBridgeStatusDidChange:(TerminalRemoteBridge *)bridge;
@end

@interface TerminalRemoteBridge : NSObject

@property(nonatomic, weak, nullable) id<TerminalRemoteBridgeDelegate> delegate;
@property(nonatomic, copy, readonly) NSString *connectionState;
@property(nonatomic, copy, readonly, nullable) NSString *pairingURL;
@property(nonatomic, copy, readonly, nullable) NSString *statusDetail;
@property(nonatomic, copy, readonly) NSArray<NSDictionary *> *trustedControllers;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly) BOOL accountOwned;
@property(nonatomic, readonly) BOOL accountBootstrapSupported;

- (instancetype)initWithDelegate:(nullable id<TerminalRemoteBridgeDelegate>)delegate;
- (void)attachToRunningAgent;
- (void)start;
- (void)enableWithBaseURL:(NSString *)baseURL
           enrollmentCode:(NSString *)enrollmentCode;
- (void)disable;
- (void)createPairing;
- (void)createAccountWithBaseURL:(NSString *)baseURL;
- (void)connectAccountWithBaseURL:(NSString *)baseURL;
- (void)refreshControllers;
- (void)revokeControllerWithIdentifier:(NSString *)controllerIdentifier;
- (void)publishOutputData:(NSData *)data
            tabIdentifier:(NSString *)tabIdentifier
                     rows:(NSUInteger)rows
                  columns:(NSUInteger)columns
                 inputMode:(NSString *)inputMode;
- (void)publishViewportForTabIdentifier:(NSString *)tabIdentifier;
- (void)publishInventory;
- (void)stop;
+ (BOOL)runUTF8OutputDecodingSelfTests;

@end

@interface TerminalRemotePanelController : NSObject

@property(nonatomic, strong, readonly) NSView *view;

- (instancetype)initWithBridge:(TerminalRemoteBridge *)bridge;
- (void)prepareForPresentationInWindow:(NSWindow *)window;
- (void)refresh;
+ (BOOL)runAccountControlsSelfTests;

@end

NS_ASSUME_NONNULL_END
