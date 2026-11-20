// Cours de l'école, lus sur une plateforme Pepal (adresse dans les réglages).
// La page d'emploi du temps contient toutes les séances de l'année en JSON, dans l'attribut
// `data-tui-calendar-event-lesson-schedules-value` : on le lit tel quel, sans dépendre de l'affichage.
import Foundation

struct Cours: Codable, Identifiable, Equatable {
    let id: String
    let debut: Date
    let fin: Date
    let matiere: String
    let salle: String?
    let prof: String?
    let distanciel: Bool
    let annule: Bool
}

enum EmploiDuTemps {
    static func decoder(_ json: String) -> [Cours] {
        guard let liste = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        return liste.compactMap { o in
            guard let id = o["uuid"] as? String,
                  let d = (o["startDate"] as? NSNumber)?.doubleValue,
                  let f = (o["endDate"] as? NSNumber)?.doubleValue else { return nil }
            let matiere = ((o["schoolSubject"] as? [String: Any])?["name"] as? String)
                ?? (o["lessonType"] as? String) ?? "Cours"
            let salle = (o["rooms"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.joined(separator: ", ")
            let prof = (o["teachers"] as? [[String: Any]])?.compactMap { t -> String? in
                guard let n = t["lastName"] as? String else { return nil }
                let p = (t["firstName"] as? String).map { $0 + " " } ?? ""
                return p + n.capitalized
            }.joined(separator: ", ")
            let statut = (o["lessonStatus"] as? String ?? "Actif").lowercased()
            let annule = !(statut.hasPrefix("actif")) || !((o["cancelDesc"] as? String) ?? "").isEmpty
            return Cours(id: id, debut: Date(timeIntervalSince1970: d / 1000), fin: Date(timeIntervalSince1970: f / 1000),
                         matiere: matiere, salle: (salle?.isEmpty ?? true) ? nil : salle,
                         prof: (prof?.isEmpty ?? true) ? nil : prof,
                         distanciel: o["remote"] as? Bool ?? false, annule: annule)
        }
        .sorted { $0.debut < $1.debut }
    }

    // Copie locale : les cours s'affichent dès le démarrage, avant que la page ait fini de charger.
    private static var fichier: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rainette", isDirectory: true).appendingPathComponent("cours.json")
    }

    static func cache() -> [Cours] {
        guard let d = try? Data(contentsOf: fichier) else { return [] }
        return (try? JSONDecoder().decode([Cours].self, from: d)) ?? []
    }

    static func memoriser(_ c: [Cours]) {
        try? FileManager.default.createDirectory(at: fichier.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(c).write(to: fichier)
    }

    static func du(_ cours: [Cours], debut: Date, fin: Date) -> [Cours] {
        cours.filter { $0.fin > debut && $0.debut < fin }
    }
}

extension PageWeb {
    /// Lit les séances de l'emploi du temps (nil si la page n'est pas lisible, ex. déconnecté).
    func lireCours() async -> [Cours]? {
        let code = """
        document.querySelector('[data-tui-calendar-event-lesson-schedules-value]')
          ?.getAttribute('data-tui-calendar-event-lesson-schedules-value') || null
        """
        guard let json = await js(code) as? String else { return nil }
        let c = EmploiDuTemps.decoder(json)
        return c.isEmpty && json.count > 10 ? nil : c
    }
}
