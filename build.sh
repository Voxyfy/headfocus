#!/bin/sh
# HeadFocus.app paketini üretir. SwiftPM tek başına .app yapmıyor; ikili
# elle bir bundle'a konuyor. Kulaklık hareket izni ve bildirimler bundle
# ve Info.plist olmadan çalışmıyor, o yüzden çıplak ikili yetmiyor.
set -e
cd "$(dirname "$0")"
swift build -c release 2>&1 | tail -3
APP="build/HeadFocus.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/HeadFocus "$APP/Contents/MacOS/HeadFocus"
cp Resources/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
# Geçici imza: izin istemleri imzasız ikilide sessizce reddediliyor.
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "hazır: $APP"
