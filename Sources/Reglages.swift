// Réglages personnels de Rainette, lus dans ~/Library/Application Support/Rainette/reglages.json.
// Ce fichier reste sur le Mac : rien de personnel (nom, adresses, contacts, école, spots) n'est dans le code.
// Modèle : reglages.exemple.json à la racine du dépôt. Tout est facultatif : une partie sans réglage est masquée.
import Foundation

struct Reglages: Codable {
    struct Page: Codable {
        var nom: String                  // nom affiché, ex. « Cours »
        var adresse: String              // ex. https://ecole.exemple.fr/emploi-du-temps
    }
    struct Spot: Codable {
        var nom: String
        var vent: [Double]               // [latitude, longitude] pour le vent (à terre, près de la plage)
        var mer: [Double]                // [latitude, longitude] pour la houle (au large)
    }
    struct Mer: Codable {
        var navigation: Spot?            // ligne « ⛵ » (catamaran, voile)
        var surf: Spot?                  // ligne « 🏄 »
    }

    /// Prénom, utilisé par l'IA pour s'adresser à toi et signer les réponses « tranquilles ».
    var prenom = ""
    /// Prénom et nom, pour signer les réponses « formelles ».
    var nomComplet = ""
    /// Qui tu es, en une phrase : aide l'IA à juger ce qui est important dans tes mails.
    var profil = "une personne qui veut garder l'essentiel de ses mails"
    /// Comptes de l'app Mail à lire (adresse ou identifiant). Vide = tous les comptes actifs.
    var comptesMail: [String] = []
    /// Compte Microsoft 365 (école ou travail) pour Outlook web et Teams web. Absent = pas d'Outlook ni de Teams.
    var compteMicrosoft: String?
    var outlook = true
    var teams = true
    /// Les seules personnes dont Rainette lit les messages Teams.
    var contactsTeams: [String] = []
    /// Emploi du temps sur une plateforme Pepal (connexion Microsoft). Absent = pas de cours.
    var emploiDuTemps: Page?
    /// Spots pour les conditions en mer (Open-Meteo). Absent = pas de ligne mer.
    var mer: Mer?
    /// [latitude, longitude] du lieu où regarder s'il pleut (la grenouille sort son parapluie).
    /// Absent = le spot de navigation.
    var meteo: [Double]?

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let base = Reglages()
        prenom = try c.decodeIfPresent(String.self, forKey: .prenom) ?? base.prenom
        nomComplet = try c.decodeIfPresent(String.self, forKey: .nomComplet) ?? base.nomComplet
        profil = try c.decodeIfPresent(String.self, forKey: .profil) ?? base.profil
        comptesMail = try c.decodeIfPresent([String].self, forKey: .comptesMail) ?? base.comptesMail
        compteMicrosoft = try c.decodeIfPresent(String.self, forKey: .compteMicrosoft)
        outlook = try c.decodeIfPresent(Bool.self, forKey: .outlook) ?? base.outlook
        teams = try c.decodeIfPresent(Bool.self, forKey: .teams) ?? base.teams
        contactsTeams = try c.decodeIfPresent([String].self, forKey: .contactsTeams) ?? base.contactsTeams
        emploiDuTemps = try c.decodeIfPresent(Page.self, forKey: .emploiDuTemps)
        mer = try c.decodeIfPresent(Mer.self, forKey: .mer)
        meteo = try c.decodeIfPresent([Double].self, forKey: .meteo)
    }

    static var fichier: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rainette", isDirectory: true).appendingPathComponent("reglages.json")
    }

    /// Les réglages, lus une fois au lancement (relancer Rainette après une modification).
    static let actuels: Reglages = {
        guard let d = try? Data(contentsOf: fichier) else { return Reglages() }
        do { return try JSONDecoder().decode(Reglages.self, from: d) } catch {
            FileHandle.standardError.write("reglages.json illisible : \(error)\n".data(using: .utf8)!)
            return Reglages()
        }
    }()

    /// Le prénom s'il est connu, sinon « l'utilisateur » (pour les consignes de l'IA).
    var appel: String { prenom.isEmpty ? "l'utilisateur" : prenom }
}
