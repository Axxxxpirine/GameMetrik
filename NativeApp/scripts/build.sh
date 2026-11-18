#!/bin/bash
set -euo pipefail
NATIVE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/xcrun swift build --package-path "$NATIVE_ROOT" -c release
/usr/bin/python3 "$NATIVE_ROOT/scripts/package-app.py"
