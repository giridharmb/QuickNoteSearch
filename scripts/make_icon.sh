#!/bin/bash
# Regenerates Support/AppIcon.icns from scripts/make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
SET=Support/AppIcon.iconset
rm -rf "$SET" && mkdir -p "$SET"
swift scripts/make_icon.swift "$SET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$SET/icon_512x512@2x.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); [ $d -le 1024 ] && [ $s -ne 512 ] && sips -z $d $d "$SET/icon_512x512@2x.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Support/AppIcon.icns
rm -rf "$SET"
echo "Wrote Support/AppIcon.icns"
