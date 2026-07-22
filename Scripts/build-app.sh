#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
FINAL_APP_DIR="$PROJECT_DIR/dist/Liltfinch.app"
FINAL_ZIP="$PROJECT_DIR/dist/Liltfinch.zip"
BUILD_WORK="$(mktemp -d)"
trap '/bin/rm -rf "$BUILD_WORK"' EXIT
APP_DIR="$BUILD_WORK/Liltfinch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

case "$FINAL_APP_DIR" in
  "$PROJECT_DIR"/dist/Liltfinch.app) ;;
  *) print -u2 "Refusing to build outside the project dist directory"; exit 1 ;;
esac

case "$FINAL_ZIP" in
  "$PROJECT_DIR"/dist/Liltfinch.zip) ;;
  *) print -u2 "Refusing to archive outside the project dist directory"; exit 1 ;;
esac

cd "$PROJECT_DIR"
swift build -c release --arch arm64 --arch x86_64 --product Liltfinch
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

/bin/mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
/usr/bin/ditto "$BIN_DIR/Liltfinch" "$MACOS_DIR/Liltfinch"
/usr/bin/ditto "$PROJECT_DIR/Support/Info.plist" "$CONTENTS_DIR/Info.plist"

RESOURCE_BUNDLE="$BIN_DIR/Liltfinch_Liltfinch.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  /usr/bin/ditto "$RESOURCE_BUNDLE" "$RESOURCES_DIR/Liltfinch_Liltfinch.bundle"
fi

ICON_WORK="$BUILD_WORK/IconWork"
/bin/mkdir -p "$ICON_WORK"
ICONSET="$ICON_WORK/AppIcon.iconset"
/bin/mkdir -p "$ICONSET"
/usr/bin/sips -s format png "$PROJECT_DIR/Sources/Liltfinch/Resources/AppIcon.svg" --out "$ICON_WORK/base.png" >/dev/null

function make_icon() {
  local pixels="$1"
  local filename="$2"
  /usr/bin/sips -z "$pixels" "$pixels" "$ICON_WORK/base.png" --out "$ICONSET/$filename" >/dev/null
}

make_icon 16 icon_16x16.png
make_icon 32 icon_16x16@2x.png
make_icon 32 icon_32x32.png
make_icon 64 icon_32x32@2x.png
make_icon 128 icon_128x128.png
make_icon 256 icon_128x128@2x.png
make_icon 256 icon_256x256.png
make_icon 512 icon_256x256@2x.png
make_icon 512 icon_512x512.png
make_icon 1024 icon_512x512@2x.png
/usr/bin/iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns"

/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
/usr/bin/xattr -cr "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"

/bin/rm -rf "$FINAL_APP_DIR"
/bin/rm -f "$FINAL_ZIP"
/usr/bin/ditto -c -k --norsrc --keepParent "$APP_DIR" "$FINAL_ZIP"

VERIFY_WORK="$BUILD_WORK/Verify"
/bin/mkdir -p "$VERIFY_WORK"
/usr/bin/ditto -x -k "$FINAL_ZIP" "$VERIFY_WORK"
/usr/bin/codesign --verify --deep --strict "$VERIFY_WORK/Liltfinch.app"

/usr/bin/ditto "$APP_DIR" "$FINAL_APP_DIR"
/usr/bin/xattr -cr "$FINAL_APP_DIR"

print "$FINAL_APP_DIR"
print "$FINAL_ZIP"
