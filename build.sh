#!/bin/zsh
# 「디스코드 번역.app」을 build/ 아래에 만든다.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/디스코드 번역.app"
VERSION="0.2.1"
REPOSITORY="datell1357/DiscordTranslator"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 대상을 정하지 않으면 빌드한 맥의 macOS 버전이 최소 버전이 된다.
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 -module-name DiscordTranslator \
  Sources/main.swift Sources/app.swift Sources/onboarding.swift -o "$APP/Contents/MacOS/DiscordTranslator"
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
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>KRTReleasesURL</key><string>https://api.github.com/repos/$REPOSITORY/releases/latest</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "완료: $APP"
