#!/bin/zsh
# 공개용 앱을 만든다: Developer ID 서명 → 공증 → 스테이플 → zip.
# 먼저 한 번 등록: xcrun notarytool store-credentials "discord-translator" --apple-id "이메일" --team-id "팀ID"
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-discord-translator}"
APP="build/디스코드 번역.app"
OUT="build/release"

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)
if [[ -z "$IDENTITY" ]]; then
  print -u2 "Developer ID Application 인증서가 없습니다. 애플 개발자 사이트에서 발급해 키체인에 넣어 주세요."
  exit 1
fi
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  print -u2 "공증 자격($PROFILE)이 없습니다. 이 파일 맨 위의 등록 명령을 한 번 실행해 주세요."
  exit 1
fi

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
rm -rf "$OUT"
mkdir -p "$OUT"

# 공증은 강화된 런타임과 시간 도장이 있어야 통과한다.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

SUBMIT="$OUT/submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$SUBMIT"

FINAL="$OUT/DiscordTranslator-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$FINAL"
shasum -a 256 "$FINAL"
print "완료: $FINAL"
