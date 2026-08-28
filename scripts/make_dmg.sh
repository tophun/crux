#!/bin/bash
# 서명된 Crux.app을 DMG로 포장한다.
#
# 사용법:
#   ./scripts/make_dmg.sh              # 앱을 빌드·서명한 뒤 DMG를 만든다
#   SKIP_BUILD=1 ./scripts/make_dmg.sh # 이미 빌드했을 때 포장만 한다
#
# 앱 서명은 make_app.sh와 같다. 개인 Apple Development 인증서를 쓴다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="${APP_NAME:-Crux}"
APP_DIR="$ROOT/.xcbuild/$APP_NAME.app"
DIST_DIR="$ROOT/dist"

"$ROOT/scripts/make_app.sh"

if [ ! -d "$APP_DIR" ]; then
  echo "앱 번들이 없습니다: $APP_DIR" >&2
  exit 1
fi

AUTHORITY="$(codesign -dv --verbose=2 "$APP_DIR" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
if [ -z "$AUTHORITY" ]; then
  if [ "${CODESIGN_IDENTITY:-}" = "-" ]; then
    AUTHORITY="ad-hoc"
  else
    echo "앱이 서명되어 있지 않습니다: $APP_DIR" >&2
    exit 1
  fi
fi
if [ -z "${CODESIGN_IDENTITY:-}" ] && ! printf '%s' "$AUTHORITY" | grep -q '@'; then
  echo "개인 Apple Development 인증서가 아닙니다: $AUTHORITY" >&2
  echo "회사 팀 인증서로 서명된 앱은 DMG에 넣지 않습니다." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/crux-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$DIST_DIR" "$STAGE"
ditto "$APP_DIR" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "서명: $AUTHORITY"
echo "생성: $DMG"
echo "설치: open \"$DMG\""
