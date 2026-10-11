#!/bin/zsh
# Собирает «Локалки», ставит в ~/Applications и включает автозапуск при входе.
set -e
cd "${0:A:h}"

APP="build/Локалки.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS"

swiftc -O -parse-as-library -target arm64-apple-macos14 \
  Sources/*.swift -o "$APP/Contents/MacOS/Localki"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.danyaeast.localki</string>
  <key>CFBundleName</key><string>Локалки</string>
  <key>CFBundleExecutable</key><string>Localki</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP"

DEST="$HOME/Applications/Локалки.app"
mkdir -p "$HOME/Applications"
launchctl bootout "gui/$UID/com.danyaeast.localki" 2>/dev/null || true
rm -rf "$DEST" && cp -R "$APP" "$DEST"

AGENT="$HOME/Library/LaunchAgents/com.danyaeast.localki.plist"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.danyaeast.localki</string>
  <key>ProgramArguments</key><array><string>$DEST/Contents/MacOS/Localki</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl bootstrap "gui/$UID" "$AGENT"
echo "Готово: $DEST, автозапуск включён"
