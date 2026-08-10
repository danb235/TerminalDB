import { readFileSync } from "node:fs";
import * as path from "node:path";

import type * as cognito from "aws-cdk-lib/aws-cognito";

const colors = {
  amber: "e3ac4eff",
  border: "2c2c33ff",
  borderStrong: "3b3b43ff",
  canvas: "101013ff",
  coral: "ef6557ff",
  cyan: "52d0ddff",
  cyanActive: "43b4bfff",
  cyanHover: "70e1ebff",
  elevated: "232327ff",
  lime: "b4e34dff",
  muted: "8b8b85ff",
  panel: "1c1c20ff",
  terminal: "17171aff",
  text: "e7e7e2ff",
} as const;

const bothModes = <T>(value: T): { darkMode: T; lightMode: T } => ({
  darkMode: value,
  lightMode: value,
});

const logoBytes = readFileSync(
  path.join(process.cwd(), "../../apps/web/public/terminaldb-icon.svg"),
).toString("base64");

const logoAsset = (
  category: "FAVICON_SVG" | "FORM_LOGO",
  colorMode: "DARK" | "LIGHT",
): cognito.CfnManagedLoginBranding.AssetTypeProperty => ({
  bytes: logoBytes,
  category,
  colorMode,
  extension: "SVG",
});

export const terminalDBManagedLoginAssets = [
  logoAsset("FORM_LOGO", "DARK"),
  logoAsset("FORM_LOGO", "LIGHT"),
  logoAsset("FAVICON_SVG", "DARK"),
  logoAsset("FAVICON_SVG", "LIGHT"),
] satisfies cognito.CfnManagedLoginBranding.AssetTypeProperty[];

const errorColors = {
  backgroundColor: "2b1717ff",
  borderColor: colors.coral,
};

export const terminalDBManagedLoginSettings = {
  categories: {
    form: { displayGraphics: false },
    global: {
      colorSchemeMode: "DARK",
      spacingDensity: "REGULAR",
    },
  },
  components: {
    alert: {
      borderRadius: 8,
      ...bothModes({ error: errorColors }),
    },
    favicon: { enabledTypes: ["SVG"] },
    form: {
      backgroundImage: { enabled: false },
      borderRadius: 8,
      ...bothModes({
        backgroundColor: colors.panel,
        borderColor: colors.borderStrong,
      }),
      logo: {
        enabled: true,
        formInclusion: "IN",
        location: "CENTER",
        position: "TOP",
      },
    },
    pageBackground: {
      image: { enabled: false },
      ...bothModes({ color: colors.canvas }),
    },
    pageText: bothModes({
      bodyColor: colors.text,
      descriptionColor: colors.muted,
      headingColor: colors.text,
    }),
    primaryButton: bothModes({
      active: {
        backgroundColor: colors.cyanActive,
        textColor: colors.canvas,
      },
      defaults: {
        backgroundColor: colors.cyan,
        textColor: colors.canvas,
      },
      disabled: {
        backgroundColor: colors.elevated,
        borderColor: colors.elevated,
      },
      hover: {
        backgroundColor: colors.cyanHover,
        textColor: colors.canvas,
      },
    }),
    secondaryButton: bothModes({
      active: {
        backgroundColor: colors.elevated,
        borderColor: colors.cyanActive,
        textColor: colors.cyanActive,
      },
      defaults: {
        backgroundColor: colors.panel,
        borderColor: colors.cyan,
        textColor: colors.cyan,
      },
      hover: {
        backgroundColor: colors.terminal,
        borderColor: colors.cyanHover,
        textColor: colors.cyanHover,
      },
    }),
  },
  componentClasses: {
    buttons: { borderRadius: 8 },
    divider: bothModes({ borderColor: colors.border }),
    dropDown: {
      borderRadius: 8,
      ...bothModes({
        defaults: { itemBackgroundColor: colors.terminal },
        hover: {
          itemBackgroundColor: colors.elevated,
          itemBorderColor: colors.cyan,
          itemTextColor: colors.text,
        },
        match: {
          itemBackgroundColor: colors.panel,
          itemTextColor: colors.cyan,
        },
      }),
    },
    focusState: bothModes({ borderColor: colors.cyan }),
    input: {
      borderRadius: 8,
      ...bothModes({
        defaults: {
          backgroundColor: colors.terminal,
          borderColor: colors.borderStrong,
        },
        placeholderColor: colors.muted,
      }),
    },
    inputDescription: bothModes({ textColor: colors.muted }),
    inputLabel: bothModes({ textColor: colors.text }),
    link: bothModes({
      defaults: { textColor: colors.cyan },
      hover: { textColor: colors.lime },
    }),
    optionControls: bothModes({
      defaults: {
        backgroundColor: colors.terminal,
        borderColor: colors.borderStrong,
      },
      selected: {
        backgroundColor: colors.cyan,
        foregroundColor: colors.canvas,
      },
    }),
    statusIndicator: bothModes({
      error: {
        ...errorColors,
        indicatorColor: colors.coral,
      },
      pending: { indicatorColor: colors.cyan },
      success: {
        backgroundColor: "1d2718ff",
        borderColor: colors.lime,
        indicatorColor: colors.lime,
      },
      warning: {
        backgroundColor: "2b2418ff",
        borderColor: colors.amber,
        indicatorColor: colors.amber,
      },
    }),
  },
} as const;
