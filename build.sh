#!/usr/bin/env bash
#
# build.sh — build "Merge Goblin.app".
#
#   ./build.sh                 release build into build/Merge Goblin.app (ad-hoc signed)
#   ./build.sh --dev           same, but a separate bundle id, so it can run next to
#                              an installed copy instead of handing over to it
#   ./build.sh --universal     arm64 + x86_64
#   ./build.sh --sign "Developer ID Application: Name (TEAMID)"
#                              hardened-runtime signature, ready for notarisation
#   ./build.sh --dmg           also make build/MergeGoblin-<version>.dmg
#   ./build.sh --out <dir>
#
# The engine (bin/ lib/ share/ templates/) is copied INTO the bundle, so the app and
# the scripts it drives are always the same version and an install is one file.
# Needs only the Xcode command line tools: no .xcodeproj, no asset catalog.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/brand.sh
. "$ROOT/lib/brand.sh"

DEV=false; UNIVERSAL=false; SIGN="-"; DMG=false; OUT="$ROOT/build"
while [ $# -gt 0 ]; do
  case "$1" in
    --dev) DEV=true; shift ;;
    --universal) UNIVERSAL=true; shift ;;
    --sign) SIGN="${2:?--sign needs an identity}"; shift 2 ;;
    --dmg) DMG=true; shift ;;
    --out) OUT="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

EXEC_NAME="GoblinBar"
BUNDLE_ID="app.mergegoblin.MergeGoblin"; $DEV && BUNDLE_ID="$BUNDLE_ID.dev"
NAME="$GOBLIN_SHORT"; $DEV && NAME="$GOBLIN_SHORT Dev"
APP="$OUT/$NAME.app"

echo "building $NAME $GOBLIN_VERSION"
ARCHS=(); $UNIVERSAL && ARCHS=(--arch arm64 --arch x86_64)
( cd "$ROOT" && swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} >&2 )
BIN="$( cd "$ROOT" && swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path )/$EXEC_NAME"
[ -x "$BIN" ] || { echo "build produced no executable" >&2; exit 1; }

STAGE="$(mktemp -d)/$NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources/engine"
cp "$BIN" "$STAGE/Contents/MacOS/$EXEC_NAME"
cp "$ROOT"/Sources/Goblin/Resources/*.icns "$ROOT"/Sources/Goblin/Resources/*.png "$STAGE/Contents/Resources/"

ENG="$STAGE/Contents/Resources/engine"
mkdir -p "$ENG/bin" "$ENG/share" "$ENG/templates"
cp "$ROOT/bin/goblin" "$ENG/bin/goblin"
cp -R "$ROOT/lib" "$ENG/lib"
for d in jq prompt schema; do cp -R "$ROOT/share/$d" "$ENG/share/$d"; done
cp "$ROOT"/templates/*.tmpl "$ENG/templates/"
chmod +x "$ENG/bin/goblin"

sed -e "s|__SHORT__|$NAME|g" -e "s|__VERSION__|$GOBLIN_VERSION|g" \
    -e "s|__BUNDLE_ID__|$BUNDLE_ID|g" -e "s|__EXEC__|$EXEC_NAME|g" \
    -e "s|__CLI__||g" -e "s|__GOBLIN_HOME__||g" \
    "$ROOT/templates/app-info.plist.tmpl" > "$STAGE/Contents/Info.plist"
plutil -lint "$STAGE/Contents/Info.plist" >/dev/null

# AFTER every file is in place: a signature covers the bundle's contents.
if [ "$SIGN" = "-" ]; then
  codesign --force --sign - --identifier "$BUNDLE_ID" "$STAGE" >/dev/null 2>&1 || echo "! ad-hoc signing failed" >&2
else
  codesign --force --options runtime --timestamp --sign "$SIGN" --identifier "$BUNDLE_ID" "$STAGE"
fi

mkdir -p "$OUT"; rm -rf "$APP"; ditto "$STAGE" "$APP"; rm -rf "$(dirname "$STAGE")"
echo "built: $APP"

if $DMG; then
  D="$OUT/MergeGoblin-$GOBLIN_VERSION.dmg"; rm -f "$D"
  BG="$ROOT/design/dmg-background.png"
  T="$(mktemp -d)"; RW="$T/rw.dmg"; MNT="/Volumes/$GOBLIN_SHORT"
  # Finder addresses the volume by name, so it has to mount at the default place.
  hdiutil detach -quiet "$MNT" 2>/dev/null || true
  # A writable image first, so Finder can be told how the window should look; it is
  # converted to a compressed read-only image at the end.
  hdiutil create -quiet -size 120m -fs HFS+ -volname "$GOBLIN_SHORT" -ov "$RW"
  hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"
  cp -R "$APP" "$MNT/"; ln -s /Applications "$MNT/Applications"
  STYLED=false
  if [ -f "$BG" ]; then
    # Finder draws a background at its pixel size, so a 1320x800 picture would be
    # cropped in a 660x400 window. A two-resolution TIFF is how it picks the sharp one.
    mkdir "$MNT/.background"
    sips -z 400 660 "$BG" --out "$T/bg.png" >/dev/null 2>&1 && cp "$BG" "$T/bg@2x.png" \
      && tiffutil -cathidpicheck "$T/bg.png" "$T/bg@2x.png" -out "$MNT/.background/background.tiff" >/dev/null 2>&1 \
      || cp "$BG" "$MNT/.background/background.tiff"
    # Window 660x400, the app on the left and Applications on the right, where the
    # artwork leaves two clear zones. Finder may be unavailable (SSH, some CI): the
    # image is then simply plain, which still installs fine.
    if osascript >/dev/null 2>"$T/osascript.err" <<APPLESCRIPT
tell application "Finder"
  tell disk "$GOBLIN_SHORT"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "$NAME.app" of container window to {170, 200}
    set position of item "Applications" of container window to {490, 200}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
    then STYLED=true; else head -c 400 "$T/osascript.err" >&2; fi
  fi
  sync; hdiutil detach -quiet "$MNT" || { sleep 2; hdiutil detach -quiet -force "$MNT"; }
  hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$D"
  rm -rf "$T"
  $STYLED || echo "(the disk image is plain: Finder could not be scripted)" >&2
  [ "$SIGN" = "-" ] || codesign --force --timestamp --sign "$SIGN" "$D"
  echo "built: $D"
fi
