#!/bin/zsh
# 공개용 앱을 만든다: Developer ID 서명 → 공증 → 스테이플 → DMG(서명·공증) → Sparkle 업데이트 목록(appcast.xml).
# 먼저 한 번 등록: xcrun notarytool store-credentials "discord-translator" --apple-id "이메일" --team-id "팀ID"
# 업데이트 서명 키는 키체인의 Sparkle 항목(계정 discord-translator)에 있어야 한다. 다른 맥으로 옮길 때는
# vendor/Sparkle-<버전>/bin/generate_keys --account discord-translator 의 -x(내보내기)와 -f(가져오기)를 쓴다.
# 사용: RELEASE_NOTES=노트.md tools/release.sh  (노트는 앱의 업데이트 창에 그대로 나온다. 없으면 노트 없이 낸다.)
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-discord-translator}"
SPARKLE_ACCOUNT="discord-translator"
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
SPARKLE=$(tools/fetch-sparkle.sh)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
FEED=$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")
# 키체인의 업데이트 서명 키가 앱에 든 공개 키와 짝이어야 사용자 앱이 새 버전을 받아들인다.
PUBLIC_KEY=$("$SPARKLE/bin/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null || true)
if [[ "$PUBLIC_KEY" != "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")" ]]; then
  print -u2 "업데이트 서명 키(키체인 계정 $SPARKLE_ACCOUNT)가 없거나 앱의 공개 키와 다릅니다. 이 파일 맨 위의 안내대로 가져와 주세요."
  exit 1
fi
rm -rf "$OUT"
mkdir -p "$OUT"

tools/sign-app.sh "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

SUBMIT="$OUT/submit.zip"
ditto -c -k --keepParent "$APP" "$SUBMIT"
xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose "$APP"
rm -f "$SUBMIT"

FINAL="$OUT/DiscordTranslator-$VERSION.dmg"
tools/make-dmg.sh "$APP" "$FINAL"

# 업데이트 목록: 앱이 releases/latest/download/appcast.xml을 읽으니, 이 출시의 첨부 파일로 DMG와 함께 올린다.
# DMG와 목록 모두 출시 키로 서명된다(키가 앱의 공개 키와 짝인지는 위에서 확인했다).
if [[ -n "${RELEASE_NOTES:-}" ]]; then
  cp "$RELEASE_NOTES" "$OUT/DiscordTranslator-$VERSION.md"
fi
"$SPARKLE/bin/generate_appcast" --account "$SPARKLE_ACCOUNT" --embed-release-notes \
  --download-url-prefix "${FEED%/latest/download/appcast.xml}/download/v$VERSION/" "$OUT"
rm -f "$OUT/DiscordTranslator-$VERSION.md"
print "완료: $FINAL, $OUT/appcast.xml (둘 다 v$VERSION 출시에 올린다)"
