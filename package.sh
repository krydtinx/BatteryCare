#!/bin/bash
set -e

VERSION=${1:-1.0}
DERIVED_DATA=/tmp/BatteryCare-build
APP_PATH="$DERIVED_DATA/Build/Products/Release/BatteryCare.app"
PKG_OUT="dist/BatteryCare-$VERSION.pkg"

mkdir -p dist

echo "==> Building Release..."
xcodebuild \
    -project BatteryCare/BatteryCare.xcodeproj \
    -scheme BatteryCare \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    build | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)"

echo "==> Packaging $APP_PATH -> $PKG_OUT"
chmod +x packaging/scripts/postinstall

pkgbuild \
    --component "$APP_PATH" \
    --install-location /Applications \
    --scripts packaging/scripts \
    --identifier com.batterycare.app \
    --version "$VERSION" \
    "$PKG_OUT"

echo ""
echo "Done: $PKG_OUT"
echo "Install with: sudo installer -pkg $PKG_OUT -target /"
