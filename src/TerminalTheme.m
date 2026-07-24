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
    theme.name = @"Graphite Ledger";
    theme.dark = YES;

    theme.terminalBackground = ThemeColor(@"#101215");
    theme.terminalForeground = ThemeColor(@"#d9e0e3");
    theme.cursorColor = ThemeColor(@"#f3f6f7");
    theme.selectionBackground = ThemeColor(@"#52d0dd2e");

    theme.statusBarBackground = ThemeColor(@"#0c0e10");
    theme.statusBarForeground = ThemeColor(@"#687277");
    theme.statusBarActiveForeground = ThemeColor(@"#a5afb3");
    theme.statusBarBorder = ThemeColor(@"#282d31");
    theme.titleBarBackground = ThemeColor(@"#171a1f");
    theme.titleBarForeground = ThemeColor(@"#c8d0d3");

    theme.ansiColors = @[
        ThemeColor(@"#101215"),
        ThemeColor(@"#f16f74"),
        ThemeColor(@"#b4e34d"),
        ThemeColor(@"#e5b454"),
        ThemeColor(@"#d88a55"),
        ThemeColor(@"#a78bd4"),
        ThemeColor(@"#52d0dd"),
        ThemeColor(@"#d9e0e3"),
        ThemeColor(@"#687277"),
        ThemeColor(@"#ff858a"),
        ThemeColor(@"#c7f062"),
        ThemeColor(@"#f0c66b"),
        ThemeColor(@"#e29b68"),
        ThemeColor(@"#b9a0e8"),
        ThemeColor(@"#72e2ec"),
        ThemeColor(@"#f3f6f7"),
    ];

    // The Graphite Ledger UI uses the system face for controls and
    // JetBrains Mono for every command, path, metric, and shortcut.
    theme.fontName = @"JetBrainsMono-Regular";
    theme.fontSize = 13.5;
    theme.lineHeightMultiple = 1.24;
    return theme;
}

@end
