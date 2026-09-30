#!/bin/bash
# Local build helper for macOS. Produces the same two IPAs as the GitHub
# Actions workflow, without needing Xcode's GUI.
#
#   ./build-ipa.sh
#
# Requirements: macOS with Xcode command line tools, and xcodegen
#   (brew install xcodegen)

set -euo pipefail

cd "$(dirname "$0")"

echo "==> Toolchain"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not found. Install it with:  brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating MeterReader.xcodeproj"
xcodegen generate --spec project.yml

echo "==> Building (Release, unsigned)"
rm -rf out
xcodebuild \
  -project MeterReader.xcodeproj \
  -target MeterReader \
  -configuration Release \
  -sdk iphoneos \
  CONFIGURATION_BUILD_DIR="$PWD/out" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP="out/MeterReader.app"
[ -d "$APP" ] || { echo "error: $APP was not produced" >&2; exit 1; }
lipo -info "$APP/MeterReader"

echo "==> Packaging MeterReader-unsigned.ipa"
rm -rf Payload
mkdir -p Payload
cp -R "$APP" Payload/MeterReader.app
chmod +x Payload/MeterReader.app/MeterReader
rm -rf Payload/MeterReader.app/_CodeSignature
zip -qry MeterReader-unsigned.ipa Payload

echo "==> Ad-hoc signing and packaging MeterReader-adhoc.ipa"
codesign --force --sign - --timestamp=none Payload/MeterReader.app
zip -qry MeterReader-adhoc.ipa Payload

echo
echo "Done:"
ls -lh MeterReader-unsigned.ipa MeterReader-adhoc.ipa
echo
echo "  MeterReader-adhoc.ipa    -> TrollStore"
echo "  MeterReader-unsigned.ipa -> AppSync Unified / AltStore / Sideloadly"
