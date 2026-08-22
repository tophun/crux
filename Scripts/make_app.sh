#!/bin/bash
# Crux 앱 번들 생성.
#
# EventKit(캘린더), 마이크, 화면 기록 권한은 번들 식별자 기준으로 부여되므로
# 실행 파일이 아니라 .app 번들로 실행해야 한다.
#
# 사용법:
#   ./Scripts/make_app.sh              # 빌드하고 번들까지 만든다
#   SKIP_BUILD=1 ./Scripts/make_app.sh # 이미 빌드했을 때 포장만 한다
#
# swift build로는 MLX의 Metal 셰이더를 컴파일할 수 없어 xcodebuild를 쓴다.
# -skipMacroValidation은 mlx-swift-lm 매크로 신뢰 확인을 건너뛰기 위한 것이다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Debug}"
BINARY="$ROOT/.xcbuild/Build/Products/$CONFIG/MeetingApp"
# 실행 파일·번들 디렉터리 이름(공백 없음)과 사용자에게 보이는 이름을 분리한다.
APP_NAME="${APP_NAME:-Crux}"
DISPLAY_NAME="${DISPLAY_NAME:-Crux}"
# Developer ID를 쓰게 되면 BUNDLE_ID를 조직 도메인으로 바꾼다.
BUNDLE_ID="${BUNDLE_ID:-local.crux.app}"
APP_DIR="$ROOT/.xcbuild/$APP_NAME.app"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  echo "MeetingApp 빌드 중… (Metal 셰이더 때문에 첫 빌드는 오래 걸린다)"
  xcodebuild -scheme MeetingApp -destination 'platform=OS X,arch=arm64' \
    -derivedDataPath "$ROOT/.xcbuild" -configuration "$CONFIG" \
    -skipMacroValidation build >"$ROOT/.xcbuild/build.log" 2>&1 || {
    echo "빌드 실패. 로그: $ROOT/.xcbuild/build.log" >&2
    tail -20 "$ROOT/.xcbuild/build.log" >&2
    exit 1
  }
fi

if [ ! -x "$BINARY" ]; then
  echo "실행 파일이 없습니다: $BINARY" >&2
  echo "SKIP_BUILD를 쓰지 말고 다시 실행하세요." >&2
  exit 1
fi

# 빌드한 실행 파일이 지금 소스보다 오래됐으면 포장해도 소용없다. 바로 알린다.
NEWEST_SOURCE="$(find "$ROOT/Sources" -name '*.swift' -newer "$BINARY" -print -quit)"
if [ -n "$NEWEST_SOURCE" ]; then
  echo "경고: 빌드 산출물이 소스보다 오래됐습니다 ($NEWEST_SOURCE)" >&2
  echo "SKIP_BUILD 없이 다시 실행해 빌드부터 하세요." >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

# SwiftPM 리소스 번들을 함께 넣는다.
for bundle in "$ROOT/.xcbuild/Build/Products/$CONFIG/"*.bundle; do
  [ -e "$bundle" ] || continue
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done

# MLX Metal 셰이더는 실행 파일 옆의 mlx.metallib를 가장 먼저 찾는다.
# 앱 번들에서는 SwiftPM 리소스 번들 탐색이 동작하지 않으므로 여기에 함께 둔다.
METALLIB="$ROOT/.xcbuild/Build/Products/$CONFIG/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ -f "$METALLIB" ]; then
  cp "$METALLIB" "$APP_DIR/Contents/MacOS/mlx.metallib"
else
  echo "경고: mlx metallib을 찾지 못했습니다. 앱에서 회의록 생성 단계가 실패할 수 있습니다." >&2
fi

# 앱 아이콘 (Fixtures/icon/AppIcon.icns — 원본은 source.png)
if [ -f "$ROOT/Fixtures/icon/AppIcon.icns" ]; then
  cp "$ROOT/Fixtures/icon/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>회의 음성을 이 기기에서 녹음하고 회의록을 만들기 위해 마이크를 사용합니다. 녹음 파일은 외부로 전송되지 않습니다.</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>회의 일정을 읽어 회의 시작을 감지하고 회의록의 제목·날짜·참석자를 채우기 위해 캘린더를 사용합니다. 일정 정보는 이 기기에만 저장됩니다.</string>
  <key>NSCalendarsUsageDescription</key>
  <string>회의 일정을 읽어 회의 시작을 감지하기 위해 캘린더를 사용합니다.</string>
</dict>
</plist>
PLIST

# 권한(TCC)은 서명 신원 기준으로 기억된다. ad-hoc 서명은 빌드마다 바뀌어
# 매번 권한을 다시 물으므로, 가능하면 안정적인 개발 인증서로 서명한다.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --sign "$IDENTITY" "$APP_DIR" >/dev/null 2>&1 \
    && echo "서명: $IDENTITY (권한 승인 유지됨)" \
    || echo "경고: '$IDENTITY' 서명 실패. ad-hoc으로 대체합니다." >&2
fi
codesign --verify "$APP_DIR" >/dev/null 2>&1 || codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || {
  echo "경고: 코드 서명에 실패했습니다. 권한 요청이 매번 다시 뜰 수 있습니다." >&2
}

echo "생성: $APP_DIR"
echo "실행: open \"$APP_DIR\""
echo ""
echo "권한 안내"
echo "- 마이크: 첫 녹음 시 요청됩니다."
echo "- 캘린더: 설정 화면의 '캘린더 권한 요청'을 누르세요."
echo "- 시스템 오디오: 시스템 설정 → 개인정보 보호 및 보안 → 화면 및 시스템 오디오 기록에서 이 앱을 허용하세요."
