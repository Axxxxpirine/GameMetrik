#!/bin/bash
set -euo pipefail
IOS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 1 ]]; then
  echo 'Usage : ./iOSApp/scripts/install.sh IDENTIFIANT_IPHONE' >&2
  echo 'Appareils disponibles :' >&2
  xcrun devicectl list devices
  exit 1
fi
APP="$IOS_ROOT/build-device/Build/Products/Release-iphoneos/GameMetrik.app"
[[ -d "$APP" ]] || { echo 'Compiler et signer le paquet iPhone avant installation.' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
xcrun devicectl device install app --device "$1" "$APP"
echo 'GameMetrik est installé. Ouvre-le toi-même sur ton iPhone pour le premier essai.'
