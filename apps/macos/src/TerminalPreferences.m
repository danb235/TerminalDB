#import "TerminalPreferences.h"
#include <stdlib.h>

NSUserDefaults *TerminalDBPreferences(void) {
    static NSUserDefaults *preferences;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSProcessInfo *process = NSProcessInfo.processInfo;
        BOOL testing = [process.environment[@"TERMINALDB_PEER_QA"] isEqualToString:@"1"];
        for (NSString *flag in @[@"--self-test", @"--terminal-qa", @"--visual-qa", @"--background-tab-qa"]) {
            if ([process.arguments containsObject:flag]) testing = YES;
        }
        if (!testing) {
            // The GUI and the separately identified session host share the
            // existing workstation preferences, including provider settings.
            preferences = [[NSUserDefaults alloc] initWithSuiteName:@"com.terminaldb.app"];
            return;
        }
        // Real interactive QA keeps the production app's provider keys,
        // permission settings and appearance preferences untouched.
        NSString *domain = [NSString stringWithFormat:@"com.terminaldb.qa.%d", process.processIdentifier];
        preferences = [[NSUserDefaults alloc] initWithSuiteName:domain];
        [preferences removePersistentDomainForName:domain];
        atexit_b(^{ [preferences removePersistentDomainForName:domain]; });
    });
    return preferences;
}
