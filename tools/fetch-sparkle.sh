#!/bin/zsh
# 자동 업데이트에 쓰는 Sparkle(https://sparkle-project.org)을 vendor/ 아래에 받고 그 폴더를 출력한다. 이미 있으면 받지 않는다.
# 받은 파일은 아래 SHA-256과 맞을 때만 푼다. 버전을 올릴 때는 두 값을 함께 바꾼다.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
DEST="vendor/Sparkle-$SPARKLE_VERSION"

if [[ -d "$DEST/Sparkle.framework" ]]; then
  print "$DEST"
  exit 0
fi

ARCHIVE=$(mktemp -t sparkle)
trap 'rm -f "$ARCHIVE"' EXIT
curl -fsSL -o "$ARCHIVE" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
ACTUAL=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
if [[ "$ACTUAL" != "$SPARKLE_SHA256" ]]; then
  print -u2 "Sparkle 파일이 예상과 다릅니다: $ACTUAL"
  exit 1
fi
rm -rf "$DEST"
mkdir -p "$DEST"
tar -xJf "$ARCHIVE" -C "$DEST"
print "$DEST"
