// Lecture des mails dans l'app Mail (AppleScript) et tri / résumé par l'IA locale.
import AppKit
import Foundation

struct Mail: Identifiable {
    let id: Int              // numéro local, transmis au modèle
    let compte: String       // adresse du compte
    let idMessage: String    // Message-ID, pour rouvrir le mail dans Mail
    let expediteur: String
    let sujet: String
    let ilYa: Int            // secondes depuis la réception
    let corps: String

    var nom: String {
        // « Jean Dupont <jean@x.fr> » → « Jean Dupont »
        if let i = expediteur.firstIndex(of: "<") {
            let n = expediteur[..<i].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            if !n.isEmpty { return n }
        }
        return expediteur.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
    }

    var estTeams: Bool { idMessage.hasPrefix("teams:") || expediteur.lowercased().contains("teams") }

    var estEcole: Bool { idMessage.hasPrefix("outlook:") || idMessage.hasPrefix("teams:") }

    /// Pour les mails de l'école (lus dans Outlook web), c'est Rainette qui sait les rouvrir.
    @MainActor static var ouvrirEcole: ((Mail) -> Void)?

    @MainActor func ouvrir() {
        if estEcole { Mail.ouvrirEcole?(self); return }
        let id = idMessage.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let enc = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "@.-_"))) ?? id
        if let u = URL(string: "message://%3C\(enc)%3E") { NSWorkspace.shared.open(u) }
    }
}

struct ResumeMail: Identifiable {
    let id: Int
    let mail: Mail
    let resume: String
    let prioritaire: Bool
}

enum LecteurMail {
    /// Seuls ces comptes de l'app Mail sont lus (adresse ou identifiant du compte) ; aucun = tous.
    static var comptesSuivis: [String] { Reglages.actuels.comptesMail }

    /// Mails non lus de la boîte de réception, reçus depuis `heures` heures (40 au plus par compte).
    static let script = """
    on run argv
        set heures to (item 1 of argv) as integer
        set suivis to rest of argv
        set limite to (current date) - (heures * hours)
        set FS to ASCII character 31
        set RS to ASCII character 30
        set sortie to ""
        tell application "Mail"
            repeat with c in every account
                set adresse to ""
                if (count of suivis) is 0 then
                    try
                        set adresse to (item 1 of (email addresses of c)) as text
                    end try
                end if
                try
                    if suivis contains (user name of c) then set adresse to user name of c
                end try
                if adresse is "" then
                    try
                        repeat with a in (email addresses of c)
                            if suivis contains (a as text) then set adresse to a as text
                        end repeat
                    end try
                end if
                if enabled of c and adresse is not "" then
                    try
                        set boite to mailbox "INBOX" of c
                        set msgs to (messages of boite whose date received > limite and read status is false)
                        set k to 0
                        repeat with m in msgs
                            set k to k + 1
                            if k > 40 then exit repeat
                            set corps to ""
                            try
                                set corps to content of m
                                if (length of corps) > 700 then set corps to text 1 thru 700 of corps
                            end try
                            set age to ((current date) - (date received of m)) as integer
                            set sortie to sortie & adresse & FS & (message id of m) & FS & (sender of m) & FS & (subject of m) & FS & age & FS & corps & RS
                        end repeat
                    end try
                end if
            end repeat
        end tell
        return sortie
    end run
    """

    enum Erreur: Error { case refus(String) }

    static func lire(heures: Int = 72) async throws -> [Mail] {
        let brut: String = try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-", String(heures)] + comptesSuivis
            let entree = Pipe(), sortie = Pipe(), err = Pipe()
            p.standardInput = entree
            p.standardOutput = sortie
            p.standardError = err
            try p.run()
            entree.fileHandleForWriting.write(script.data(using: .utf8)!)
            try entree.fileHandleForWriting.close()
            let d = sortie.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                throw Erreur.refus(String(data: e, encoding: .utf8) ?? "erreur inconnue")
            }
            return String(data: d, encoding: .utf8) ?? ""
        }.value

        let RS = Character(UnicodeScalar(30)), FS = Character(UnicodeScalar(31))
        var res: [Mail] = []
        for (i, rec) in brut.split(separator: RS).enumerated() {
            let f = rec.split(separator: FS, omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 6 else { continue }
            res.append(Mail(id: i + 1, compte: f[0].trimmingCharacters(in: .whitespacesAndNewlines),
                            idMessage: f[1], expediteur: f[2], sujet: f[3],
                            ilYa: Int(f[4]) ?? 0, corps: f[5]))
        }
        return res.sorted { $0.ilYa < $1.ilYa }
    }
}

/// Verdict de l'IA sur un mail, gardé d'un tri à l'autre (clé : identifiant du message).
struct Verdict: Codable {
    let important: Bool
    let resume: String
    let prioritaire: Bool
    let tache: String?
}

enum Resumeur {
    static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "mails": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "categorie": ["type": "string", "enum": ["a_faire", "a_savoir", "inutile"]],
                        "resume": ["type": "string"],
                        "prioritaire": ["type": "boolean"],
                        "tache": ["type": "string"],
                    ],
                    "required": ["id", "categorie"],
                ],
            ],
        ],
        "required": ["mails"],
    ]

    /// Phrases par lesquelles l'IA avoue elle-même qu'un mail ne sert à rien.
    static let motifInutile = #"(rien (à|a) faire|rien d'urgent|pas d'action|rien d'actionnable|pas (compatible|pour toi|prioritaire|important)|ne te correspond pas|correspond pas à ton|aucune action|pour info(rmation)?\b|juste (une )?info|si tu cherches|si ça te tente|si ça t'intéresse|si tu l'utilises)"#

    /// Le modèle glisse parfois les numéros internes des mails (« (mail id 13) », « dans le mail id 20 ») : on les retire.
    static func sansId(_ t: String) -> String {
        t.replacingOccurrences(of: #"\s*\((?:dans le |du |cf\.? )?(?:mail\s*)?(?:ids?|n°)\s*:?\s*\d[^)]*\)"#,
                               with: "", options: [.regularExpression, .caseInsensitive])
         .replacingOccurrences(of: #"\s*(?:dans|du|de) (?:le )?mail (?:ids?|n°)\s*:?\s*\d+"#,
                               with: "", options: [.regularExpression, .caseInsensitive])
         .replacingOccurrences(of: #"\s+([.,;!?])"#, with: "$1", options: .regularExpression)
    }

    static var consigne: String { """
    Tu tries les nouveaux mails de \(Reglages.actuels.profil). Il ne veut voir que ce qui compte VRAIMENT : \
    sois strict, dans le doute c'est « inutile ».
    Pour CHAQUE mail, choisis une catégorie :
    - "a_faire" : il doit agir lui-même (répondre, confirmer, envoyer un document, payer, se présenter, \
    sécuriser SON compte après une connexion qu'il n'a peut-être pas faite). Typiquement : une vraie personne \
    qui lui écrit à lui (recruteur, entreprise, école, prof, administration), une échéance, un rendez-vous à confirmer.
    - "a_savoir" : rien à faire, mais utile de le savoir maintenant (cours annulé, colis qui arrive aujourd'hui ou \
    demain, rendez-vous ou voyage dans les 2 jours, réponse attendue à une candidature).
    - "inutile" : tout le reste. En particulier : alertes d'emploi et offres envoyées automatiquement \
    (LinkedIn Jobs, Hellowork, Indeed, Welcome to the Jungle…), même si l'offre lui correspond ; newsletters, \
    pubs, promos, conseils ; notifications de réseaux sociaux (« X a vu ton profil », « 1 message en attente » sans \
    nom ni contenu) ; rappels d'information de la banque ou d'un service sans action ; bulletins de sécurité \
    généraux sur un logiciel ; confirmations de quelque chose de déjà fait ou passé ; mails « rien à faire ».
    Pour "a_faire" et "a_savoir" seulement : resume = 15 mots maximum, en français, comme on parle à un pote \
    (familier, tutoiement, ex. « Ils t'invitent à un entretien mardi 10h, faut confirmer »), sans répéter \
    l'expéditeur. Pour "a_faire" : tache = l'action à faire, à l'impératif et en tutoyant \
    (ex. « Confirme l'entretien avec Studio Nova avant lundi »). prioritaire = true seulement pour un recrutement \
    qui le concerne personnellement, l'école avec une échéance, ou une alerte sur l'un de SES comptes.
    N'utilise que les id fournis, et n'écris jamais d'id dans les textes. N'invente rien.
    Réponds UNIQUEMENT avec ce JSON, sans texte autour :
    {"mails": [{"id": 3, "categorie": "inutile"}, {"id": 4, "categorie": "a_faire", "resume": "…", "prioritaire": true, "tache": "…"}]}
    """ }

    /// Trie un paquet de NOUVEAUX mails ; renvoie un verdict pour chacun (absent de la réponse = pas important).
    static func trier(_ mails: [Mail]) async throws -> [String: Verdict] {
        if mails.isEmpty { return [:] }
        let texte = mails.map { m in
            let corps = m.corps.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
            return "id \(m.id) · compte \(m.compte) · de \(m.expediteur) · sujet « \(m.sujet) »\n\(corps.prefix(300))"
        }.joined(separator: "\n---\n")
        // Une réponse illisible : on réessaie une fois avant d'abandonner le paquet.
        let rep: [String: Any]
        do { rep = try await Ollama.json(consigne: consigne, texte: texte, schema: schema) }
        catch Ollama.Erreur.illisible { rep = try await Ollama.json(consigne: consigne, texte: texte, schema: schema) }
        var res: [String: Verdict] = [:]
        for m in mails { res[m.idMessage] = Verdict(important: false, resume: "", prioritaire: false, tache: nil) }
        let parId = Dictionary(mails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for o in rep["mails"] as? [[String: Any]] ?? [] {
            guard let id = (o["id"] as? Int) ?? Int(o["id"] as? String ?? ""), let m = parId[id] else { continue }
            let categorie = (o["categorie"] as? String ?? "inutile").lowercased()
            let resume = sansId(o["resume"] as? String ?? "")
            // Filet de sécurité : un résumé qui dit lui-même que ça ne sert à rien = inutile, quoi qu'ait décidé l'IA.
            let inutile = categorie.hasPrefix("inutile") || resume.isEmpty
                || resume.range(of: Resumeur.motifInutile, options: [.regularExpression, .caseInsensitive]) != nil
            if inutile { continue }
            let aFaire = categorie.hasPrefix("a_faire") || categorie.hasPrefix("à_faire")
            let t = sansId((o["tache"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            res[m.idMessage] = Verdict(important: true, resume: resume,
                                       prioritaire: o["prioritaire"] as? Bool ?? false,
                                       tache: aFaire && !t.isEmpty ? t : nil)
        }
        return res
    }

    /// Ce qu'on affiche, à partir des verdicts : importants (prioritaires d'abord, puis du plus récent)
    /// sans doublons, et 3 tâches au plus.
    static func affichage(_ mails: [Mail], _ verdicts: [String: Verdict],
                          traites: Set<String> = []) -> ([ResumeMail], [String]) {
        var vus = Set<String>()
        var imp: [ResumeMail] = []
        for m in mails {
            // Mail dont il a coché la tâche : traité, on ne l'affiche plus.
            guard let v = verdicts[m.idMessage], v.important, !traites.contains(m.idMessage) else { continue }
            // Plusieurs mails qui disent la même chose (ex. « 1 message en attente » LinkedIn) : un seul.
            let cle = m.nom.lowercased() + "|" + m.sujet.lowercased()
            if vus.contains(cle) { continue }
            vus.insert(cle)
            imp.append(ResumeMail(id: m.id, mail: m, resume: v.resume, prioritaire: v.prioritaire))
        }
        // Messages Teams d'une personne d'abord, puis les prioritaires, puis du plus récent au plus ancien.
        func rang(_ r: ResumeMail) -> Int { r.mail.idMessage.hasPrefix("teams:") ? 0 : (r.prioritaire ? 1 : 2) }
        imp.sort { (rang($0), $0.mail.ilYa) < (rang($1), $1.mail.ilYa) }
        var taches: [String] = []
        for r in imp {
            if let t = verdicts[r.mail.idMessage]?.tache, !taches.contains(t) { taches.append(t) }
        }
        return (imp, Array(taches.prefix(3)))
    }

    // Mémoire des verdicts (~/Library/Application Support/Rainette/tri.json).
    private static var fichier: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rainette", isDirectory: true).appendingPathComponent("tri-v2.json")
    }
    static func charger() -> [String: Verdict] {
        guard let d = try? Data(contentsOf: fichier) else { return [:] }
        return (try? JSONDecoder().decode([String: Verdict].self, from: d)) ?? [:]
    }
    static func memoriser(_ v: [String: Verdict]) {
        try? FileManager.default.createDirectory(at: fichier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(v).write(to: fichier)
    }
}
