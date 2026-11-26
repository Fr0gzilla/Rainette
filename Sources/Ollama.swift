// Outils sans interface, testables seuls (voir Tests/) : formats de date, client Ollama et réparation du JSON.
import Foundation

enum Fmt {
    static func f(_ motif: String) -> DateFormatter {
        let d = DateFormatter()
        d.locale = Locale(identifier: "fr_FR")
        d.calendar = Calendar(identifier: .gregorian)
        d.dateFormat = motif
        return d
    }
    static let heure = f("HH:mm")
    static let jourLong = f("EEEE d MMMM yyyy")
    static let jourCourt = f("EEE d MMM")
    static let iso = f("yyyy-MM-dd'T'HH:mm")
    static let isoJour = f("yyyy-MM-dd")

    /// Lit une date venue du modèle. Renvoie (date, journée entière ?).
    static func lire(_ s: String) -> (Date, Bool)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for motif in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            if let d = f(motif).date(from: t) { return (d, false) }
        }
        if let d = isoJour.date(from: t) { return (d, true) }
        return nil
    }
}

// MARK: - Ollama

enum Ollama {
    static let url = URL(string: "http://127.0.0.1:11434/api/chat")!
    static let modele = "qwen3.5:9b"

    /// À l'ouverture de session, Ollama peut démarrer après Rainette : on l'attend (90 s au plus).
    static func attendrePret() async {
        let tags = URL(string: "http://127.0.0.1:11434/api/tags")!
        for _ in 0..<45 {
            var req = URLRequest(url: tags)
            req.timeoutInterval = 2
            if let (_, r) = try? await URLSession.shared.data(for: req),
               (r as? HTTPURLResponse)?.statusCode == 200 { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    static func chat(_ messages: [[String: Any]], outils: [[String: Any]]) async throws -> [String: Any] {
        let corps: [String: Any] = [
            "model": modele, "messages": messages, "tools": outils,
            "stream": false, "think": false, "options": ["temperature": 0.2],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: corps)
        let (data, rep) = try await URLSession.shared.data(for: req)
        let json = try Ollama.verifier(data, rep)
        return json["message"] as? [String: Any] ?? [:]
    }

    enum Erreur: Error { case http(String), illisible }

    /// Refuse une réponse en erreur (modèle absent, mémoire insuffisante…) au lieu de la prendre pour une réponse vide.
    static func verifier(_ data: Data, _ rep: URLResponse) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (rep as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 || json["error"] != nil {
            throw Erreur.http("\(code) \(json["error"] as? String ?? "")")
        }
        return json
    }

    /// Réponse structurée (JSON imposé par un schéma).
    static func json(consigne: String, texte: String, schema: [String: Any]) async throws -> [String: Any] {
        let corps: [String: Any] = [
            "model": modele, "stream": false, "think": false,
            "options": ["temperature": 0.1, "num_ctx": 8192],
            "messages": [["role": "system", "content": consigne], ["role": "user", "content": texte]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: corps)
        let (data, rep) = try await URLSession.shared.data(for: req)
        let json = try Ollama.verifier(data, rep)
        let contenu = (json["message"] as? [String: Any])?["content"] as? String ?? ""
        // Le modèle n'a pas de sortie contrainte : on garde le bloc { … } de sa réponse, réparé s'il est incomplet.
        // Pas de JSON lisible = erreur (sinon tout le paquet serait classé « pas important » pour toujours).
        guard let objet = Ollama.objetJSON(contenu) else { throw Erreur.illisible }
        return objet
    }

    /// Extrait l'objet JSON d'une réponse. Le modèle oublie parfois de refermer la fin (« …}] » au lieu de « …}]} ») :
    /// on referme ce qui est resté ouvert (en ignorant ce qui est entre guillemets).
    static func objetJSON(_ texte: String) -> [String: Any]? {
        guard let d = texte.firstIndex(of: "{") else { return nil }
        var t = String(texte[d...])
        if let f = t.lastIndex(of: "}"), let o = (try? JSONSerialization.jsonObject(with: Data(t[...f].utf8))) as? [String: Any] {
            return o
        }
        var pile: [Character] = []
        var dansChaine = false, echappe = false
        for c in t {
            if dansChaine {
                if echappe { echappe = false } else if c == "\\" { echappe = true } else if c == "\"" { dansChaine = false }
                continue
            }
            switch c {
            case "\"": dansChaine = true
            case "{": pile.append("}")
            case "[": pile.append("]")
            case "}", "]": if !pile.isEmpty { pile.removeLast() }
            default: break
            }
        }
        if dansChaine { t += "\"" }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(",") { t.removeLast() }
        t += String(pile.reversed())
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any]
    }

    static let outils: [[String: Any]] = [
        [
            "type": "function",
            "function": [
                "name": "ajouter_evenement",
                "description": "Propose d'ajouter un évènement au calendrier Apple. L'utilisateur confirmera.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "titre": ["type": "string", "description": "Titre court"],
                        "debut": ["type": "string", "description": "AAAA-MM-JJTHH:MM si une heure est donnée, sinon AAAA-MM-JJ (journée entière). Jamais d'heure inventée."],
                        "fin": ["type": "string", "description": "AAAA-MM-JJTHH:MM (facultatif, 1 h par défaut)"],
                        "lieu": ["type": "string", "description": "Lieu (facultatif)"],
                    ],
                    "required": ["titre", "debut"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "lire_agenda",
                "description": "Liste les évènements du calendrier entre deux dates incluses.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "du": ["type": "string", "description": "AAAA-MM-JJ"],
                        "au": ["type": "string", "description": "AAAA-MM-JJ"],
                    ],
                    "required": ["du", "au"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "repondre_mail",
                "description": "Prépare une réponse à un des mails non lus. Rainette demandera le ton puis reformulera ; l'utilisateur relira avant l'envoi.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer", "description": "Numéro du mail dans la liste des mails non lus"],
                        "message": ["type": "string", "description": "Ce que l'utilisateur veut répondre, recopié tel quel"],
                    ],
                    "required": ["id", "message"],
                ],
            ],
        ],
        [
            "type": "function",
            "function": [
                "name": "lire_mails",
                "description": "Liste les mails non lus des trois derniers jours (expéditeur, sujet, début du texte).",
                "parameters": ["type": "object", "properties": [String: Any]()],
            ],
        ],
    ]
}

// MARK: - Calendrier

// MARK: - Dates d'évènements

enum Dates {
    static let jours = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]

    /// Corrige la date proposée par le modèle :
    /// - une date déjà passée part à l'année suivante (« le 17 septembre » dit en novembre) ;
    /// - si le message cite UN jour de la semaine (et pas « aujourd'hui » / « demain ») et que la date ne tombe pas
    ///   ce jour-là, on prend le prochain jour de ce nom, en gardant l'heure (le modèle confond souvent les jours).
    static func recaler(_ date: Date, journee: Bool, message: String, corrigerJour: Bool = true,
                        maintenant: Date = Date(), cal: Calendar = .current) -> Date {
        var debut = date
        while debut < cal.startOfDay(for: maintenant), let d = cal.date(byAdding: .year, value: 1, to: debut) { debut = d }
        let m = message.lowercased()
        let cites = jours.filter { m.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        guard corrigerJour, cites.count == 1, !m.contains("aujourd"), !m.contains("demain"),
              let voulu = jours.firstIndex(of: cites[0]), cal.component(.weekday, from: debut) != voulu + 1
        else { return debut }
        let h = cal.dateComponents([.hour, .minute], from: debut)
        var d = cal.startOfDay(for: maintenant)
        while cal.component(.weekday, from: d) != voulu + 1 { d = cal.date(byAdding: .day, value: 1, to: d)! }
        guard let avecHeure = cal.date(bySettingHour: h.hour ?? 0, minute: h.minute ?? 0, second: 0, of: d) else { return debut }
        // Aujourd'hui mais heure déjà passée, ou « mardi prochain » dit un mardi : la semaine d'après.
        let passe = !journee && avecHeure < maintenant
        let prochain = m.contains("\(jours[voulu]) prochain") && cal.isDate(d, inSameDayAs: maintenant)
        return (passe || prochain) ? cal.date(byAdding: .day, value: 7, to: avecHeure)! : avecHeure
    }
}
