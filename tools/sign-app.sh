#!/bin/zsh
# 앱을 안쪽부터 서명한다: Sparkle 도우미 → Sparkle 프레임워크 → 앱. --deep은 쓰지 않는다(Sparkle 문서).
# 사용: tools/sign-app.sh <서명 이름 | - (임시 서명)> <앱 경로>
set -euo pipefail

IDENTITY="$1"
APP="$2"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

FLAGS=(--force --sign "$IDENTITY")
# 공증은 강화된 런타임과 시간 도장이 있어야 통과한다.
[[ "$IDENTITY" != "-" ]] && FLAGS+=(--options runtime --timestamp)

codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${FLAGS[@]}" "$SPARKLE"
codesign "${FLAGS[@]}" "$APP"
