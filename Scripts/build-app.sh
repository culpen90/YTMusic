#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
VERSION_FILE="$PROJECT_DIR/VERSION"
FINAL_APP_DIR="$PROJECT_DIR/dist/Liltfinch.app"
FINAL_ZIP="$PROJECT_DIR/dist/Liltfinch.zip"
BUILD_WORK="$(mktemp -d)"
trap '/bin/rm -rf "$BUILD_WORK"' EXIT
APP_DIR="$BUILD_WORK/Liltfinch.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

if [[ ! -f "$VERSION_FILE" ]]; then
  print -u2 "Missing app version file: $VERSION_FILE"
  exit 1
fi

APP_VERSION="$(<"$VERSION_FILE")"
if [[ "$APP_VERSION" == *$'\n'* ]]; then
  print -u2 "Invalid app version '$APP_VERSION' in $VERSION_FILE (expected one line)"
  exit 1
fi

VERSION_COMPONENT='(0|[1-9][0-9]{0,8})'
if print -r -- "$APP_VERSION" | /usr/bin/grep -Eq "^${VERSION_COMPONENT}(\.${VERSION_COMPONENT}){2}$"; then
  MARKETING_VERSION="$APP_VERSION"
  PRERELEASE_BUILD=9999
elif print -r -- "$APP_VERSION" | /usr/bin/grep -Eq "^${VERSION_COMPONENT}(\.${VERSION_COMPONENT}){2}-beta[1-9][0-9]{0,3}$"; then
  MARKETING_VERSION="${APP_VERSION%%-*}"
  PRERELEASE_BUILD="${APP_VERSION##*-beta}"
  if (( PRERELEASE_BUILD > 9998 )); then
    print -u2 "Invalid beta number '$PRERELEASE_BUILD' in $VERSION_FILE (expected 1 through 9998)"
    exit 1
  fi
else
  print -u2 "Invalid app version '$APP_VERSION' in $VERSION_FILE (expected MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-betaN)"
  exit 1
fi

BUILD_VERSION="$PRERELEASE_BUILD"

function verify_app_version() {
  local info_plist="$1"
  local app_version
  local marketing_version
  local bundle_version
  app_version="$(/usr/bin/plutil -extract LiltfinchVersion raw "$info_plist")"
  marketing_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$info_plist")"
  bundle_version="$(/usr/bin/plutil -extract CFBundleVersion raw "$info_plist")"

  if [[ "$app_version" != "$APP_VERSION" || "$marketing_version" != "$MARKETING_VERSION" || "$bundle_version" != "$BUILD_VERSION" ]]; then
    print -u2 "Version verification failed for $info_plist"
    exit 1
  fi
}

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
/usr/bin/plutil -insert LiltfinchVersion -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD_VERSION" "$CONTENTS_DIR/Info.plist"

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
verify_app_version "$CONTENTS_DIR/Info.plist"
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
verify_app_version "$VERIFY_WORK/Liltfinch.app/Contents/Info.plist"

/usr/bin/ditto "$APP_DIR" "$FINAL_APP_DIR"
/usr/bin/xattr -cr "$FINAL_APP_DIR"

print "Version $APP_VERSION"
print "$FINAL_APP_DIR"
print "$FINAL_ZIP"
