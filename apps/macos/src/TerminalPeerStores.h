#pragma once
#import "TerminalLedger.h"
#import "TerminalProduct.h"
#import "ClaudeAPI.h"
#import "TerminalDBTerminal-Swift.h"

@interface TerminalPeerLedgerStore : TerminalLedgerStore
@property(nonatomic) NSUInteger hostRecordCount;
- (void)invalidate;
- (instancetype)initWithClient:(TDBSessionClient *)client;
@end

@interface TerminalPeerProductStore : TerminalProductStore
@property(nonatomic, copy) void (^didChange)(void);
- (instancetype)initWithClient:(TDBSessionClient *)client;
- (void)invalidate;
@end

@interface TerminalPeerAPIConfiguration : ClaudeAPIConfiguration
@property(nonatomic, copy) NSDictionary *hostConfiguration;
- (instancetype)initWithClient:(TDBSessionClient *)client;
@end
