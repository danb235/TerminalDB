#import <AppKit/AppKit.h>

@class ClaudeAssistantView;
@class TerminalTheme;

NS_ASSUME_NONNULL_BEGIN

@protocol ClaudeAssistantViewDelegate <NSObject>

- (void)claudeAssistantView:(ClaudeAssistantView *)view
       didChooseRunCommand:(NSString *)command;
- (void)claudeAssistantView:(ClaudeAssistantView *)view
          didSubmitFollowUp:(NSString *)prompt;
- (void)claudeAssistantViewDidRequestNewConversation:
    (ClaudeAssistantView *)view;
- (void)claudeAssistantViewDidRequestClose:(ClaudeAssistantView *)view;
- (void)claudeAssistantViewDidRequestSettings:(ClaudeAssistantView *)view;

@end

@interface ClaudeAssistantView : NSView

@property(nonatomic, weak, nullable) id<ClaudeAssistantViewDelegate> delegate;

- (instancetype)initWithFrame:(NSRect)frame theme:(TerminalTheme *)theme;
- (void)beginWithModelName:(NSString *)modelName
                  messages:(NSArray<NSDictionary *> *)messages;
- (void)resetConversationWithModelName:(NSString *)modelName;
- (void)appendResponseText:(NSString *)text;
- (void)finish;
- (void)showError:(NSString *)message settingsAvailable:(BOOL)settingsAvailable;
- (void)focusComposer;
+ (NSArray<NSString *> *)commandsFromMarkdown:(NSString *)markdown;

@end

NS_ASSUME_NONNULL_END
