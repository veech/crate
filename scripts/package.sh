#!/bin/zsh
# Assemble dist/Slipmat.app from a release build.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=dist/Slipmat.app
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Slipmat "$APP/Contents/MacOS/Slipmat"
cp -R .build/release/slipmat_Slipmat.bundle "$APP/Contents/Resources/"
cp -R .build/release/GRDB_GRDB.bundle "$APP/Contents/Resources/"

# Liquid Glass icon (macOS 26+) plus the icns fallback actool renders from
# it. Absolute paths: actool's ibtoold daemon resolves relative ones against
# its own working directory, not ours.
xcrun actool "$PWD/Slipmat.icon" --compile "$PWD/$APP/Contents/Resources" \
    --output-format human-readable-text --warnings --errors \
    --platform macosx --minimum-deployment-target 15.0 \
    --app-icon Slipmat --include-all-app-icons \
    --output-partial-info-plist "$PWD/dist/actool-partial.plist"
rm -f dist/actool-partial.plist

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Slipmat</string>
    <key>CFBundleDisplayName</key>
    <string>Slipmat</string>
    <key>CFBundleIdentifier</key>
    <string>me.veech.slipmat</string>
    <key>CFBundleExecutable</key>
    <string>Slipmat</string>
    <key>CFBundleIconFile</key>
    <string>Slipmat</string>
    <key>CFBundleIconName</key>
    <string>Slipmat</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "built: $APP"
