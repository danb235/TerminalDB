#!/usr/bin/env bash
# Build and assemble a universal TerminalDB.app without requiring Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_NAME="TerminalDB"
APP_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
BIN_PATH="${CONTENTS_DIR}/MacOS/${APP_NAME}"
VERSION="${TERMINALDB_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
BUILD_NUMBER="${TERMINALDB_BUILD:-${VERSION}}"

SOURCES=(
  src/main.m
  src/ClaudeAPI.m
  src/ClaudeAssistantView.m
  src/TerminalInspector.m
  src/ClaudeProfile.m
  src/ClaudeStatusBar.m
  src/TerminalTheme.m
  src/TerminalLedger.m
  src/TerminalPermissions.m
  src/TerminalProduct.m
)

if [[ "${CONFIGURATION}" == "debug" ]]; then
  OPTIMIZATION_FLAGS=(-O0 -g)
else
  OPTIMIZATION_FLAGS=(-O2)
fi

if [[ -d "${APP_DIR}" ]]; then
  /bin/rm -r "${APP_DIR}"
fi

mkdir -p \
  "${CONTENTS_DIR}/MacOS" \
  "${CONTENTS_DIR}/Resources/Fonts" \
  "${CONTENTS_DIR}/Resources/Licenses" \
  "${CONTENTS_DIR}/Resources/Scripts"

cp Info.plist "${CONTENTS_DIR}/Info.plist"
cp Resources/AppIcon.icns "${CONTENTS_DIR}/Resources/AppIcon.icns"
cp Resources/Fonts/*.ttf "${CONTENTS_DIR}/Resources/Fonts/"
cp Resources/Licenses/JetBrainsMono-OFL.txt "${CONTENTS_DIR}/Resources/Licenses/"
cp Resources/Scripts/claude-status-bridge.sh "${CONTENTS_DIR}/Resources/Scripts/"
cp Resources/Scripts/claude-tab-state.sh "${CONTENTS_DIR}/Resources/Scripts/"
chmod 755 "${CONTENTS_DIR}/Resources/Scripts/"*.sh

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString ${VERSION}" \
  "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
  "${CONTENTS_DIR}/Info.plist"

clang \
  -fobjc-arc \
  -Wall \
  -Wextra \
  -mmacosx-version-min=13.0 \
  -arch arm64 \
  -arch x86_64 \
  "${OPTIMIZATION_FLAGS[@]}" \
  -framework AppKit \
  -framework Foundation \
  "${SOURCES[@]}" \
  -o "${BIN_PATH}"

IDENTITY_CN="TerminalDB Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENTITY_CN}"; then
  echo "Signing with stable identity '${IDENTITY_CN}'"
  codesign \
    --force \
    --deep \
    --sign "${IDENTITY_CN}" \
    --identifier com.terminaldb.app \
    "${APP_DIR}"
else
  echo "No stable signing identity found. Using an ad hoc signature."
  codesign \
    --force \
    --deep \
    --sign - \
    --identifier com.terminaldb.app \
    --requirements '=designated => identifier "com.terminaldb.app"' \
    "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
lipo "${BIN_PATH}" -verify_arch arm64 x86_64

echo "Built ${APP_DIR}"
echo "Version: ${VERSION}"
echo "Architectures: $(lipo -archs "${BIN_PATH}")"
