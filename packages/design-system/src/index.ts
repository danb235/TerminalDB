export const graphiteLedger = {
  colors: {
    canvas: "#101013",
    terminal: "#17171A",
    panel: "#1C1C20",
    elevated: "#232327",
    border: "#2C2C33",
    text: "#E7E7E2",
    muted: "#8B8B85",
    quiet: "#6B6B66",
    cyan: "#52D0DD",
    purple: "#A78BD4",
    lime: "#B4E34D",
    amber: "#E3AC4E",
    coral: "#EF6557",
  },
  typography: {
    mono: '"JetBrains Mono", "SFMono-Regular", Consolas, monospace',
    sans: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
  },
  spacing: {
    xs: 4,
    sm: 8,
    md: 12,
    lg: 16,
    xl: 24,
  },
} as const;

export type GraphiteLedgerToken = typeof graphiteLedger;
