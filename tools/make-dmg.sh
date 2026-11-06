#!/bin/zsh
# 공증·스테이플이 끝난 앱으로 배포용 DMG를 만든다: 앱과 응용 프로그램 바로가기 → 서명 → 공증 → 스테이플.
# 사용: tools/make-dmg.sh <앱 경로> <출력 dmg 경로>
set -euo pipefail

APP="$1"
DMG="$2"
PROFILE="${NOTARY_PROFILE:-discord-translator}"

IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)
if [[ -z "$IDENTITY" ]]; then
  print -u2 "Developer ID Application 인증서가 없습니다."
  exit 1
fi
# 공증 정보가 붙은 앱만 넣는다. 인터넷 없이 열어도 Gatekeeper가 확인할 수 있다.
xcrun stapler validate "$APP" >/dev/null

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/${APP:t}"
ln -s /Applications "$STAGE/응용 프로그램" # 창에서 앱을 여기로 끌어 놓으면 설치된다.

rm -f "$DMG"
hdiutil create -volname "디스코드 번역" -srcfolder "$STAGE" -format UDZO -ov "$DMG" >/dev/null

# DMG도 서명·공증해야 처음 열 때 Gatekeeper가 막지 않는다.
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
shasum -a 256 "$DMG"
