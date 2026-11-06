#!/bin/zsh
# 「디스코드 번역.app」을 build/ 아래에 만든다.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/디스코드 번역.app"
VERSION="0.2.1"
REPOSITORY="datell1357/DiscordTranslator"
# Sparkle 업데이트 서명의 공개 키. 비밀 키는 출시하는 맥의 키체인(계정 discord-translator)에만 있다.
SPARKLE_PUBLIC_KEY="hOmHrbOk0JQbzshpgg8FHjv+eDJ5Ra3Mm1AiNg4tZiI="
SPARKLE=$(tools/fetch-sparkle.sh)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

# 대상을 정하지 않으면 빌드한 맥의 macOS 버전이 최소 버전이 된다.
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -module-name DiscordTranslator \
  -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  Sources/main.swift Sources/app.swift Sources/onboarding.swift Sources/updates.swift -o "$APP/Contents/MacOS/DiscordTranslator"
# XPC 서비스는 샌드박스 앱에만 필요하고(Sparkle 문서), 헤더는 빌드할 때만 쓴다. 실행 파일은 Apple 칩 부분만 남긴다.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE/Sparkle.framework" "$FRAMEWORK"
for part in XPCServices Headers PrivateHeaders Modules; do
  rm -rf "$FRAMEWORK/Versions/B/$part" "$FRAMEWORK/$part"
done
for binary in Sparkle Autoupdate Updater.app/Contents/MacOS/Updater; do
  lipo "$FRAMEWORK/Versions/B/$binary" -thin arm64 -output "$FRAMEWORK/Versions/B/$binary.arm64"
  mv "$FRAMEWORK/Versions/B/$binary.arm64" "$FRAMEWORK/Versions/B/$binary"
done
cp "$SPARKLE/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
cp Resources/inject.js "$APP/Contents/Resources/inject.js"
cp Resources/glossary.txt "$APP/Contents/Resources/glossary.txt"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>디스코드 번역</string>
  <key>CFBundleDisplayName</key><string>디스코드 번역</string>
  <key>CFBundleIdentifier</key><string>kr.yeoreum.discord-translator</string>
  <key>CFBundleExecutable</key><string>DiscordTranslator</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ko</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>SUFeedURL</key><string>https://github.com/$REPOSITORY/releases/latest/download/appcast.xml</string>
  <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
  <key>SUAutomaticallyUpdate</key><true/>
  <key>SUVerifyUpdateBeforeExtraction</key><true/>
  <key>SURequireSignedFeed</key><true/>
</dict>
</plist>
PLIST

tools/sign-app.sh - "$APP"
echo "완료: $APP"
