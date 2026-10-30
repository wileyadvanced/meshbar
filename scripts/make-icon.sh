#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
swift "$root/scripts/make-icon.swift" "$tmp/AppIcon.iconset"
mkdir -p "$root/Resources"
iconutil -c icns "$tmp/AppIcon.iconset" -o "$root/Resources/AppIcon.icns"
cp "$tmp/AppIcon.iconset/icon_512x512@2x.png" "$root/Resources/AppIcon-1024.png"
echo "Wrote $root/Resources/AppIcon.icns"
