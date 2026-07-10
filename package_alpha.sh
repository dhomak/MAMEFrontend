#!/usr/bin/env bash
#
# Build, ad-hoc sign, and package MAMEFrontend as a zip.
# Run on macOS with Xcode installed, from the project root.
#
#   ./package_alpha.sh
#   VERSION=0.3.1 SCHEME=MAMEFrontend ./package_alpha.sh
#
set -euo pipefail

SCHEME="${SCHEME:-MAMEFrontend}"
PROJECT="${PROJECT:-MAMEFrontend.xcodeproj}"
CONFIG="Release"
VERSION="${VERSION:-0.3.0}"
BUILD_DIR="build"

echo "▶ Building $SCHEME ($CONFIG)…"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$BUILD_DIR" clean build | tail -n 20

APP="$BUILD_DIR/Build/Products/$CONFIG/$SCHEME.app"
[ -d "$APP" ] || { echo "✗ App not found at $APP"; exit 1; }

echo "▶ Ad-hoc signing…"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "  signature ok"

OUT="$SCHEME-$VERSION.zip"
echo "▶ Packaging → $OUT"
ditto -c -k --keepParent "$APP" "$OUT"

echo "✓ Done: $OUT"
echo "  Testers: unzip, move to /Applications, right-click → Open (first launch),"
echo "  or run: xattr -dr com.apple.quarantine /Applications/$SCHEME.app"
