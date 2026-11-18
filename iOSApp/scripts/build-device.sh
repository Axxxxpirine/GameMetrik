#!/bin/bash
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAMEMETRIK_APPLE_TEAM="${GAMEMETRIK_APPLE_TEAM:-YOUR_TEAM_ID}"
cd "$IOS_ROOT"
xcodegen generate --spec project.yml
# Local profiles only: no -allowProvisioningUpdates and no upload.
xcodebuild -project GameMetrik.xcodeproj -scheme GameMetrik -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build-device \
  DEVELOPMENT_TEAM="$GAMEMETRIK_APPLE_TEAM" CODE_SIGN_STYLE=Automatic build
codesign --verify --deep --strict "$IOS_ROOT/build-device/Build/Products/Release-iphoneos/GameMetrik.app"
