#!/bin/bash
# Builds build/QuickNoteSearch.app. Pass --install to copy it to /Applications and launch it.
# Signs with your first Apple Development / Developer ID identity if present (so Full Disk Access
# survives rebuilds); otherwise ad-hoc, which means re-granting Full Disk Access after each rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/QuickNoteSearch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/QuickNoteSearch" "$APP/Contents/MacOS/"
cp Support/Info.plist "$APP/Contents/"
[ -f Support/AppIcon.icns ] || scripts/make_icon.sh
cp Support/AppIcon.icns "$APP/Contents/Resources/"

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Developer ID Application/ {print $2; exit}' || true)}"
codesign --force --sign "${SIGN_ID:--}" "$APP"
echo "Built $APP (signed: ${SIGN_ID:-ad-hoc})"

if [ "${1:-}" = "--install" ]; then
  pkill -x QuickNoteSearch || true
  rm -rf /Applications/QuickNoteSearch.app
  cp -R "$APP" /Applications/
  open /Applications/QuickNoteSearch.app
  echo "Installed to /Applications"
fi
