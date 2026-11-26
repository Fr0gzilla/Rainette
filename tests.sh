#!/bin/zsh
# Tests des règles fragiles (dates, Teams, JSON du modèle, tri, cours, mer), sans lancer l'interface.
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 \
  Sources/Ollama.swift Sources/PagesWeb.swift Sources/Mails.swift Sources/Reglages.swift \
  Sources/EmploiDuTemps.swift Sources/Mer.swift Tests/Tests.swift -o build/tests
build/tests
