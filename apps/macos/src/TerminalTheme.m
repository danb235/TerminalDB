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

    theme.terminalBackground = ThemeColor(@"#17171A");
    theme.terminalForeground = ThemeColor(@"#E7E7E2");
    theme.cursorColor = ThemeColor(@"#E7E7E2");
    theme.selectionBackground = ThemeColor(@"#52d0dd2e");

    theme.statusBarBackground = ThemeColor(@"#141417");
    theme.statusBarForeground = ThemeColor(@"#6B6B66");
    theme.statusBarActiveForeground = ThemeColor(@"#A0A09A");
    theme.statusBarBorder = ThemeColor(@"#2C2C33");
    theme.titleBarBackground = ThemeColor(@"#232327");
    theme.titleBarForeground = ThemeColor(@"#C9C9C3");
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast) {
        theme.statusBarBorder = ThemeColor(@"#4A4A52");
        theme.statusBarActiveForeground = ThemeColor(@"#C9C9C3");
    }

    theme.ansiColors = @[
        ThemeColor(@"#101013"),
        ThemeColor(@"#EF6557"),
        ThemeColor(@"#B4E34D"),
        ThemeColor(@"#E3AC4E"),
        ThemeColor(@"#d88a55"),
        ThemeColor(@"#a78bd4"),
        ThemeColor(@"#52D0DD"),
        ThemeColor(@"#E7E7E2"),
        ThemeColor(@"#6B6B66"),
        ThemeColor(@"#ff858a"),
        ThemeColor(@"#C7F062"),
        ThemeColor(@"#F0C66B"),
        ThemeColor(@"#e29b68"),
        ThemeColor(@"#b9a0e8"),
        ThemeColor(@"#72E2EC"),
        ThemeColor(@"#F3F6F7"),
    ];

    // The Graphite Ledger UI uses the system face for controls and
    // JetBrains Mono for every command, path, metric, and shortcut.
    theme.fontName = @"JetBrainsMono-Regular";
    theme.fontSize = 13.5;
    theme.lineHeightMultiple = 1.24;
    return theme;
}

@end
