#!/usr/bin/env bash
# Build and assemble an Apple Silicon TerminalDB.app without requiring Xcode.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="${1:-release}"
APP_NAME="TerminalDB"
APP_DIR="build/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
BIN_PATH="${CONTENTS_DIR}/MacOS/${APP_NAME}"
VERSION="${TERMINALDB_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
BUILD_NUMBER="${TERMINALDB_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)}"

if [[ -d "${APP_DIR}" ]]; then
  # Copied license files and SwiftPM resources are read-only; make the tree
  # writable so removal never prompts or leaves a half-deleted bundle.
  /bin/chmod -R u+w "${APP_DIR}"
  /bin/rm -rf "${APP_DIR}"
fi

mkdir -p \
  "${CONTENTS_DIR}/Library/LaunchAgents" \
  "${CONTENTS_DIR}/MacOS" \
  "${CONTENTS_DIR}/Resources/Fonts" \
  "${CONTENTS_DIR}/Resources/Licenses" \
  "${CONTENTS_DIR}/Resources/Scripts"

cp Info.plist "${CONTENTS_DIR}/Info.plist"
cp Resources/LaunchAgents/*.plist "${CONTENTS_DIR}/Library/LaunchAgents/"
cp Resources/AppIcon.icns "${CONTENTS_DIR}/Resources/AppIcon.icns"
cp Resources/Fonts/*.ttf "${CONTENTS_DIR}/Resources/Fonts/"
cp Resources/Licenses/*.txt "${CONTENTS_DIR}/Resources/Licenses/"
cp Resources/Scripts/claude-status-bridge.sh "${CONTENTS_DIR}/Resources/Scripts/"
cp Resources/Scripts/claude-tab-state.sh "${CONTENTS_DIR}/Resources/Scripts/"
chmod 755 "${CONTENTS_DIR}/Resources/Scripts/"*.sh

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString ${VERSION}" \
  "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion ${BUILD_NUMBER}" \
  "${CONTENTS_DIR}/Info.plist"

./Scripts/build-terminal-surface.sh arm64 "${BIN_PATH}" "${CONFIGURATION}"
for helper in TerminalDBSessionHost TerminalDBPeerAgent; do
  helper_contents="${CONTENTS_DIR}/Library/LoginItems/${helper}.app/Contents"
  mkdir -p "${helper_contents}/MacOS"
  cp "${BIN_PATH}" "${helper_contents}/MacOS/${helper}"
  cp "Resources/Helpers/${helper}.plist" "${helper_contents}/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "${helper_contents}/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${BUILD_NUMBER}" "${helper_contents}/Info.plist"
  # The host uses the same bundled shell hooks, fonts and terminal renderer.
  # Keep each helper self-contained so Launch Services never assigns it the
  # visible app's bundle URL or identity.
  /usr/bin/ditto "${CONTENTS_DIR}/Resources" "${helper_contents}/Resources"
done
chmod 755 "${BIN_PATH}"

IDENTITY_CN="TerminalDB Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "${IDENTITY_CN}"; then
  echo "Signing with stable identity '${IDENTITY_CN}'"
  signing_identity="${IDENTITY_CN}"
else
  echo "No stable signing identity found. Using an ad hoc signature."
  signing_identity="-"
fi
# Sign inside out. --deep with the GUI identifier would assign that signing
# identity to every helper, contrary to their own bundle metadata.
for component in TerminalDBSessionHost TerminalDBPeerAgent TerminalDB; do
  component_app="${APP_DIR}"
  identifier="com.terminaldb.app"
  if [[ "${component}" != "TerminalDB" ]]; then
    component_app="${CONTENTS_DIR}/Library/LoginItems/${component}.app"
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${component_app}/Contents/Info.plist")"
  fi
  codesign_args=(--force --sign "${signing_identity}" --identifier "${identifier}")
  if [[ "${signing_identity}" == "-" ]]; then
    codesign_args+=(--requirements "=designated => identifier \"${identifier}\"")
  fi
  codesign "${codesign_args[@]}" "${component_app}"
done

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"
for executable in "${BIN_PATH}" \
  "${CONTENTS_DIR}/Library/LoginItems/TerminalDBSessionHost.app/Contents/MacOS/TerminalDBSessionHost" \
  "${CONTENTS_DIR}/Library/LoginItems/TerminalDBPeerAgent.app/Contents/MacOS/TerminalDBPeerAgent"; do
  if [[ "$(lipo -archs "${executable}")" != "arm64" ]]; then
    echo "Expected an arm64-only executable: ${executable}" >&2
    exit 1
  fi
done

echo "Built ${APP_DIR}"
echo "Version: ${VERSION}"
echo "Architectures: $(lipo -archs "${BIN_PATH}")"
