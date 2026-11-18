#!/bin/bash
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$IOS_ROOT"
command -v xcodegen >/dev/null || { echo 'Installer XcodeGen pour générer le projet.' >&2; exit 1; }
xcodegen generate --spec project.yml
xcodebuild -project GameMetrik.xcodeproj -scheme GameMetrik -configuration Release -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
