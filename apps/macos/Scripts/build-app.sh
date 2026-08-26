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

if [[ "${CONFIGURATION}" == "debug" ]]; then
  SWIFT_OPTIMIZATION_FLAGS=(-Onone -g)
else
  SWIFT_OPTIMIZATION_FLAGS=(-O)
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

architectures=(arm64 x86_64)
if [[ "${TERMINALDB_NATIVE_ONLY:-0}" == "1" ]]; then architectures=("$(uname -m)"); fi
app_slices=()
agent_slices=()
for arch in "${architectures[@]}"; do
  slice="${BIN_PATH}.${arch}"
  ./Scripts/build-terminal-surface.sh "${arch}" "${slice}" "${CONFIGURATION}"
  app_slices+=("${slice}")
  agent_slice="${CONTENTS_DIR}/MacOS/TerminalDBRemoteAgent.${arch}"
  xcrun swiftc -parse-as-library -strict-concurrency=minimal \
    -target "${arch}-apple-macosx13.0" "${SWIFT_OPTIMIZATION_FLAGS[@]}" \
    -framework Foundation -framework Security \
    remote-agent/TerminalDBRemoteAgent.swift -o "${agent_slice}"
  agent_slices+=("${agent_slice}")
done
AGENT_PATH="${CONTENTS_DIR}/MacOS/TerminalDBRemoteAgent"
lipo -create "${app_slices[@]}" -output "${BIN_PATH}"
lipo -create "${agent_slices[@]}" -output "${AGENT_PATH}"
rm "${app_slices[@]}" "${agent_slices[@]}"
chmod 755 "${BIN_PATH}" "${AGENT_PATH}"

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
lipo "${BIN_PATH}" -verify_arch "${architectures[@]}"
lipo "${AGENT_PATH}" -verify_arch "${architectures[@]}"

echo "Built ${APP_DIR}"
echo "Version: ${VERSION}"
echo "Architectures: $(lipo -archs "${BIN_PATH}")"
