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
./Scripts/prepare-terminal-package.sh "${scratch}"
xcrun swift build --package-path "${package}" --scratch-path "${scratch}" --arch "${arch}" \
  --configuration release --product TerminalDBTerminal
package_bin="$(xcrun swift build --package-path "${package}" --scratch-path "${scratch}" --arch "${arch}" \
  --configuration release --show-bin-path)"
generated_header="$(find "${scratch}" -path '*/TerminalDBTerminal.build/include/TerminalDBTerminal-Swift.h' -print -quit)"
if [[ -z "${generated_header}" || "${TERMINALDB_FORCE_SWIFT_HEADER:-0}" == "1" ]]; then
  # Swift 6.2's CI toolchain does not always emit the Objective-C compatibility
  # header for a static SwiftPM library. Generate it deterministically from the
  # same sources and already-built SwiftTerm module instead of relying on cache.
  generated_header="${objects}/TerminalDBTerminal-Swift.h"
  c_module_flags=()
  while IFS= read -r module_map; do
    c_module_flags+=(-Xcc "-fmodule-map-file=${module_map}")
  done < <(find "${package_bin}" -maxdepth 2 -name module.modulemap -print)
  while IFS= read -r include_dir; do
    c_module_flags+=(-Xcc "-I${include_dir}")
  done < <(find "${scratch}/checkouts" -maxdepth 4 -type d -name include -print)
  xcrun swiftc -target "${arch}-apple-macosx13.0" -swift-version 5 \
    -parse-as-library -module-name TerminalDBTerminal \
    -I "${package_bin}/Modules" "${c_module_flags[@]}" -emit-module \
    -emit-module-path "${objects}/TerminalDBTerminal.swiftmodule" \
    -emit-objc-header -emit-objc-header-path "${generated_header}" \
    "${package}"/Sources/TerminalDBTerminal/*.swift
fi
generated_header_dir="$(dirname "${generated_header}")"
optimization=(-O2)
if [[ "${configuration}" == "debug" ]]; then optimization=(-O0 -g); fi
object_files=()
for source in src/*.m; do
  object="${objects}/$(basename "${source}" .m).o"
  xcrun clang -c -fobjc-arc -Wall -Wextra -arch "${arch}" \
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

# Include notices for every pinned dependency and its bundled crypto sources.
for dependency in "${scratch}"/checkouts/*; do
  name="$(basename "${dependency}")"
  for notice in LICENSE LICENSE.txt NOTICE.txt Sources/CNIOBoringSSL/LICENSE Sources/CCryptoBoringSSL/LICENSE; do
    if [[ -f "${dependency}/${notice}" ]]; then
      suffix="${notice//\//-}"
      notice_target="build/TerminalDB.app/Contents/Resources/Licenses/${name}-${suffix}"
      if [[ ! -f "${notice_target}" ]]; then cp "${dependency}/${notice}" "${notice_target}"; fi
    fi
  done
done
