#!/usr/bin/env bash
# Build a double-clickable MeshBar.app. Requires Xcode or the Swift toolchain on macOS.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c release --product MeshBar

app="$root/dist/MeshBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/.build/release/MeshBar" "$app/Contents/MacOS/MeshBar"
chmod +x "$app/Contents/MacOS/MeshBar"
cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
if [ ! -f "$root/Resources/AppIcon.icns" ]; then
  "$root/scripts/make-icon.sh"
fi
cp "$root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

if command -v codesign >/dev/null 2>&1; then
  # Ad-hoc signature with an identifier-only requirement, so the Keychain
  # keeps trusting MeshBar after a rebuild instead of asking again each time.
  codesign --force --sign - -r='designated => identifier "com.meshbar.app"' "$app"
fi

echo "Built $app"
