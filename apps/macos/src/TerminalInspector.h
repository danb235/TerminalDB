#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TerminalInspectionCompletion)(
    NSDictionary<NSString *, id> *result);

@interface TerminalInspector : NSObject

+ (BOOL)validateReadOnlyCommand:(NSString *)command
                          error:(NSString *_Nullable *_Nullable)error;
- (void)runCommand:(NSString *)command
         directory:(NSString *)directory
        completion:(TerminalInspectionCompletion)completion;

@end

NS_ASSUME_NONNULL_END
