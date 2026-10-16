#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="WebM Dönüştürücü.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
[ -f AppIcon.icns ] || { swift make_icon.swift AppIcon.iconset && iconutil -c icns AppIcon.iconset -o AppIcon.icns; }
cp AppIcon.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/tr.lproj" "$APP/Contents/Resources/en.lproj"
printf '"CFBundleDisplayName" = "WebM Dönüştürücü";\n"CFBundleName" = "WebM Dönüştürücü";\n' > "$APP/Contents/Resources/tr.lproj/InfoPlist.strings"
printf '"CFBundleDisplayName" = "WebM Converter";\n"CFBundleName" = "WebM Converter";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
swiftc -O -parse-as-library -swift-version 5 WebMConverter.swift -o "$APP/Contents/MacOS/WebMConverter"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WebMConverter</string>
<key>CFBundleIdentifier</key><string>com.muratgokoglu.webmconverter</string>
<key>CFBundleName</key><string>WebM Dönüştürücü</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
<key>LSHasLocalizedDisplayName</key><true/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHumanReadableCopyright</key><string>© 2026 Murat Gökoğlu</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force -s - "$APP"
echo "Hazır: $APP"
