// Mode démo (`Rainette.app/Contents/MacOS/Rainette --demo`) : des données inventées, pour les captures d'écran.
// Rien de réel n'est lu (ni Mail, ni Outlook, ni Teams, ni emploi du temps), et rien n'est enregistré.
import EventKit
import Foundation

enum Demo {
    static var active: Bool {
        CommandLine.arguments.contains("--demo") || ProcessInfo.processInfo.environment["RAINETTE_DEMO"] == "1"
    }
}

extension Etat {
    func remplirDemo() {
        let cal = Calendar.current
        let j0 = cal.startOfDay(for: Date())
        func a(_ jour: Int, _ h: Int, _ m: Int = 0) -> Date {
            cal.date(byAdding: .minute, value: jour * 1440 + h * 60 + m, to: j0)!
        }

        majA = a(0, 8, 45)

        // Mails
        func mail(_ id: Int, _ de: String, _ sujet: String, _ ilYa: Int, teams: Bool = false) -> Mail {
            Mail(id: id, compte: "demo", idMessage: (teams ? "teams:" : "demo:") + "\(id)",
                 expediteur: de, sujet: sujet, ilYa: ilYa, corps: "")
        }
        let importantsDemo = [
            (mail(1, "Studio Nova", "Entretien alternance", 2 * 3600),
             "Ils te proposent un entretien d'alternance mardi à 10h, faut confirmer.", true),
            (mail(2, "Scolarité", "Projet final", 5 * 3600),
             "Le rendu du projet final est avancé à vendredi 18h.", true),
            (mail(3, "Alex Durand", "Message Teams", 50 * 60, teams: true),
             "Il demande si t'as fini ta partie du TP pour demain.", false),
        ]
        let pubs = (4...14).map { mail($0, "Newsletter", "Promo", 20 * 3600) }
        mails = importantsDemo.map(\.0) + pubs
        importants = importantsDemo.map { ResumeMail(id: $0.0.id, mail: $0.0, resume: $0.1, prioritaire: $0.2) }
        aFaire = ["Confirme l'entretien avec Studio Nova", "Termine ta partie du TP avant demain",
                  "Rends le projet final avant vendredi 18h"]
        faits = ["Rends le projet final avant vendredi 18h"]
        teamsNonLus = 3
        etatMails = .ok

        // Agenda (évènements non enregistrés) et cours
        let store = EKEventStore()
        func ev(_ titre: String, _ debut: Date, _ fin: Date, _ lieu: String? = nil) -> EKEvent {
            let e = EKEvent(eventStore: store)
            e.title = titre; e.startDate = debut; e.endDate = fin; e.location = lieu
            return e
        }
        aujourdhui = [ev("Entraînement", a(0, 18, 30), a(0, 20))]
        demain = [ev("Dentiste", a(1, 17), a(1, 17, 30))]
        cours = [
            Cours(id: "d1", debut: a(0, 13, 30), fin: a(0, 17), matiere: "Développement web",
                  salle: "Salle 4", prof: "Julie Leroy", distanciel: false, annule: false),
            Cours(id: "d2", debut: a(1, 9), fin: a(1, 12, 30), matiere: "Bases de données",
                  salle: "Salle 2", prof: "Marc Simon", distanciel: false, annule: false),
            Cours(id: "d3", debut: a(1, 13, 30), fin: a(1, 15), matiere: "Anglais",
                  salle: nil, prof: nil, distanciel: true, annule: false),
        ]

        // Mer
        let h = Date().addingTimeInterval(-600)
        mer = Mer.Conditions(
            navigation: [Mer.Heure(date: h, vent: 16, rafales: 22, dirVent: 270, vague: 1.1, houle: 1.1,
                                   periode: 8, dirHoule: 280, eau: 13)],
            surf: [Mer.Heure(date: h, vent: 6, rafales: 9, dirVent: 80, vague: 1.2, houle: 1.2,
                             periode: 10, dirHoule: 275, eau: 13)])

        // Un petit échange dans la discussion
        // Un chevauchement pour la démo : le dentiste de demain pendant l'anglais à distance.
        demain = [ev("Dentiste", a(1, 14), a(1, 14, 45))]
        conflits = Chevauchements.trouver(
            demain.map { Chevauchements.Plage(cle: "e:" + ($0.eventIdentifier ?? ""), titre: $0.title ?? "", debut: $0.startDate,
                                              fin: $0.endDate, estCours: false) }
            + cours.map { Chevauchements.Plage(cle: "c:" + $0.id, titre: $0.matiere, debut: $0.debut, fin: $0.fin, estCours: true) })
        if CommandLine.arguments.contains("--demo-point") {
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); CompteRendu.afficher(self) }
        }
        if CommandLine.arguments.contains("--demo-discussion") {
            bulles = [
                Bulle(deMoi: true, texte: "réponds a studio nova que cest ok pour mardi 10h merci"),
                Bulle(deMoi: false, texte: "Ok, je réponds à Studio Nova. Tu la veux formelle ou tranquille ?"),
            ]
            var r = ReponseMail(mail: importantsDemo[0].0, brouillon: "cest ok pour mardi 10h merci")
            r.ton = .formel
            r.texte = "Bonjour,\n\nJe vous confirme ma présence pour l'entretien d'alternance de mardi à 10h. "
                + "Merci beaucoup pour votre proposition.\n\nCordialement,\nCamille Martin"
            reponse = r
        }
    }
}
