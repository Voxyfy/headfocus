#!/bin/sh
# Yayın paketi: ./release.sh 0.2.0
#
# 1. Sürüm numarasını Info.plist'e yazar, derler.
# 2. "Developer ID Application" sertifikası varsa onunla, hardened runtime
#    ile imzalar (noter onayı bunu şart koşuyor); yoksa geliştirici
#    sertifikasıyla imzalar ve uyarır (yalnızca kendi Mac'lerinde açılır).
# 3. DMG üretir (Applications kısayoluyla).
# 4. Keychain'de "headfocus-notary" adlı notarytool profili varsa DMG'yi
#    Apple'a gönderir, onayı bekler, mührü basar.
# 5. gh kuruluysa ve GH_RELEASE=1 verildiyse GitHub Release oluşturur.
#
# Tek seferlik hazırlık (ücretli Apple Developer hesabı gerekir):
#   - developer.apple.com → Certificates → Developer ID Application → Keychain'e ekle
#   - appleid.apple.com → uygulamaya özel parola
#   - xcrun notarytool store-credentials headfocus-notary \
#         --apple-id you@example.com --team-id TEAMID --password app-specific-password
set -e
cd "$(dirname "$0")"

VERSION="${1:?kullanım: ./release.sh 0.2.0}"
BUILD=$(date +%Y%m%d%H%M)
APP="build/HeadFocus.app"
DMG="build/HeadFocus-$VERSION.dmg"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" Resources/Info.plist

./build.sh >/dev/null

DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
if [ -n "$DEV_ID" ]; then
  echo "imza: $DEV_ID"
  codesign --force --deep --options runtime --timestamp --sign "$DEV_ID" "$APP"
  SIGNED=1
else
  echo "UYARI: Developer ID sertifikası yok; paket yalnızca bu Mac'te ve geliştirici cihazlarında açılır."
  SIGNED=0
fi

rm -f "$DMG"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "HeadFocus" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "dmg: $DMG"

if [ "$SIGNED" = 1 ]; then
  codesign --force --timestamp --sign "$DEV_ID" "$DMG"
  if xcrun notarytool history --keychain-profile headfocus-notary >/dev/null 2>&1; then
    echo "noter onayı isteniyor…"
    xcrun notarytool submit "$DMG" --keychain-profile headfocus-notary --wait
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    echo "noter onayı tamam"
  else
    echo "UYARI: 'headfocus-notary' profili yok, noter onayı atlandı (Gatekeeper uyarı verir)."
  fi
fi

if [ "$GH_RELEASE" = 1 ] && command -v gh >/dev/null; then
  gh release create "v$VERSION" "$DMG" --title "HeadFocus $VERSION" --generate-notes
  echo "GitHub Release: v$VERSION"
fi
