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
# Signature stable : macOS reconnaît Rainette d'une compilation à l'autre et garde ses autorisations
# (Calendrier, Mail, Finder). Par ordre de préférence :
#  1. un trousseau dédié (~/Library/Keychains/rainette-signature.keychain-db) dont le mot de passe est dans
#     ~/Library/Application Support/Rainette/signature.motdepasse : aucune fenêtre du trousseau ;
#  2. un certificat « Rainette (local) » dans le trousseau de session ;
#  3. sinon, signature à la volée.
K="$HOME/Library/Keychains/rainette-signature.keychain-db"
MDP="$HOME/Library/Application Support/Rainette/signature.motdepasse"
if [[ -f "$K" && -f "$MDP" ]]; then
  security unlock-keychain -p "$(cat "$MDP")" "$K"
  # codesign ne cherche que dans la liste des trousseaux de l'utilisateur : on y ajoute le nôtre (sans retirer les autres).
  if ! security list-keychains -d user | grep -q "rainette-signature"; then
    eval "security list-keychains -d user -s $(security list-keychains -d user | tr '\n' ' ') \"$K\""
  fi
  ID=$(security find-identity -p codesigning "$K" | awk '/Rainette \(local\)/ {print $2; exit}')
  codesign --force --keychain "$K" --sign "$ID" --identifier com.fr0gzilla.rainette "$APP"
elif security find-identity -p codesigning 2>/dev/null | grep -q "Rainette (local)"; then
  codesign --force --sign "Rainette (local)" --identifier com.fr0gzilla.rainette "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "OK : $APP"
