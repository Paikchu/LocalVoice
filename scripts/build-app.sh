#!/bin/zsh
set -euo pipefail

ROOT=${0:A:h:h}
DERIVED="$ROOT/.derived"
OUTPUT="$ROOT/build"

cd "$ROOT"
xcodegen generate
xcodebuild \
  -project LocalVoice.xcodeproj \
  -scheme LocalVoice \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$OUTPUT"
rm -rf "$OUTPUT/LocalVoice.app"
ditto "$DERIVED/Build/Products/Release/LocalVoice.app" "$OUTPUT/LocalVoice.app"
codesign --force --deep --sign - "$OUTPUT/LocalVoice.app"
