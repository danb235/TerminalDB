#import "TerminalTheme.h"

// TerminalDB contains its own native presentation code and design tokens.
// It does not bundle Monokai extension code, JSON theme files, icons, fonts,
// or other proprietary package assets.

@interface TerminalTheme ()
@property(nonatomic, copy, readwrite) NSString *name;
@property(nonatomic, readwrite) BOOL dark;
@property(nonatomic, strong, readwrite) NSColor *terminalBackground;
@property(nonatomic, strong, readwrite) NSColor *terminalForeground;
@property(nonatomic, strong, readwrite) NSColor *cursorColor;
@property(nonatomic, strong, readwrite) NSColor *selectionBackground;
@property(nonatomic, strong, readwrite) NSColor *statusBarBackground;
@property(nonatomic, strong, readwrite) NSColor *statusBarForeground;
@property(nonatomic, strong, readwrite) NSColor *statusBarActiveForeground;
@property(nonatomic, strong, readwrite) NSColor *statusBarBorder;
@property(nonatomic, strong, readwrite) NSColor *titleBarBackground;
@property(nonatomic, strong, readwrite) NSColor *titleBarForeground;
@property(nonatomic, copy, readwrite) NSArray<NSColor *> *ansiColors;
@property(nonatomic, copy, readwrite) NSString *fontName;
@property(nonatomic, readwrite) CGFloat fontSize;
@property(nonatomic, readwrite) CGFloat lineHeightMultiple;
@end

static NSColor *ThemeColor(NSString *hex) {
    if ([hex hasPrefix:@"#"]) hex = [hex substringFromIndex:1];
    unsigned long long number = 0;
    [[NSScanner scannerWithString:hex] scanHexLongLong:&number];
    CGFloat alpha = 1.0;
    if (hex.length == 8) {
        alpha = (number & 0xff) / 255.0;
        number >>= 8;
    }
    return [NSColor colorWithSRGBRed:((number >> 16) & 0xff) / 255.0
                              green:((number >> 8) & 0xff) / 255.0
                               blue:(number & 0xff) / 255.0
                              alpha:alpha];
}

@implementation TerminalTheme

+ (instancetype)preferredTheme {
    TerminalTheme *theme = [[TerminalTheme alloc] init];
    theme.name = @"Monokai Pro";
    theme.dark = YES;

    theme.terminalBackground = ThemeColor(@"#403e41");
    theme.terminalForeground = ThemeColor(@"#fcfcfa");
    theme.cursorColor = ThemeColor(@"#fcfcfa");
    theme.selectionBackground = ThemeColor(@"#fcfcfa26");

    theme.statusBarBackground = ThemeColor(@"#221f22");
    theme.statusBarForeground = ThemeColor(@"#727072");
    theme.statusBarActiveForeground = ThemeColor(@"#939293");
    theme.statusBarBorder = ThemeColor(@"#19181a");
    theme.titleBarBackground = ThemeColor(@"#221f22");
    theme.titleBarForeground = ThemeColor(@"#939293");

    theme.ansiColors = @[
        ThemeColor(@"#403e41"),
        ThemeColor(@"#ff6188"),
        ThemeColor(@"#a9dc76"),
        ThemeColor(@"#ffd866"),
        ThemeColor(@"#fc9867"),
        ThemeColor(@"#ab9df2"),
        ThemeColor(@"#78dce8"),
        ThemeColor(@"#fcfcfa"),
        ThemeColor(@"#727072"),
        ThemeColor(@"#ff6188"),
        ThemeColor(@"#a9dc76"),
        ThemeColor(@"#ffd866"),
        ThemeColor(@"#fc9867"),
        ThemeColor(@"#ab9df2"),
        ThemeColor(@"#78dce8"),
        ThemeColor(@"#fcfcfa"),
    ];

    // Monokai themes do not prescribe a font. TerminalDB keeps the
    // research-backed, redistributable JetBrains Mono at a comfortable
    // terminal size and rhythm.
    theme.fontName = @"JetBrainsMono-Regular";
    theme.fontSize = 14.0;
    theme.lineHeightMultiple = 1.2;
    return theme;
}

@end
