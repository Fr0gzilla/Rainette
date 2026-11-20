# 🐸 Rainette

Un widget de bureau pour macOS qui fait le point de ta journée : mails importants, agenda, cours, messages Teams et conditions en mer. Avec une IA **100 % locale** (Ollama) à qui tu parles comme à un pote.

Rien ne part sur un serveur d'IA : le tri des mails, les résumés et la discussion tournent sur ton Mac.

## Ce qu'elle fait

- **Mails** : lit les non-lus des dernières 72 h dans l'app Mail (et dans Outlook web si tu as un compte Microsoft 365), garde les importants, les résume en une phrase et en tire une liste « À faire » à cocher. Seuls les nouveaux mails passent par l'IA : les verdicts sont mémorisés.
- **Répondre à un mail** : tu dis en vrac ce que tu veux répondre, Rainette te demande le ton (formel ou tranquille), reformule, corrige, et tu relis avant d'envoyer. Rien ne part sans ton clic.
- **Agenda** : tes évènements d'aujourd'hui et de demain (calendrier Apple). Tu peux lui demander d'en ajouter (« mets foot jeudi 18h ») : elle te montre l'évènement et attend ta confirmation.
- **Cours** : ton emploi du temps, lu sur une plateforme d'école **Pepal** (connexion Microsoft), mêlé à ton agenda.
- **Teams** : le nombre de messages non lus, et le dernier message de quelques personnes choisies. Lecture discrète : rien n'est marqué comme lu.
- **Mer** : pour un spot de navigation (catamaran, voile) et un spot de surf, un avis du moment (« Top », « Pétole », « Trop gros »…) et le meilleur créneau à venir, via [Open-Meteo](https://open-meteo.com) (gratuit, sans clé).
- **Widget** : collé au bureau, sous les fenêtres. Il se déplace et se redimensionne depuis son menu, en s'aimantant aux bords de l'écran et aux widgets macOS. Les fichiers posés sur le bureau sont poussés hors de sa zone.

## Prérequis

- macOS 14 ou plus récent, Mac Apple Silicon.
- Les outils en ligne de commande d'Apple (`xcode-select --install`). Xcode n'est pas nécessaire.
- [Ollama](https://ollama.com) avec le modèle `qwen3.5:9b` :

  ```sh
  brew install ollama
  brew services start ollama
  ollama pull qwen3.5:9b
  ```

## Installation

```sh
git clone https://github.com/Fr0gzilla/Rainette.git
cd Rainette
./build.sh
open build/Rainette.app
```

`build.sh` compile avec le SDK indiqué dans le script : adapte le chemin `MacOSX26.5.sdk` à celui présent dans `/Library/Developer/CommandLineTools/SDKs/` si besoin.

Au premier lancement, macOS demande l'accès au calendrier, puis l'autorisation de piloter Mail (et le Finder, pour pousser les fichiers du bureau).

### Garder les autorisations entre deux compilations (facultatif)

Sans certificat, l'app est signée « à la volée » et macOS peut redemander les autorisations après chaque compilation. Si un certificat de signature nommé **« Rainette (local) »** existe dans ton trousseau, `build.sh` l'utilise et l'identité de l'app reste stable. Un certificat auto-signé suffit (usage : signature de code).

### Lancer Rainette à l'ouverture de session (facultatif)

Crée `~/Library/LaunchAgents/com.exemple.rainette.plist` en remplaçant le chemin :

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.exemple.rainette</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/open</string><string>/chemin/vers/Rainette/build/Rainette.app</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
```

puis `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.exemple.rainette.plist`.

## Réglages

Tout ce qui est personnel (nom, adresses, contacts, école, spots) est dans un fichier qui reste sur ton Mac :

```
~/Library/Application Support/Rainette/reglages.json
```

Copie [`reglages.exemple.json`](reglages.exemple.json) à cet endroit et adapte-le, puis relance Rainette. Tout est facultatif : une partie sans réglage est simplement masquée.

| Clé | Rôle |
|---|---|
| `prenom`, `nomComplet` | Pour que l'IA s'adresse à toi et signe tes réponses (formelles : nom complet, tranquilles : prénom). |
| `profil` | Qui tu es en une phrase : aide l'IA à juger ce qui est important. |
| `comptesMail` | Comptes de l'app Mail à lire. Liste vide = tous les comptes actifs. |
| `compteMicrosoft` | Compte Microsoft 365 (école, travail) pour Outlook web, Teams web et la connexion à l'emploi du temps. |
| `outlook`, `teams` | Activer ou non chacun des deux. |
| `contactsTeams` | Les seules personnes dont Rainette lit les messages Teams. |
| `emploiDuTemps` | `nom` affiché et `adresse` de la page d'emploi du temps (plateforme Pepal). |
| `mer` | `navigation` et `surf` : un nom, et deux points `[latitude, longitude]` (le vent près de la plage, la houle un peu au large). |

Pour Outlook, Teams et l'emploi du temps, clique sur le bouton « Brancher » qui apparaît dans le widget et connecte-toi une fois. Rainette garde la session et ouvre ces pages en arrière-plan seulement le temps de les lire.

## Utilisation

- **Barre « Tu veux quoi… »** : « j'ai quoi demain ? », « ajoute dentiste le 3 décembre à 10h30 », « réponds à Alex que c'est ok pour mardi ».
- **Flèche ↩ sur un mail** : prépare une réponse à ce mail.
- **Menu ⋯** : brancher Outlook / Teams, bouger ou redimensionner le widget, fermer Rainette.
- **Journal** (pour comprendre ce qu'elle a vu) : `~/Library/Application Support/Rainette/journal.txt`.

## Vie privée

- L'IA tourne en local avec Ollama : tes mails ne sont envoyés à aucun service d'IA.
- Les seules requêtes externes sont celles de tes propres services (Mail, Outlook, Teams, ton école) et d'Open-Meteo (avec seulement les coordonnées de tes spots).
- Rien n'est envoyé, ajouté à ton agenda ou écrit dans Teams sans ton clic.

## Limites

- Outlook web, Teams web et la plateforme Pepal sont lus dans leurs pages web : un changement de leur interface peut casser la lecture.
- Teams : seul l'aperçu du dernier message de chaque conversation est lu.
- Interface et consignes de l'IA en français.

## Structure

| Fichier | Rôle |
|---|---|
| `Sources/main.swift` | État, discussion avec l'IA et ses outils, vue du widget, fenêtre |
| `Sources/Mails.swift` | Lecture de l'app Mail, tri et résumés |
| `Sources/Reponses.swift` | Réponses aux mails |
| `Sources/PagesWeb.swift` | Outlook web, Teams web, pages en arrière-plan |
| `Sources/EmploiDuTemps.swift` | Cours (plateforme Pepal) |
| `Sources/Mer.swift` | Conditions en mer |
| `Sources/Disposition.swift` | Place, taille et aimantation du widget |
| `Sources/Bureau.swift` | Fichiers du bureau poussés hors du widget |
| `Sources/Reglages.swift` | Lecture des réglages personnels |

## Licence

[MIT](LICENSE) © 2026 Fr0gzilla
