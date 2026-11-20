#!/bin/zsh
# Compile Rainette.app (sans Xcode, avec les outils en ligne de commande).
set -euo pipefail
cd "${0:A:h}"
APP=build/Rainette.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/*.swift -o "$APP/Contents/MacOS/Rainette"
# Signature stable avec le certificat local « Rainette (local) » (trousseau de session) :
# macOS reconnaît Rainette d'une compilation à l'autre et garde ses autorisations
# (Calendrier, Mail, Finder). Sans ce certificat, signature à la volée.
if security find-identity -p codesigning 2>/dev/null | grep -q "Rainette (local)"; then
  codesign --force --sign "Rainette (local)" --identifier com.fr0gzilla.rainette "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "OK : $APP"
