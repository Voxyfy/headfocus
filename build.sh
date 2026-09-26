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
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Gerçek geliştirici imzası varsa onunla: ekran kaydı ve hareket izinleri
# imzaya bağlı, geçici (ad-hoc) imzada her derlemede yeniden soruluyor.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development: [^"]*"' | head -1 | tr -d '"')
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP" >/dev/null 2>&1 || codesign --force --sign - "$APP" >/dev/null 2>&1
else
  codesign --force --sign - "$APP" >/dev/null 2>&1
fi
echo "hazır: $APP"
