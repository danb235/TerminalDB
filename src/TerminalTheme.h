#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TerminalTheme : NSObject

@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) BOOL dark;
@property(nonatomic, strong, readonly) NSColor *terminalBackground;
@property(nonatomic, strong, readonly) NSColor *terminalForeground;
@property(nonatomic, strong, readonly) NSColor *cursorColor;
@property(nonatomic, strong, readonly) NSColor *selectionBackground;
@property(nonatomic, strong, readonly) NSColor *statusBarBackground;
@property(nonatomic, strong, readonly) NSColor *statusBarForeground;
@property(nonatomic, strong, readonly) NSColor *statusBarActiveForeground;
@property(nonatomic, strong, readonly) NSColor *statusBarBorder;
@property(nonatomic, strong, readonly) NSColor *titleBarBackground;
@property(nonatomic, strong, readonly) NSColor *titleBarForeground;
@property(nonatomic, copy, readonly) NSArray<NSColor *> *ansiColors;
@property(nonatomic, copy, readonly) NSString *fontName;
@property(nonatomic, readonly) CGFloat fontSize;
@property(nonatomic, readonly) CGFloat lineHeightMultiple;

+ (instancetype)preferredTheme;

@end

NS_ASSUME_NONNULL_END
