#!/bin/bash
# Explicit submission only: ./NativeApp/scripts/notarize.sh NAME_OF_KEYCHAIN_PROFILE
set -euo pipefail
NATIVE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$NATIVE_ROOT/dist/GameMetrik Native.app"
if [[ $# != 1 ]]; then printf '%s\n' 'Usage: notarize.sh NOTARYTOOL_KEYCHAIN_PROFILE' >&2; exit 2; fi
/usr/bin/codesign --verify --deep --strict "$APP"
SIGNATURE="$(/usr/bin/codesign -dv "$APP" 2>&1)"
if [[ "$SIGNATURE" != *"Authority=Developer ID Application:"* ]]; then printf '%s\n' 'Notarisation impossible : ce paquet doit être signé Developer ID Application.' >&2; exit 1; fi
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto -c -k --keepParent "$APP" "$STAGE/GameMetrik.zip"
/usr/bin/xcrun notarytool submit "$STAGE/GameMetrik.zip" --keychain-profile "$1" --wait --timeout 15m
/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose "$APP"
