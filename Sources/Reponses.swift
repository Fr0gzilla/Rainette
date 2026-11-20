// Réponse aux mails : l'utilisateur dit en vrac ce qu'il veut répondre, Rainette demande le ton
// (formel ou tranquille), reformule et corrige, puis il relit, modifie s'il veut, et envoie.
import SwiftUI

enum Ton: String { case formel, tranquille }

struct ReponseMail {
    let mail: Mail
    let brouillon: String          // ce que l'utilisateur a dit, tel quel
    var ton: Ton?
    var texte = ""                 // la version reformulée (modifiable avant l'envoi)
    var redige = false             // le modèle est en train d'écrire
    var envoi = false              // envoi en cours
}

enum Repondeur {
    static var consigne: String {
        let r = Reglages.actuels
        let complet = r.nomComplet.isEmpty ? r.prenom : r.nomComplet
        let signeFormel = complet.isEmpty ? "" : " puis « \(complet) » à la ligne"
        let signeTranquille = r.prenom.isEmpty ? "" : " puis « \(r.prenom) » à la ligne"
        return """
    Tu rédiges la réponse de \(complet.isEmpty ? "l'utilisateur" : complet) à un mail qu'il a reçu.
    Il te donne en vrac ce qu'il veut répondre, parfois avec des fautes. Reformule-le proprement \
    et corrige l'orthographe et la grammaire.
    Garde toutes ses idées, remerciements compris, et n'ajoute aucune promesse, excuse ou information \
    qu'il n'a pas donnée (tu peux reprendre une date ou un lieu cités dans le mail reçu).
    Réponds dans la langue du mail reçu.
    TON FORMEL : vouvoiement ; commence par « Bonjour Madame, » / « Bonjour Monsieur, » / « Bonjour Prénom Nom, » \
    selon ce que tu sais de l'expéditeur (sinon « Bonjour, ») ; phrases soignées ; termine par « Cordialement, »\
    \(signeFormel).
    TON TRANQUILLE : simple, direct et chaleureux, phrases courtes ; commence par « Bonjour Prénom, » si l'expéditeur \
    est un pro (entreprise, recruteur, école, administration) et « Salut Prénom, » seulement si c'est un proche ; \
    termine par « Bonne journée, » (pro) ou « À plus, » (proche)\(signeTranquille).
    Écris UNIQUEMENT le texte du mail : pas d'objet, pas de guillemets, pas de commentaire avant ou après.
    """
    }

    static func reformuler(_ r: ReponseMail, ton: Ton) async throws -> String {
        let texte = """
        Mail reçu de \(r.mail.expediteur), objet « \(r.mail.sujet) » :
        \(r.mail.corps.prefix(1500))

        Ce que \(Reglages.actuels.appel) veut répondre :
        \(r.brouillon)

        Ton : \(ton == .formel ? "FORMEL" : "TRANQUILLE")
        """
        let rep = try await Ollama.chat([["role": "system", "content": consigne], ["role": "user", "content": texte]],
                                        outils: [])
        var t = (rep["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"“”"))
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Répond au mail dans l'app Mail : envoie directement, ou ouvre la fenêtre de réponse pour finir à la main.
    static let script = """
    on run argv
        set mid to item 1 of argv
        set corps to item 2 of argv
        set ouvrir to (item 3 of argv) is "1"
        set essai to (item 3 of argv) is "essai"
        tell application "Mail"
            set cible to missing value
            repeat with c in every account
                try
                    set l to (messages of mailbox "INBOX" of c whose message id is mid)
                    if (count of l) > 0 then
                        set cible to item 1 of l
                        exit repeat
                    end if
                end try
            end repeat
            if cible is missing value then error "mail introuvable"
            -- Le mail d'origine, cité sous la réponse (« Le …, X a écrit : » puis chaque ligne précédée de « > »).
            set origine to ""
            try
                set origine to content of cible
            end try
            -- Sans les images (caractère « ￼ ») ni les lignes vides en série.
            set AppleScript's text item delimiters to (character id 65532)
            set morceaux to text items of origine
            set AppleScript's text item delimiters to ""
            set origine to morceaux as text
            set cite to ""
            set videAvant to true
            repeat with ligne in paragraphs of origine
                set l to ligne as text
                set vide to (l is "") or (l is " ") or (l is "  ")
                if not (vide and videAvant) then set cite to cite & "> " & l & return
                set videAvant to vide
            end repeat
            set entete to "Le " & (date received of cible as text) & ", " & (sender of cible) & " a écrit :"
            set texte to corps & return & return & entete & return & cite
            if ouvrir then
                set r to reply cible with opening window
                set content of r to texte
                activate
            else if essai then
                -- Essai à blanc : on prépare la réponse, on renvoie ce qui serait envoyé, et on la jette.
                set r to reply cible without opening window
                set content of r to texte
                set resultat to (subject of r) & linefeed & (address of item 1 of to recipients of r) & linefeed & (content of r)
                close r saving no
                return resultat
            else
                set r to reply cible without opening window
                set content of r to texte
                send r
                set read status of cible to true
            end if
        end tell
    end run
    """

    static func repondre(_ mail: Mail, texte: String, ouvrir: Bool) async throws {
        let id = mail.idMessage
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script, id, texte, ouvrir ? "1" : "0"]
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw LecteurMail.Erreur.refus(e)
            }
        }.value
    }
}

/// La carte de réponse, dans la discussion.
struct CarteReponse: View {
    @ObservedObject var e: Etat

    var body: some View {
        if let r = e.reponse {
            VStack(alignment: .leading, spacing: 8) {
                Label("Réponse à \(r.mail.nom)", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11.5, weight: .bold)).foregroundStyle(or)
                Text("Re: \(r.mail.sujet)").font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                if r.ton == nil {
                    HStack(spacing: 8) {
                        Button { e.choisirTon(.formel) } label: { Text("Formelle").frame(minWidth: 80) }
                            .buttonStyle(.borderedProminent).tint(or)
                        Button { e.choisirTon(.tranquille) } label: { Text("Tranquille").frame(minWidth: 80) }
                            .buttonStyle(.borderedProminent).tint(or)
                        Button("Laisse tomber") { e.annulerReponse() }.buttonStyle(.bordered)
                    }
                } else if r.redige {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Je te rédige ça…").foregroundStyle(.secondary)
                    }
                } else {
                    TextEditor(text: Binding(get: { e.reponse?.texte ?? "" }, set: { e.reponse?.texte = $0 }))
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: hauteurTexte(r.texte))
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
                    // Sur une ligne si ça tient, sinon sur deux : jamais de bouton coupé.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { boutonsPrincipaux(r); boutonsSecondaires(r) }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) { boutonsPrincipaux(r) }
                            HStack(spacing: 8) { boutonsSecondaires(r) }
                        }
                    }
                    Text("Tu peux retoucher le texte avant d'envoyer.").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(or.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(or.opacity(0.3), lineWidth: 1))
        }
    }

    @ViewBuilder
    private func boutonsPrincipaux(_ r: ReponseMail) -> some View {
        Button { e.envoyerReponse(ouvrir: false) } label: { Text("Envoie").frame(minWidth: 64) }
            .buttonStyle(.borderedProminent).tint(or).disabled(r.envoi).fixedSize()
        Button("Ouvre dans Mail") { e.envoyerReponse(ouvrir: true) }
            .buttonStyle(.bordered).disabled(r.envoi).fixedSize()
    }

    @ViewBuilder
    private func boutonsSecondaires(_ r: ReponseMail) -> some View {
        Button(r.ton == .formel ? "Plus tranquille" : "Plus formel") {
            e.choisirTon(r.ton == .formel ? .tranquille : .formel)
        }
        .buttonStyle(.bordered).disabled(r.envoi).fixedSize()
        Button("Laisse tomber") { e.annulerReponse() }.buttonStyle(.bordered).disabled(r.envoi).fixedSize()
    }

    /// Hauteur de la zone de texte : assez pour tout voir (signature comprise), entre 90 et 220 pt.
    private func hauteurTexte(_ t: String) -> CGFloat {
        let lignes = t.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((Double($1.count) / 50).rounded(.up))) }
        return min(max(CGFloat(lignes) * 17 + 18, 90), 220)
    }
}
