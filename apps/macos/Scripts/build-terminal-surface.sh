#!/usr/bin/env bash
# Build the pinned Swift package and link its native view into the Objective-C app.
set -euo pipefail
cd "$(dirname "$0")/.."
arch="${1:?architecture required}"
destination="${2:?output executable required}"
configuration="${3:-release}"
package="TerminalSurface"
scratch="${package}/.build/terminaldb-${arch}"
objects="build/terminal-surface/${arch}"
mkdir -p "${objects}"
xcrun swift build --package-path "${package}" --scratch-path "${scratch}" --arch "${arch}" \
  --configuration release --product TerminalDBTerminal
package_bin="$(xcrun swift build --package-path "${package}" --scratch-path "${scratch}" --arch "${arch}" \
  --configuration release --show-bin-path)"
generated_header="$(find "${scratch}" -path '*/TerminalDBTerminal.build/include/TerminalDBTerminal-Swift.h' -print -quit)"
if [[ -z "${generated_header}" ]]; then
  printf '%s\n' "SwiftPM did not generate TerminalDBTerminal-Swift.h" >&2
  exit 1
fi
generated_header_dir="$(dirname "${generated_header}")"
optimization=(-O2)
if [[ "${configuration}" == "debug" ]]; then optimization=(-O0 -g); fi
object_files=()
for source in src/*.m; do
  object="${objects}/$(basename "${source}" .m).o"
  clang -c -fobjc-arc -Wall -Wextra -arch "${arch}" \
    -mmacosx-version-min=13.0 "${optimization[@]}" \
    -I "${generated_header_dir}" \
    "${source}" -o "${object}"
  object_files+=("${object}")
done
xcrun swiftc -target "${arch}-apple-macosx13.0" \
  "${object_files[@]}" "${package_bin}/libTerminalDBTerminal.a" \
  -Xlinker -ObjC -framework AppKit -framework Foundation \
  -framework CoreImage -framework LocalAuthentication \
  -o "${destination}"
# SPM's resource files are read-only. Both architecture slices use the same
# resources; copy once rather than trying to overwrite the first slice's bundle.
if [[ ! -d build/TerminalDB.app/Contents/Resources/SwiftTerm_SwiftTerm.bundle ]]; then
  cp -R "${package_bin}/SwiftTerm_SwiftTerm.bundle" build/TerminalDB.app/Contents/Resources/
  cp "${scratch}/checkouts/SwiftTerm/LICENSE" \
    build/TerminalDB.app/Contents/Resources/Licenses/SwiftTerm-MIT.txt
fi
