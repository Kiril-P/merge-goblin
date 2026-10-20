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
  T="$(mktemp -d)"; cp -R "$APP" "$T/"; ln -s /Applications "$T/Applications"
  hdiutil create -quiet -volname "$GOBLIN_SHORT" -srcfolder "$T" -ov -format UDZO "$D"
  rm -rf "$T"; echo "built: $D"
fi
