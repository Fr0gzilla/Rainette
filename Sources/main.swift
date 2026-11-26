// Rainette — widget de bureau : point du jour + barre pour parler à l'IA locale (Ollama).
import AppKit
import EventKit
import SwiftUI

let or = Color(red: 0.83, green: 0.66, blue: 0.24)


final class Agenda {
    let store = EKEventStore()

    func demanderAcces() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func evenements(du debut: Date, au fin: Date) -> [EKEvent] {
        let p = store.predicateForEvents(withStart: debut, end: fin, calendars: nil)
        return store.events(matching: p).sorted { $0.startDate < $1.startDate }
    }

    /// Ajoute l'évènement et renvoie le nom de l'agenda où il a été rangé.
    @discardableResult
    func ajouter(_ p: Proposition) throws -> String {
        let e = EKEvent(eventStore: store)
        e.title = p.titre
        e.startDate = p.debut
        e.endDate = p.fin
        e.isAllDay = p.journee
        e.location = p.lieu
        e.calendar = store.defaultCalendarForNewEvents
        try store.save(e, span: .thisEvent, commit: true)
        return e.calendar?.title ?? "?"
    }
}

// MARK: - État

struct Bulle: Identifiable {
    let id = UUID()
    let deMoi: Bool
    let texte: String
}

struct Proposition {
    let titre: String
    let debut: Date
    let fin: Date
    let journee: Bool
    let lieu: String?
    /// Ce qui tombe déjà sur ce créneau (cours, rdv), pour prévenir avant de valider.
    var conflit: String? = nil

    var resume: String {
        let jour = Fmt.jourCourt.string(from: debut)
        if journee { return "\(jour) · journée entière" }
        return "\(jour) · \(Fmt.heure.string(from: debut))–\(Fmt.heure.string(from: fin))"
    }
}

@MainActor
final class Etat: ObservableObject {
    @Published var aujourdhui: [EKEvent] = []
    @Published var demain: [EKEvent] = []
    /// Évènements du calendrier des 7 jours après demain (pour voir ce qu'il vient d'ajouter pour plus tard).
    @Published var aVenir: [EKEvent] = []
    @Published var majA = Date()
    @Published var acces = true
    @Published var bulles: [Bulle] = []
    @Published var reflechit = false
    @Published var proposition: Proposition?
    /// Les évènements suivants, quand il en a demandé plusieurs d'un coup.
    private var enAttente: [Proposition] = []
    private func suivante() {
        guard !enAttente.isEmpty else { return }
        proposition = enAttente.removeFirst()
        dire("Et celui-là, je te le mets ?")
    }

    // Mails
    enum EtatMails: Equatable { case attente, lecture, tri, ok, erreur(String) }
    @Published var mails: [Mail] = []
    @Published var importants: [ResumeMail] = []
    @Published var aFaire: [String] = []
    @Published var etatMails: EtatMails = .attente

    // À faire cochés (gardés d'un tri à l'autre, et après un redémarrage)
    @Published var faits: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "RainetteFaits") ?? [])
    func cocher(_ t: String) {
        if faits.contains(t) { faits.remove(t) } else { faits.insert(t) }
        // On ne garde que ce qui est encore dans la liste.
        faits.formIntersection(aFaire)
        if !Demo.active { UserDefaults.standard.set(Array(faits), forKey: "RainetteFaits") }
        guard faits.contains(t) else { return }
        // Coché = c'est fait : après un instant (le temps de voir la case barrée), le mail d'où vient la tâche
        // et la tâche disparaissent du widget. Retenu même après un redémarrage.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard faits.contains(t) else { return }          // décoché entre-temps
            let concernes = mails.filter { verdicts[$0.idMessage]?.tache == t }.map(\.idMessage)
            withAnimation(.easeOut(duration: 0.3)) {
                traites.formUnion(concernes)
                if Demo.active {
                    aFaire.removeAll { $0 == t }
                } else {
                    (importants, aFaire) = Resumeur.affichage(mails, verdicts, traites: traites)
                }
                faits.remove(t)
            }
            dernierRetrait = Retrait(tache: t, ids: concernes)
            Task {
                try? await Task.sleep(for: .seconds(8))
                if dernierRetrait?.tache == t { withAnimation { dernierRetrait = nil } }
            }
            if !Demo.active {
                // On ne garde en mémoire que les mails encore présents.
                traites.formIntersection(Set(mails.map(\.idMessage)).union(concernes))
                UserDefaults.standard.set(Array(traites), forKey: "RainetteTraites")
                UserDefaults.standard.set(Array(faits), forKey: "RainetteFaits")
                journal("à faire : « \(t) » coché, \(concernes.count) mail(s) retiré(s) du widget")
            }
        }
    }
    struct Retrait: Equatable { let tache: String; let ids: [String] }
    /// Dernière tâche cochée (et ses mails retirés), annulable quelques secondes.
    @Published var dernierRetrait: Retrait?

    func annulerRetrait() {
        guard let r = dernierRetrait else { return }
        withAnimation(.easeOut(duration: 0.25)) {
            traites.subtract(r.ids)
            if Demo.active { aFaire.insert(r.tache, at: 0) }
            else { (importants, aFaire) = Resumeur.affichage(mails, verdicts, traites: traites) }
            dernierRetrait = nil
        }
        if !Demo.active {
            UserDefaults.standard.set(Array(traites), forKey: "RainetteTraites")
            journal("à faire : « \(r.tache) » décoché (annulé), mail(s) remis")
        }
    }

    /// Mails triés « inutiles » (cachés), hors mails traités.
    func mailsCaches() -> [Mail] {
        mails.filter { m in
            guard let v = verdicts[m.idMessage] else { return false }
            return !v.important && !traites.contains(m.idMessage)
        }
    }

    /// Il remonte un mail caché : il devient « à savoir » (affiché), et le reste après les prochains tris.
    func remonter(_ m: Mail) {
        verdicts[m.idMessage] = Verdict(important: true, resume: "« \(m.sujet) »", prioritaire: false, tache: nil)
        (importants, aFaire) = Resumeur.affichage(mails, verdicts, traites: traites)
        if !Demo.active {
            Resumeur.memoriser(verdicts)
            journal("tri : « \(m.sujet) » (\(m.nom)) remonté à la main")
        }
    }

    /// Mails traités (tâche cochée) : plus affichés.
    @Published var traites: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "RainetteTraites") ?? [])

    // Réponse à un mail
    @Published var reponse: ReponseMail?

    func preparerReponse(_ m: Mail, brouillon: String) {
        proposition = nil
        if m.estEcole {
            m.ouvrir()
            dire(m.idMessage.hasPrefix("teams:")
                 ? "Pour Teams je peux pas écrire moi-même, je t'ouvre la conv 👉 réponds direct là-bas."
                 : "Pour l'école je peux pas envoyer moi-même, je t'ouvre le mail dans Outlook 👉 réponds direct là-bas.")
            return
        }
        reponse = ReponseMail(mail: m, brouillon: brouillon)
        dire("Ok, je réponds à \(m.nom). Tu la veux formelle ou tranquille ?")
    }

    func choisirTon(_ ton: Ton) {
        guard var r = reponse else { return }
        if Demo.active { reponse?.ton = ton; return }
        r.ton = ton
        r.redige = true
        reponse = r
        Task {
            do {
                let t = try await Repondeur.reformuler(r, ton: ton)
                guard reponse?.mail.idMessage == r.mail.idMessage else { return }
                reponse?.texte = t
                reponse?.redige = false
            } catch {
                reponse?.ton = nil
                reponse?.redige = false
                dire("L'IA répond pas… Ollama est bien lancé ?")
            }
        }
    }

    func envoyerReponse(ouvrir: Bool) {
        guard let r = reponse, !r.texte.isEmpty else { return }
        if Demo.active { reponse = nil; dire("(Démo : rien n'est envoyé 🐸)"); return }
        reponse?.envoi = true
        Task {
            do {
                try await Repondeur.repondre(r.mail, texte: r.texte, ouvrir: ouvrir)
                // Seulement si c'est toujours cette réponse-là qui est affichée (il a pu en commencer une autre).
                if reponse?.mail.idMessage == r.mail.idMessage { reponse = nil }
                if ouvrir {
                    dire("C'est ouvert dans Mail, t'as plus qu'à vérifier et envoyer.")
                } else {
                    dire("📨 C'est parti, \(r.mail.nom) a ta réponse.")
                    historique.append(["role": "assistant", "content": "Réponse envoyée à \(r.mail.nom)."])
                }
            } catch {
                if reponse?.mail.idMessage == r.mail.idMessage { reponse?.envoi = false }
                dire("J'ai pas réussi à passer par Mail 😕 Essaie « Ouvre dans Mail ».")
            }
        }
    }

    func annulerReponse() {
        reponse = nil
        dire("Ok, je laisse tomber.")
    }

    // Mode « Modifier » (déplacer / redimensionner le widget)
    @Published var edition = false
    func dispositionParDefaut() {
        Disposition.oublier()
        fenetreWidget?.placer()
    }

    // Mer (spots des réglages)
    @Published var mer: Mer.Conditions?
    /// Il pleut en ce moment (la grenouille sort son parapluie).
    @Published var ilPleut = false

    /// L'humeur de la grenouille : dort la nuit, parapluie s'il pleut, grand sourire s'il n'y a rien à faire.
    var humeur: Grenouille.Humeur {
        let h = Calendar.current.component(.hour, from: Date())
        if h >= 23 || h < 6 { return .dort }
        if ilPleut { return .pluie }
        if etatMails == .ok, aFaire.allSatisfy({ faits.contains($0) }) { return .contente }
        return .normale
    }
    @Published var merErreur = false
    private var cleMails = ""
    /// Verdicts de l'IA déjà connus (seuls les nouveaux mails sont triés).
    private var verdicts: [String: Verdict] = Resumeur.charger()
    /// Nombre de mails encore en cours de tri (affiché discrètement).
    @Published var triEnCours = 0
    /// Mails que l'IA n'a pas pu trier (panne) : retentés à la prochaine lecture, jamais comptés « pas importants ».
    @Published var nonTries = 0

    // Boîte école et Teams (pages web cachées)
    var ecole: PageWeb?
    var teams: PageWeb?
    var edt: PageWeb?
    /// Cours de l'école (emploi du temps Pepal), avec une copie locale pour l'affichage immédiat.
    @Published var cours: [Cours] = EmploiDuTemps.cache()

    func rafraichirCours() async {
        defer { majEtatsWeb() }
        guard let c = edt else { return }
        let lu = await c.session({ await c.lireCours() })
        // Page prête mais sans les séances, ou jamais prête alors qu'on est connecté : lecture cassée.
        signalerCasse(c.nom, c.lectureCassee || (lu != nil && lu! == nil))
        guard let l = lu, let lus = l else { return }
        if lus != cours { cours = lus; EmploiDuTemps.memoriser(lus); majConflits() }
        journal("Emploi du temps : \(lus.count) séances lues")
    }

    func coursDu(_ debut: Date, _ fin: Date) -> [Cours] {
        EmploiDuTemps.du(cours, debut: debut, fin: fin).filter { $0.fin > Date() }
    }
    @Published var etatEcole: PageWeb.Etat = .chargement
    @Published var etatTeams: PageWeb.Etat = .chargement
    @Published var etatEdt: PageWeb.Etat = .chargement
    /// Derniers mails de l'école et messages Teams lus (les pages sont refermées entre deux lectures).
    private var mailsOutlook: [Mail] = []
    private var mailsTeams: [Mail] = []

    func preparerPagesWeb() {
        let r = Reglages.actuels
        // Outlook et Teams : seulement si un compte Microsoft est réglé.
        if let compte = r.compteMicrosoft, !compte.isEmpty {
            if r.outlook {
                let e = PageWeb(nom: "Outlook", adresse: "https://outlook.office.com/mail/",
                                hotes: ["outlook.office.com", "outlook.office365.com", "outlook.cloud.microsoft"])
                e.pret = "!!document.querySelector('[data-folder-name]')"
                ecole = e
            }
            if r.teams {
                let t = PageWeb(nom: "Teams", adresse: "https://teams.microsoft.com/v2/",
                                hotes: ["teams.microsoft.com", "teams.cloud.microsoft"])
                t.discret = true
                t.pret = "[...document.querySelectorAll('button, [role=\"button\"], [role=\"tab\"]')].some(b => /^(Conversation|Chat)\\b/i.test((b.getAttribute('aria-label') || b.innerText || '').trim()))"
                teams = t
            }
        }
        // Emploi du temps : seulement si son adresse est réglée.
        if let p = r.emploiDuTemps, let u = URL(string: p.adresse), let hote = u.host {
            let c = PageWeb(nom: p.nom, adresse: p.adresse, hotes: [hote])
            c.pret = "!!document.querySelector('[data-tui-calendar-event-lesson-schedules-value]')"
            edt = c
        }
        for p in [ecole, teams, edt].compactMap({ $0 }) {
            p.compte = r.compteMicrosoft
            // Juste après une connexion : on relit tout (la page se referme à la fin de la lecture).
            p.quandConnecte = { [weak self] in
                self?.majEtatsWeb()
                Task {
                    await self?.rafraichirMails()
                    await self?.rafraichirCours()
                }
            }
        }
        Mail.ouvrirEcole = { [weak e = ecole, weak t = teams] m in
            if m.idMessage.hasPrefix("teams:") {
                let nom = m.idMessage.dropFirst("teams:".count).split(separator: "#").first.map(String.init) ?? ""
                t?.ouvrirConversationTeams(nom)
            } else {
                e?.ouvrirConversation(String(m.idMessage.dropFirst("outlook:".count)))
            }
        }
    }

    func majEtatsWeb() {
        etatEcole = ecole?.etat ?? .chargement
        etatTeams = teams?.etat ?? .chargement
        etatEdt = edt?.etat ?? .chargement
    }

    @Published var teamsNonLus = 0
    /// Toutes les conversations Teams non lues (groupes compris), affichées dans le point du jour.
    @Published var conversationsTeams: [PageWeb.ConversationTeams] = []
    /// Pages connectées mais illisibles (leur interface a sans doute changé).
    @Published var lecturesCassees: [String] = []
    func signalerCasse(_ nom: String, _ cassee: Bool) {
        let avant = lecturesCassees.contains(nom)
        if cassee && !avant {
            lecturesCassees.append(nom)
            journal("⚠️ \(nom) : connecté mais illisible, la page a sans doute changé")
        } else if !cassee && avant {
            lecturesCassees.removeAll { $0 == nom }
            journal("\(nom) : de nouveau lisible")
        }
    }
    /// Les seules personnes dont Rainette lit les messages Teams.
    var contactsTeams: [String] { Reglages.actuels.contactsTeams }

    /// Petit journal (~/Library/Application Support/Rainette/journal.txt), pour comprendre ce qu'elle a vu.
    func journal(_ t: String) {
        let dossier = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rainette", isDirectory: true)
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let f = dossier.appendingPathComponent("journal.txt")
        var ancien = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        if ancien.count > 20000 { ancien = String(ancien.suffix(10000)) }
        let heure = DateFormatter()
        heure.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ligne = "\(heure.string(from: Date())) \(t)\n"
        try? (ancien + ligne).write(to: f, atomically: true, encoding: .utf8)
    }

    /// Lit Outlook puis Teams, l'un après l'autre (une seule page ouverte à la fois).
    func lirePagesWeb() async {
        if let e = ecole {
            if let r = await e.session({
                await e.nonLusOutlook(compte: Reglages.actuels.compteMicrosoft ?? "", premierId: 101)
            }) { mailsOutlook = r }
            signalerCasse("Outlook", e.lectureCassee || (e.dernierEtat == .connecte && e.lignesLues == 0))
        }
        if let t = teams, let r = await t.session({
            // La liste d'abord : le compteur du titre n'apparaît qu'une fois Teams bien chargé.
            let messages = await t.messagesTeams(de: contactsTeams, premierId: 201)
            return (await t.nonLusTeams(), messages)
        }) { teamsNonLus = r.0; mailsTeams = r.1; conversationsTeams = teams?.conversationsNonLues ?? [] }
        if let t = teams { signalerCasse("Teams", t.lectureCassee || (t.dernierEtat == .connecte && t.lignesLues == 0)) }
        if let t = teams, !t.preuves.isEmpty { t.preuves.forEach { journal($0) }; t.preuves = [] }
        journal("Teams : \(teamsNonLus) non lus, \(mailsTeams.count) message(s) privé(s) · \(teams?.diagnostic ?? "")")
        majEtatsWeb()
    }

    let agenda = Agenda()

    /// Calendrier tout de suite, mails en arrière-plan.
    func rafraichirTout() {
        if Demo.active { return }   // démo : jamais de vraies données
        rafraichir()
        Task {
            ilPleut = await Mer.pleutIl()
            guard Mer.active else { return }
            do { mer = try await Mer.charger(); merErreur = false } catch { merErreur = mer == nil }
        }
        Task { await rafraichirMails() }
        Task { await rafraichirCours() }
    }

    /// Une seule lecture + tri à la fois (bouton ↻, minuteur, réveil et reconnexion peuvent tomber ensemble).
    private var lectureEnCours = false
    /// Numéro de chaque mail (par identifiant de message) : unique toutes sources confondues, et stable
    /// tant que Rainette tourne, pour que « (mail 12) » désigne toujours le même mail.
    private var numeros: [String: Int] = [:]
    private func numeroter(_ m: Mail) -> Mail {
        let n = numeros[m.idMessage] ?? (numeros.values.max() ?? 0) + 1
        numeros[m.idMessage] = n
        return Mail(id: n, compte: m.compte, idMessage: m.idMessage, expediteur: m.expediteur,
                    sujet: m.sujet, ilYa: m.ilYa, corps: m.corps)
    }

    func rafraichirMails() async {
        if Demo.active || lectureEnCours { return }
        lectureEnCours = true
        defer { lectureEnCours = false }
        // Une fois les mails lus et triés : le point du matin, s'il n'a pas encore été fait aujourd'hui.
        defer { if etatMails == .ok { pointDuMatinSiBesoin() } }
        await lirePagesWeb()
        etatMails = mails.isEmpty ? .lecture : etatMails
        let lus: [Mail]
        do {
            let gmail = try await LecteurMail.lire()
            let ecoleLus = (etatEcole == .connecte ? mailsOutlook : []) + (etatTeams == .connecte ? mailsTeams : [])
            lus = (gmail + ecoleLus).sorted { $0.ilYa < $1.ilYa }.map(numeroter)
            journal("lecture : \(gmail.count) Gmail, \(ecoleLus.count) école (Outlook \(etatEcole)), Teams \(teamsNonLus) non lus (\(etatTeams))"
                    + ecoleLus.map { "\n  école · \($0.nom) · \($0.sujet) · il y a \($0.ilYa / 3600) h" }.joined())
        } catch LecteurMail.Erreur.refus(let msg) {
            etatMails = .erreur(msg.contains("-1743")
                ? "Faut que tu me laisses piloter Mail : Réglages Système › Confidentialité › Automatisation."
                : "J'arrive pas à lire Mail 😕")
            return
        } catch {
            etatMails = .erreur("J'arrive pas à lire Mail 😕")
            return
        }
        mails = lus
        // Rien de nouveau depuis le dernier tri : on garde le résumé.
        let cle = lus.map(\.idMessage).joined(separator: "|")
        if cle == cleMails, cle != "" || importants.isEmpty {
            etatMails = .ok
            return
        }
        // Messages Teams d'une personne (pas d'un groupe) : toujours affichés, en priorité, sans passer par l'IA.
        for m in lus where m.idMessage.hasPrefix("teams:") {
            let premier = m.corps.split(separator: "\n").last.map(String.init) ?? m.corps
            verdicts[m.idMessage] = Verdict(important: true,
                                            resume: premier.count > 140 ? String(premier.prefix(137)) + "…" : premier,
                                            prioritaire: true, tache: "Réponds à \(m.nom) sur Teams")
        }
        // Seuls les mails jamais triés passent par l'IA, par paquets de 8 affichés au fur et à mesure.
        let nouveaux = lus.filter { verdicts[$0.idMessage] == nil }
        (importants, aFaire) = Resumeur.affichage(lus, verdicts, traites: traites)
        if nouveaux.isEmpty {
            cleMails = cle
            etatMails = .ok
            return
        }
        etatMails = importants.isEmpty ? .tri : .ok
        triEnCours = nouveaux.count
        await Ollama.attendrePret()
        let debut = Date()
        for k in stride(from: 0, to: nouveaux.count, by: 8) {
            let paquet = Array(nouveaux[k..<min(k + 8, nouveaux.count)])
            do {
                let v = try await Resumeur.trier(paquet)
                verdicts.merge(v) { _, n in n }
                (importants, aFaire) = Resumeur.affichage(lus, verdicts, traites: traites)
                triEnCours = max(0, nouveaux.count - k - paquet.count)
                if !importants.isEmpty { etatMails = .ok }
            } catch {
                triEnCours = 0
                nonTries = lus.filter { verdicts[$0.idMessage] == nil }.count
                Resumeur.memoriser(verdicts)
                journal("tri interrompu : \(error) — \(nonTries) mail(s) à retrier")
                etatMails = importants.isEmpty ? .erreur("L'IA répond pas… Ollama est bien lancé ?") : .ok
                return
            }
        }
        // On ne garde en mémoire que les verdicts des mails encore là (plus une marge).
        let presents = Set(lus.map(\.idMessage))
        if verdicts.count > 300 { verdicts = verdicts.filter { presents.contains($0.key) } }
        Resumeur.memoriser(verdicts)
        nonTries = 0
        journal("tri : \(nouveaux.count) nouveau(x) mail(s) en \(Int(Date().timeIntervalSince(debut))) s, \(lus.count - nouveaux.count) déjà connus")
        triEnCours = 0
        cleMails = cle
        etatMails = .ok
    }

    /// Pour la discussion : la liste des mails non lus.
    func texteMails() -> String {
        if mails.isEmpty { return "Aucun mail non lu ces trois derniers jours." }
        return mails.prefix(25).map { m in
            "[\(m.id)] de \(m.nom) (\(m.compte)) : « \(m.sujet) » — \(m.corps.replacingOccurrences(of: "\n", with: " ").prefix(200))"
        }.joined(separator: "\n")
    }
    private var historique: [[String: Any]] = []

    func demarrer() async {
        preparerPagesWeb()
        acces = await agenda.demanderAcces()
        surveillerPointDuJour()
        journal("agenda : accès au calendrier \(acces ? "autorisé" : "REFUSÉ (Réglages Système › Confidentialité › Calendriers)")")
        rafraichirTout()
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: agenda.store, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.rafraichir() } }
    }

    func rafraichir() {
        let cal = Calendar.current
        let j0 = cal.startOfDay(for: Date())
        let j1 = cal.date(byAdding: .day, value: 1, to: j0)!
        let j2 = cal.date(byAdding: .day, value: 2, to: j0)!
        let maintenant = Date()
        // Un même évènement peut figurer dans deux agendas (ex. Gmail + suggestions de Siri) : une seule fois.
        func sansDoublons(_ evs: [EKEvent]) -> [EKEvent] {
            var vus = Set<String>()
            return evs.filter { vus.insert(($0.title ?? "").lowercased() + "|\($0.startDate.timeIntervalSince1970)").inserted }
        }
        aujourdhui = sansDoublons(agenda.evenements(du: j0, au: j1).filter { $0.isAllDay || $0.endDate > maintenant })
        demain = sansDoublons(agenda.evenements(du: j1, au: j2))
        aVenir = sansDoublons(agenda.evenements(du: j2, au: cal.date(byAdding: .day, value: 7, to: j2)!))
        majA = maintenant
        majConflits()
    }

    /// Évènements (hors journées entières) et cours non annulés des 10 prochains jours.
    func plagesAVenir() -> [Chevauchements.Plage] {
        let cal = Calendar.current
        let j0 = cal.startOfDay(for: Date()), fin = cal.date(byAdding: .day, value: 10, to: j0)!
        var vus = Set<String>()
        let evs = agenda.evenements(du: j0, au: fin).filter { !$0.isAllDay }.filter {
            vus.insert(($0.title ?? "").lowercased() + "|\($0.startDate.timeIntervalSince1970)").inserted
        }
        return evs.map { Chevauchements.Plage(cle: "e:" + ($0.eventIdentifier ?? ""), titre: $0.title ?? "?",
                                              debut: $0.startDate, fin: $0.endDate, estCours: false) }
            + EmploiDuTemps.du(cours, debut: j0, fin: fin).filter { !$0.annule }.map {
                Chevauchements.Plage(cle: "c:" + $0.id, titre: $0.matiere, debut: $0.debut, fin: $0.fin, estCours: true)
            }
    }

    /// Ce qui tombe en même temps qu'autre chose (clé « e:<id> » ou « c:<id> » → libellés de l'autre).
    @Published var conflits: [String: [String]] = [:]
    func majConflits() {
        conflits = Chevauchements.trouver(plagesAVenir())
    }
    func conflit(_ ev: EKEvent) -> String? { conflits["e:" + (ev.eventIdentifier ?? "")]?.joined(separator: ", ") }
    func conflit(_ k: Cours) -> String? { conflits["c:" + k.id]?.joined(separator: ", ") }

    private func consigneSysteme() -> String {
        let cal = Calendar.current
        let j0 = cal.startOfDay(for: Date())
        let jours = (0..<14).map { i -> String in
            let d = cal.date(byAdding: .day, value: i, to: j0)!
            return "- \(Fmt.jourLong.string(from: d)) = \(Fmt.isoJour.string(from: d))"
        }.joined(separator: "\n")
        return """
        Tu es Rainette, l'assistant perso de \(Reglages.actuels.appel), qui tourne sur son Mac.
        Ne parle de sport, de mer ou de sa vie que s'il en parle, et n'invente jamais ses projets ou ses habitudes : \
        si tu ne sais pas, demande-lui ou dis-le simplement.
        Parle-lui comme un pote : en français familier et oral, tutoiement, une ou deux phrases courtes.
        Mots de tous les jours : « t'as », « y'a », « ok », « tranquille », « grave », « genre », « t'inquiète », « carrément ».
        Jamais de « Bien sûr ! », « N'hésitez pas », ni de ton service client ou de formules polies à rallonge. \
        Pas de vulgarité, pas de fautes exprès, pas de jargon. Un emoji de temps en temps, pas plus.
        Exemples de ton :
        - « t'as quoi demain ? » → « Rien de calé demain, t'es tranquille. »
        - « j'ai des mails importants ? » → « Ouais, France Travail t'invite à une réunion recrutement, faut confirmer. »
        Nous sommes le \(Fmt.jourLong.string(from: Date())), il est \(Fmt.heure.string(from: Date())).
        Correspondance des prochains jours (utilise-la pour « demain », « jeudi », etc.) :
        \(jours)
        Pour ajouter un évènement, tu DOIS appeler l'outil ajouter_evenement (sans heure de fin : 1 h). \
        Sans cet appel, rien n'est ajouté : ne dis JAMAIS « j'ajoute », « je cale » ou « c'est fait » sans l'avoir appelé. \
        Ne demande pas de confirmation toi-même : la carte de confirmation s'affiche toute seule après l'appel.
        Si l'utilisateur ne donne PAS d'heure (anniversaire, journée, rappel), mets seulement la date AAAA-MM-JJ : \
        c'est une journée entière. N'invente jamais d'heure, et ne prends pas l'heure actuelle.
        Une date sans année désigne la PROCHAINE fois que ce jour arrive (jamais une date déjà passée).
        Pour répondre à une question sur l'agenda, appelle lire_agenda ; sur les mails, appelle lire_mails.
        Quand il veut répondre à un mail (« réponds à … que … »), appelle repondre_mail avec le numéro du mail \
        et son message recopié tel quel, sans le reformuler toi-même. Mails non lus (numéro, expéditeur, objet) :
        \(mails.prefix(25).map { "[\($0.id)] \($0.nom) — \($0.sujet)" }.joined(separator: "\n"))
        N'invente jamais d'évènement. lire_agenda donne aussi ses cours de l'école, et marque « ⚠️ CHEVAUCHE » ce qui tombe en même temps : signale-le-lui.
        """
    }

    func envoyer(_ texte: String) {
        let t = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !reflechit else { return }
        bulles.append(Bulle(deMoi: true, texte: t))
        // Démo : l'IA ne voit ni le vrai agenda ni les vrais réglages.
        if Demo.active { dire("C'est le mode démo : je fais semblant 🐸"); return }
        pointSeul = false
        activite()
        // Une carte « Je te mets ça ? » attend : « oui / ouai / vas-y » la valide, « non » l'annule.
        if proposition != nil {
            let r = t.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if r.range(of: #"^(oui|ouai|ouais|ok|okay|vas-y|vas y|go|yes|carrément|grave|parfait|valide|c'est bon)( .*)?$"#,
                       options: .regularExpression) != nil { confirmer(); return }
            if r.range(of: #"^(non|nan|laisse tomber|annule|pas la peine)( .*)?$"#, options: .regularExpression) != nil {
                annuler(); return
            }
        }
        proposition = nil
        enAttente = []
        historique.append(["role": "user", "content": t])
        // Mémoire courte : on garde les derniers échanges, en repartant d'un message de l'utilisateur.
        if historique.count > 16 {
            historique = Array(historique.suffix(16))
            while let r = historique.first?["role"] as? String, r != "user" { historique.removeFirst() }
        }
        reflechit = true
        Task {
            await boucle()
            reflechit = false
        }
    }

    private func dire(_ texte: String) {
        bulles.append(Bulle(deMoi: false, texte: texte))
        if bulles.count > 20 { bulles.removeFirst(bulles.count - 20) }
        activite()
    }

    // MARK: Effacement de la conversation
    // Elle disparaît après 3 min sans activité, ou 20 s après qu'il a dit qu'il avait fini (« merci », « c'est bon »…),
    // sauf si une carte (évènement, réponse) attend encore ou si l'IA réfléchit.
    private var derniereActivite = Date()
    private var finAnnoncee = false
    private var veille: Timer?

    func activite() {
        derniereActivite = Date()
        if let t = bulles.last(where: { $0.deMoi })?.texte.lowercased(), bulles.last?.deMoi == true {
            finAnnoncee = t.range(of: #"^(merci|thx|c'est bon|c bon|ok merci|merci beaucoup|parfait merci|top merci|à plus|a plus|bye|ciao|bonne nuit|c'est tout|rien d'autre)\b"#,
                                  options: .regularExpression) != nil
        }
        if veille == nil {
            veille = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.effacerSiInactif() }
            }
        }
    }

    private func effacerSiInactif() {
        guard !bulles.isEmpty, !reflechit, proposition == nil, reponse == nil else { return }
        // Le point du matin seul reste affiché plus longtemps (il n'a peut-être pas encore regardé l'écran).
        let delai: TimeInterval = pointSeul ? 4 * 3600 : (finAnnoncee ? 20 : 180)
        if Date().timeIntervalSince(derniereActivite) >= delai { effacerConversation() }
    }

    // MARK: Point du matin

    /// Vérifie chaque minute s'il est l'heure du point du jour (7 h) : on relit tout, et le point s'ouvre
    /// à la fin de la lecture (voir `rafraichirMails`).
    private var horlogePoint: Timer?
    func surveillerPointDuJour() {
        guard horlogePoint == nil, !Demo.active else { return }
        horlogePoint = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let jour = Fmt.isoJour.string(from: Date())
                if Calendar.current.component(.hour, from: Date()) >= 7,
                   UserDefaults.standard.string(forKey: "RainettePointDuJour") != jour {
                    self.rafraichir()
                    await self.rafraichirCours()
                    await self.rafraichirMails()
                }
            }
        }
    }

    /// Vrai tant que la seule bulle affichée est le point du matin.
    private var pointSeul = false

    func pointDuMatinSiBesoin() {
        let jour = Fmt.isoJour.string(from: Date())
        let h = Calendar.current.component(.hour, from: Date())
        // À partir de 7 h, une fois par jour (si le Mac dormait à 7 h : dès qu'il se réveille).
        guard !Demo.active, h >= 7, UserDefaults.standard.string(forKey: "RainettePointDuJour") != jour else { return }
        UserDefaults.standard.set(jour, forKey: "RainettePointDuJour")
        // Le compte rendu complet, dans une fenêtre au centre de l'écran (une fois par jour).
        CompteRendu.afficher(self)
        journal("point du jour affiché (fenêtre)")
    }

    /// Le point du jour, écrit par le code (rapide et sans erreur) : tâches, cours, agenda, ce qui arrive, la mer.
    func pointDuMatin() -> String {
        let cal = Calendar.current
        let j0 = cal.startOfDay(for: Date()), j1 = cal.date(byAdding: .day, value: 1, to: j0)!
        var lignes: [String] = []
        // « 9h », « 13h30 » : plus naturel que « 09:00 ».
        func h(_ d: Date) -> String {
            let c = cal.dateComponents([.hour, .minute], from: d)
            return "\(c.hour ?? 0)h" + ((c.minute ?? 0) > 0 ? String(format: "%02d", c.minute!) : "")
        }
        func sansPoint(_ t: String) -> String { t.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
        let taches = aFaire.filter { !faits.contains($0) }.map(sansPoint)
        if !taches.isEmpty {
            lignes.append("\(taches.count == 1 ? "1 truc" : "\(taches.count) trucs") à faire : "
                          + taches.prefix(3).joined(separator: " ; ") + ".")
        }
        // Seulement les cours qui ne sont pas encore finis.
        let lecons = EmploiDuTemps.du(cours, debut: j0, fin: j1).filter { !$0.annule && $0.fin > Date() }
        let annules = EmploiDuTemps.du(cours, debut: j0, fin: j1).filter(\.annule)
        if !lecons.isEmpty {
            let l = lecons.prefix(4).map { k in
                "\(k.matiere) à \(h(k.debut))"
                    + (k.distanciel ? " (à distance)" : k.salle.map { " (\($0))" } ?? "")
            }
            lignes.append("Cours : " + l.joined(separator: ", ") + ".")
        }
        if !annules.isEmpty { lignes.append("Annulé : " + annules.map(\.matiere).joined(separator: ", ") + " 🎉") }
        let evs = aujourdhui
        if !evs.isEmpty {
            lignes.append("Agenda : " + evs.prefix(3).map { e in
                (e.title ?? "?") + (e.isAllDay ? "" : " à \(h(e.startDate))")
            }.joined(separator: ", ") + ".")
        }
        if lecons.isEmpty && evs.isEmpty { lignes.append("Rien de calé aujourd'hui, t'es tranquille.") }
        if let p = (demain + aVenir).first {
            let quand = cal.isDateInTomorrow(p.startDate) ? "demain" : Fmt.jourCourt.string(from: p.startDate)
            lignes.append("Ensuite : \(p.title ?? "?") \(quand)\(p.isAllDay ? "" : " à \(h(p.startDate))").")
        }
        if let m = mer {
            var bon: [String] = []
            if let n = m.navigation, let h = Mer.maintenant(n), Mer.avisNavigation(h).0 == .bon { bon.append("cata") }
            if let s = m.surf, let h = Mer.maintenant(s), Mer.avisSurf(h).0 == .bon { bon.append("surf") }
            if !bon.isEmpty { lignes.append("Et ça a l'air bon pour le \(bon.joined(separator: " et le ")) 🌊") }
        }
        return "☀️ Le point du jour\n" + lignes.joined(separator: "\n")
    }

    func effacerConversation() {
        withAnimation(.easeOut(duration: 0.4)) { bulles = [] }
        historique = []
        enAttente = []
        finAnnoncee = false
        pointSeul = false
    }

    private func boucle() async {
        var relance = false
        for _ in 0..<5 {
            let messages = [["role": "system", "content": consigneSysteme()]] + historique
            let rep: [String: Any]
            do {
                rep = try await Ollama.chat(messages, outils: Ollama.outils)
            } catch {
                dire("J'arrive pas à joindre l'IA, t'as lancé Ollama ?")
                return
            }
            historique.append(rep)
            let appels = rep["tool_calls"] as? [[String: Any]] ?? []
            var nouvelles: [Proposition] = []
            if appels.isEmpty {
                let c = (rep["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Il annonce un ajout au calendrier sans avoir appelé l'outil : rien ne serait ajouté. On le relance une fois.
                if !relance, proposition == nil,
                   c.range(of: #"(?i)\b(j'?ajoute|je (te )?(le |la |l')?(cale|mets|rajoute)|c'est (calé|ajouté|noté)|ajouté au calendrier|on cale)"#,
                           options: .regularExpression) != nil {
                    relance = true
                    historique.removeLast()
                    historique.append(["role": "user", "content": "(Rappel du système : tu n'as pas appelé ajouter_evenement, donc rien n'est ajouté. Appelle l'outil maintenant avec la bonne date.)"])
                    journal("agenda : le modèle a annoncé un ajout sans appeler l'outil, relance")
                    continue
                }
                dire(c.isEmpty ? "J'ai pas capté, tu peux reformuler ?" : c)
                return
            }
            for appel in appels {
                let fn = appel["function"] as? [String: Any] ?? [:]
                let nom = fn["name"] as? String ?? ""
                let args = fn["arguments"] as? [String: Any] ?? [:]
                switch nom {
                case "lire_mails":
                    historique.append(["role": "tool", "tool_name": nom, "content": texteMails()])
                case "repondre_mail":
                    let id = (args["id"] as? Int) ?? Int(args["id"] as? String ?? "") ?? -1
                    if let m = mails.first(where: { $0.id == id }),
                       let msg = args["message"] as? String, !msg.isEmpty {
                        preparerReponse(m, brouillon: msg)
                        historique.append(["role": "tool", "tool_name": nom,
                                           "content": "Carte de réponse affichée ; Rainette demande le ton."])
                        return
                    }
                    historique.append(["role": "tool", "tool_name": nom,
                                       "content": "Mail introuvable : donne le numéro exact d'un mail non lu."])
                case "lire_agenda":
                    historique.append(["role": "tool", "tool_name": nom, "content": lireAgenda(args)])
                case "ajouter_evenement":
                    // Correction du jour de la semaine seulement s'il n'y a qu'un évènement dans ce tour.
                    let unSeul = appels.filter { (($0["function"] as? [String: Any])?["name"] as? String) == nom }.count == 1
                    if let p = proposer(args, corrigerJour: unSeul) {
                        nouvelles.append(p)
                        historique.append(["role": "tool", "tool_name": nom,
                                           "content": "Proposition affichée ; l'utilisateur doit confirmer."])
                    } else {
                        historique.append(["role": "tool", "tool_name": nom,
                                           "content": "Date illisible : utilise AAAA-MM-JJTHH:MM."])
                    }
                default:
                    historique.append(["role": "tool", "tool_name": nom, "content": "Outil inconnu."])
                }
            }
            if !nouvelles.isEmpty {
                proposition = nouvelles.removeFirst()
                enAttente = nouvelles
                for p in [proposition!] + enAttente {
                    journal("agenda : proposé « \(p.titre) », \(p.resume) — en attente de « Vas-y »")
                }
                dire(enAttente.isEmpty ? "Je te le mets dans le calendrier ?"
                     : "J'en ai \(enAttente.count + 1) à ajouter, on les fait un par un. Je te mets celui-là ?")
                return
            }
        }
        dire("Je me suis emmêlé les pattes 🐸, tu peux redire autrement ?")
    }

    private func lireAgenda(_ a: [String: Any]) -> String {
        guard let du = (a["du"] as? String).flatMap(Fmt.lire)?.0,
              let au = (a["au"] as? String).flatMap(Fmt.lire)?.0
        else { return "Dates illisibles : utilise AAAA-MM-JJ." }
        let fin = Calendar.current.date(byAdding: .day, value: 1, to: au)!
        let evs = agenda.evenements(du: du, au: fin)
        // Les cours de l'école comptent aussi : ils ne sont pas dans le calendrier Apple.
        let lecons = EmploiDuTemps.du(cours, debut: du, fin: fin)
        if evs.isEmpty && lecons.isEmpty { return "Aucun évènement ni cours." }
        let lignes: [(Date, String)] = evs.map { e in
            let quand = e.isAllDay ? "journée entière"
                : "\(Fmt.heure.string(from: e.startDate))–\(Fmt.heure.string(from: e.endDate))"
            let lieu = (e.location ?? "").isEmpty ? "" : " (\(e.location!))"
            return (e.isAllDay ? Calendar.current.startOfDay(for: e.startDate) : e.startDate,
                    "\(Fmt.jourCourt.string(from: e.startDate)) \(quand) : \(e.title ?? "sans titre")\(lieu)"
                    + (conflit(e).map { " ⚠️ CHEVAUCHE : \($0)" } ?? ""))
        } + lecons.map { k in
            let ou = k.annule ? "ANNULÉ" : (k.distanciel ? "à distance" : (k.salle ?? ""))
            return (k.debut, "\(Fmt.jourCourt.string(from: k.debut)) \(Fmt.heure.string(from: k.debut))–\(Fmt.heure.string(from: k.fin)) : cours \(k.matiere) (\(ou)\(k.prof.map { ", " + $0 } ?? ""))"
                    + (conflit(k).map { " ⚠️ CHEVAUCHE : \($0)" } ?? ""))
        }
        return lignes.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
    }

    private func proposer(_ a: [String: Any], corrigerJour: Bool = true) -> Proposition? {
        guard let titre = a["titre"] as? String, !titre.isEmpty,
              let lu = (a["debut"] as? String).flatMap(Fmt.lire)
        else { return nil }
        let journee = lu.1
        let dernier = (historique.last {
            ($0["role"] as? String) == "user" && !(($0["content"] as? String ?? "").hasPrefix("(Rappel du système"))
        }?["content"] as? String ?? "")
        let debut = Dates.recaler(lu.0, journee: journee, message: dernier, corrigerJour: corrigerJour)
        // La fin suit le début recalé : on garde la durée demandée (sinon « lundi 9h-13h » recalé ferait 2 jours).
        let finModele = (a["fin"] as? String).flatMap(Fmt.lire)?.0
        let fin: Date
        if journee {
            fin = Calendar.current.date(byAdding: .day, value: 1, to: debut)!
        } else if let f = finModele, f > lu.0 {
            fin = debut.addingTimeInterval(f.timeIntervalSince(lu.0))
        } else {
            fin = debut.addingTimeInterval(3600)
        }
        let lieu = (a["lieu"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var prop = Proposition(titre: titre, debut: debut, fin: fin, journee: journee, lieu: lieu)
        if !journee {
            let nouveau = Chevauchements.Plage(cle: "nouveau", titre: titre, debut: debut, fin: fin, estCours: false)
            let deja = Chevauchements.trouver([nouveau] + plagesAVenir())["nouveau"] ?? []
            if !deja.isEmpty { prop.conflit = deja.joined(separator: ", ") }
        }
        return prop
    }

    func confirmer() {
        guard let p = proposition, !Demo.active else { proposition = nil; return }
        do {
            let nomAgenda = try agenda.ajouter(p)
            journal("agenda : ajouté « \(p.titre) », \(p.resume) (agenda « \(nomAgenda) »)")
            dire("✅ C'est calé : \(p.titre), \(p.resume) (dans ton agenda « \(nomAgenda) »).")
            historique.append(["role": "assistant", "content": "C'est ajouté au calendrier."])
            rafraichir()
        } catch {
            journal("agenda : échec de l'ajout de « \(p.titre) » : \(error)")
            dire("J'ai pas pu l'ajouter… t'as bien autorisé le calendrier ?")
        }
        proposition = nil
        suivante()
    }

    func annuler() {
        if let p = proposition { journal("agenda : « \(p.titre) » proposé puis annulé") }
        proposition = nil
        dire("Ok, je laisse tomber.")
        historique.append(["role": "assistant", "content": "Ajout annulé par l'utilisateur."])
        suivante()
    }
}

// MARK: - Interface

struct Verre: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

struct Widget: View {
    @ObservedObject var e: Etat
    @State private var saisie = ""
    @State private var hBulles: CGFloat = 80
    @State private var voirCaches = false
    @State private var cligne = false
    @FocusState private var focus: Bool
    private let horloge = Timer.publish(every: 1800, on: .main, in: .common).autoconnect()

    private var salutation: String {
        let h = Calendar.current.component(.hour, from: e.majA)
        if h < 5 { return "Encore debout ?" }
        if h < 18 { return "Salut" }
        return "Hey"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            entete
            ScrollView {
                milieu
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 14) {
                if !e.acces {
                    Label("Laisse-moi voir ton calendrier : Réglages Système › Confidentialité › Calendriers.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                discussion
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(fond)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(or.opacity(0.35), lineWidth: 1))
        .overlay { if e.edition { CalqueEdition(e: e) } }
        .onReceive(horloge) { _ in e.rafraichirTout() }
    }

    // Mails, à faire, agenda : la partie qui défile quand la place manque.
    private var milieu: some View {
        VStack(alignment: .leading, spacing: 14) {
            carte("Mails", icone: "envelope.fill", compte: e.mails.count) {
                carteMails
                connexions
            }
            if !e.aFaire.isEmpty || e.dernierRetrait != nil {
                carte("À faire", icone: "checklist", compte: nil) {
                    VStack(alignment: .leading, spacing: 7) {
                        if let r = e.dernierRetrait {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                                Text("« \(r.tache) » fait\(r.ids.isEmpty ? "" : ", mail retiré")")
                                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Button("Annuler") { e.annulerRetrait() }
                                    .buttonStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(or)
                            }
                            .transition(.opacity)
                        }
                        ForEach(e.aFaire, id: \.self) { t in
                            let fait = e.faits.contains(t)
                            Button { withAnimation(.easeOut(duration: 0.15)) { e.cocher(t) } } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: fait ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13)).foregroundStyle(or)
                                    Text(t)
                                        .strikethrough(fait, color: .secondary)
                                        .foregroundStyle(fait ? .secondary : .primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(fait ? "Décocher" : "C'est fait")
                        }
                    }
                }
            }
            let j0 = Calendar.current.startOfDay(for: Date())
            let j1 = Calendar.current.date(byAdding: .day, value: 1, to: j0)!
            let j2 = Calendar.current.date(byAdding: .day, value: 1, to: j1)!
            let coursAuj = e.coursDu(j0, j1), coursDem = e.coursDu(j1, j2)
            carte("Aujourd'hui", icone: "calendar", compte: e.aujourdhui.count + coursAuj.count) {
                liste(e.aujourdhui, cours: coursAuj, vide: "Plus rien aujourd'hui, t'es libre.")
            }
            carte("Demain", icone: "moon.stars.fill", compte: e.demain.count + coursDem.count) {
                liste(e.demain, cours: coursDem, vide: "Rien de calé demain.")
            }
            if !e.aVenir.isEmpty {
                carte("À venir", icone: "calendar.badge.clock", compte: e.aVenir.count) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(e.aVenir.prefix(6), id: \.eventIdentifier) { ev in
                            HStack(alignment: .top, spacing: 10) {
                                Capsule()
                                    .fill(ev.calendar.map { Color(nsColor: $0.color) } ?? or)
                                    .frame(width: 4, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title ?? "(sans titre)").font(.system(size: 14, weight: .medium)).lineLimit(2)
                                    Text(Fmt.jourCourt.string(from: ev.startDate).capitalizedPremier + " · " + quand(ev))
                                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    if let c = e.conflit(ev) { alerteConflit(c) }
                                }
                            }
                        }
                        if e.aVenir.count > 6 {
                            Text("+ \(e.aVenir.count - 6) autres").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var fond: some View {
            ZStack {
                Verre()
                Rectangle()
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.14, blue: 0.08).opacity(0.75),
                                              Color.black.opacity(0.55)],
                                     startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    // En-tête : logo, salutation, date, actions.
    private var entete: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(or.opacity(0.18))
                Circle().stroke(or.opacity(0.6), lineWidth: 1)
                Grenouille(style: .pleine, humeur: cligne && [.normale, .pluie].contains(e.humeur) ? .cligne : e.humeur)
                    .padding(5)
                    .animation(.easeInOut(duration: 0.25), value: e.humeur)
            }
            .frame(width: 48, height: 48)
            .help(e.humeur == .dort ? "Chut, je dors" : e.humeur == .pluie ? "Il pleut !" : e.humeur == .contente ? "Rien à faire 🎉" : "Rainette")
            .task {
                // Un clignement d'yeux toutes les 3 à 7 secondes.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Double.random(in: 3...7)))
                    cligne = true
                    try? await Task.sleep(for: .milliseconds(160))
                    cligne = false
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("RAINETTE").font(.system(size: 11, weight: .heavy)).kerning(2).foregroundStyle(or)
                Text(salutation).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(Fmt.jourLong.string(from: e.majA).capitalizedPremier)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                if let m = e.mer { LignesMer(c: m).padding(.top, 3) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 12) {
                    Button { CompteRendu.afficher(e) } label: { Image(systemName: "list.bullet.rectangle.portrait") }
                        .buttonStyle(.plain).help("Le point du jour : tout ce que t'as reçu")
                    Button { e.rafraichirTout() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("Rafraîchir")
                    Menu {
                        Button("Le point du jour…") { CompteRendu.afficher(e) }
                        Divider()
                        Button("Brancher ma boîte de l'école…") { e.ecole?.afficher() }
                        Button("Brancher Teams…") { e.teams?.afficher() }
                        Divider()
                        Button("Bouger ou redimensionner le widget…") { e.edition = true }
                        Divider()
                        Button("Fermer Rainette") { NSApp.terminate(nil) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .font(.system(size: 14)).foregroundStyle(.secondary)
                Text("à jour \(Fmt.heure.string(from: e.majA))")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var carteMails: some View {
        switch e.etatMails {
        case .attente, .lecture where e.mails.isEmpty:
            attente("J'ouvre ta boîte mail…")
        case .tri where e.importants.isEmpty:
            attente("Je trie tes \(max(e.triEnCours, 1)) nouveaux mails, j'arrive…")
        case .erreur(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5)).foregroundStyle(.orange)
        default:
            if e.mails.isEmpty {
                Text("Aucun nouveau mail, t'es tranquille 🐸").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(e.importants.prefix(6)) { r in ligneMail(r) }
                    let autres = e.mails.count - min(e.importants.count, 6) - e.nonTries
                    if e.nonTries > 0, e.triEnCours == 0 {
                        Text("\(e.nonTries) pas encore triés, l'IA répondait pas. Je réessaie au prochain coup.")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    if autres > 0, e.triEnCours == 0 {
                        // Un clic déroule les mails cachés : on peut en remonter un si le tri s'est trompé.
                        Button { withAnimation(.easeOut(duration: 0.2)) { voirCaches.toggle() } } label: {
                            HStack(spacing: 5) {
                                Text(e.importants.isEmpty
                                     ? "\(autres) non lus, que des pubs et des newsletters, rien d'important."
                                     : "+ \(autres) autres, rien d'important.")
                                Image(systemName: voirCaches ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                            }
                            .font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help(voirCaches ? "Masquer" : "Voir ce que j'ai caché")
                        if voirCaches { listeCaches }
                    }
                    if e.triEnCours > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Je trie encore \(e.triEnCours) mail\(e.triEnCours > 1 ? "s" : "")…")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connexions: some View {
        ForEach(e.lecturesCassees, id: \.self) { nom in
            Label("\(nom) : la page a changé, j'arrive plus à la lire.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.orange)
        }
        if e.teamsNonLus > 0 {
            Button { e.teams?.afficher(pourConnexion: false) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 11)).foregroundStyle(or)
                    Text("Teams : \(e.teamsNonLus) message\(e.teamsNonLus > 1 ? "s" : "") pas lu\(e.teamsNonLus > 1 ? "s" : "")")
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer()
                    Text("Ouvrir").font(.system(size: 12)).foregroundStyle(or)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        let manque = [("École", e.etatEcole, e.ecole), ("Teams", e.etatTeams, e.teams), (e.edt?.nom ?? "Cours", e.etatEdt, e.edt)]
            .filter { $0.1 == .connexionRequise }
        if !manque.isEmpty {
            HStack(spacing: 8) {
                ForEach(manque, id: \.0) { m in
                    Button { m.2?.afficher() } label: {
                        Label("Brancher \(m.0)", systemImage: m.0 == "Teams" ? "bubble.left.and.bubble.right" : "graduationcap")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().stroke(or.opacity(0.6), lineWidth: 1))
                            .foregroundStyle(or)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    private func attente(_ t: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(t).foregroundStyle(.secondary)
        }
    }

    private func ligneMail(_ r: ResumeMail) -> some View {
        Button { r.mail.ouvrir() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: r.mail.estTeams ? "bubble.left.and.bubble.right.fill"
                      : (r.prioritaire ? "star.fill" : "circle.fill"))
                    .font(.system(size: r.prioritaire || r.mail.estTeams ? 11 : 6))
                    .foregroundStyle(r.prioritaire ? or : Color.secondary)
                    .frame(width: 14).padding(.top, r.prioritaire || r.mail.estTeams ? 3 : 6)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(r.mail.nom).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(depuis(r.mail.ilYa)).font(.system(size: 11)).foregroundStyle(.tertiary)
                        Button { repondreA(r.mail) } label: {
                            Image(systemName: "arrowshape.turn.up.left").font(.system(size: 11))
                        }
                        .buttonStyle(.plain).foregroundStyle(or).help("Répondre à \(r.mail.nom)")
                    }
                    Text(r.resume).font(.system(size: 13)).foregroundStyle(.secondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ouvrir dans Mail · \(r.mail.sujet)")
        .contextMenu { Button("Répondre…") { repondreA(r.mail) } }
    }

    /// Pré-remplit la barre : il n'a plus qu'à écrire ce qu'il veut répondre.
    private func repondreA(_ m: Mail) {
        saisie = "Réponds à \(m.nom) (mail \(m.id)) : "
        focus = true
    }

    /// Les mails jugés « inutiles » : expéditeur et objet, un clic l'ouvre, la flèche le remonte dans le widget.
    private var listeCaches: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(e.mailsCaches().prefix(25), id: \.idMessage) { m in
                HStack(spacing: 8) {
                    Button { m.ouvrir() } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(m.nom).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(m.sujet).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Ouvrir")
                    Button { withAnimation { e.remonter(m) } } label: {
                        Image(systemName: "arrow.up.circle").font(.system(size: 14)).foregroundStyle(or)
                    }
                    .buttonStyle(.plain).help("C'est important : l'afficher")
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
    }

    private func depuis(_ s: Int) -> String {
        if s < 3600 { return "\(max(1, s / 60)) min" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) j"
    }

    // Une carte de section.
    private func carte<C: View>(_ titre: String, icone: String, compte: Int?,
                                @ViewBuilder contenu: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icone).font(.system(size: 12, weight: .semibold)).foregroundStyle(or)
                Text(titre.uppercased()).font(.system(size: 11.5, weight: .bold)).kerning(1.2)
                    .foregroundStyle(or.opacity(0.95))
                Spacer()
                if let n = compte, n > 0 {
                    Text("\(n)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(or.opacity(0.22))).foregroundStyle(or)
                }
            }
            contenu().font(.system(size: 14))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.055)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }

    private enum Creneau: Identifiable {
        case ev(EKEvent), cours(Cours)
        var id: String {
            switch self { case .ev(let e): return "ev-" + (e.eventIdentifier ?? UUID().uuidString)
                          case .cours(let c): return "cours-" + c.id }
        }
        var debut: Date {
            switch self { case .ev(let e): return e.isAllDay ? .distantPast : e.startDate
                          case .cours(let c): return c.debut }
        }
    }

    private func liste(_ evs: [EKEvent], cours: [Cours], vide: String) -> some View {
        let tout = (evs.map(Creneau.ev) + cours.map(Creneau.cours)).sorted { $0.debut < $1.debut }
        return Group {
            if tout.isEmpty {
                Text(vide).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(tout.prefix(8))) { c in
                        switch c {
                        case .ev(let ev):
                            HStack(alignment: .top, spacing: 10) {
                                Capsule()
                                    .fill(ev.calendar.map { Color(nsColor: $0.color) } ?? or)
                                    .frame(width: 4, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ev.title ?? "(sans titre)").font(.system(size: 14, weight: .medium)).lineLimit(2)
                                    Text(quand(ev)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    if let c = e.conflit(ev) { alerteConflit(c) }
                                }
                            }
                        case .cours(let k):
                            HStack(alignment: .top, spacing: 10) {
                                Capsule().fill(k.annule ? Color.secondary : or).frame(width: 4, height: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("🎓 \(k.matiere)")
                                        .font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        .strikethrough(k.annule, color: .secondary)
                                    Text(detailCours(k)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    if let c = e.conflit(k) { alerteConflit(c) }
                                }
                            }
                        }
                    }
                    if tout.count > 8 {
                        Text("+ \(tout.count - 8) autres").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func alerteConflit(_ c: String) -> some View {
        Text("⚠️ en même temps que \(c)").font(.system(size: 11.5)).foregroundStyle(.orange).lineLimit(2)
    }

    private func detailCours(_ k: Cours) -> String {
        var t = "\(Fmt.heure.string(from: k.debut))–\(Fmt.heure.string(from: k.fin))"
        if k.annule { return t + " · annulé" }
        if k.distanciel { t += " · à distance" } else if let s = k.salle { t += " · \(s)" }
        if let p = k.prof { t += " · \(p)" }
        return t
    }

    private func quand(_ ev: EKEvent) -> String {
        var s = ev.isAllDay ? "Toute la journée"
            : "\(Fmt.heure.string(from: ev.startDate)) – \(Fmt.heure.string(from: ev.endDate))"
        if let l = ev.location, !l.isEmpty { s += "  ·  \(l)" }
        return s
    }

    // Discussion avec l'IA locale.
    private var discussion: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !e.bulles.isEmpty {
                ScrollViewReader { lecteur in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(e.bulles) { b in
                                HStack(alignment: .bottom, spacing: 6) {
                                    if b.deMoi { Spacer(minLength: 50) } else {
                                        Grenouille(style: .pleine).frame(width: 18, height: 18)
                                    }
                                    Text(b.texte)
                                        .font(.system(size: 13.5))
                                        .textSelection(.enabled)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                .fill(b.deMoi ? or.opacity(0.25) : Color.white.opacity(0.08))
                                        )
                                    if !b.deMoi { Spacer(minLength: 50) }
                                }.id(b.id)
                            }
                        }
                        .padding(.vertical, 2)
                        .mesure { hBulles = $0 }
                    }
                    // Juste la hauteur des messages (240 au plus) : le reste de la place va au milieu du widget.
                    .frame(height: min(max(hBulles, 40), 240))
                    .onChange(of: e.bulles.count) { _, _ in
                        if let d = e.bulles.last { withAnimation { lecteur.scrollTo(d.id, anchor: .bottom) } }
                    }
                }
            }
            CarteReponse(e: e)
            if let p = e.proposition {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Je te mets ça ?", systemImage: "calendar.badge.plus")
                        .font(.system(size: 11.5, weight: .bold)).foregroundStyle(or)
                    Text(p.titre).font(.system(size: 15, weight: .semibold))
                    Text(p.resume + (p.lieu.map { "  ·  \($0)" } ?? ""))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    if let c = p.conflit {
                        Text("⚠️ Ça tombe pendant : \(c)").font(.system(size: 12.5)).foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) {
                        Button { e.confirmer() } label: { Text("Vas-y").frame(minWidth: 70) }
                            .buttonStyle(.borderedProminent).tint(or).keyboardShortcut(.defaultAction)
                        Button { e.annuler() } label: { Text("Laisse tomber").frame(minWidth: 70) }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 2)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(or.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(or.opacity(0.55), lineWidth: 1))
            }
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(or)
                TextField("Tu veux quoi…", text: $saisie)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focus)
                    .onSubmit(envoyer)
                    .onChange(of: saisie) { _, _ in e.activite() }   // il écrit : on n'efface pas
                if e.reflechit {
                    ProgressView().controlSize(.small)
                } else {
                    Button(action: envoyer) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                            .foregroundStyle(saisie.isEmpty ? Color.secondary : or)
                    }
                    .buttonStyle(.plain).disabled(saisie.isEmpty)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(focus ? or.opacity(0.7) : Color.white.opacity(0.1), lineWidth: 1))
        }
    }

    private func envoyer() {
        e.envoyer(saisie)
        saisie = ""
    }
}

/// Mesure la hauteur réelle d'une vue (pour savoir ce qui tient dans le widget).
extension View {
    func mesure(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(GeometryReader { g in
            Color.clear.onAppear { action(g.size.height) }.onChange(of: g.size.height) { _, h in action(h) }
        })
    }
}

extension String {
    var capitalizedPremier: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Fenêtre collée au bureau

final class FenetreBureau: NSWindow {
    weak var gardien: GardienBureau?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Le cadre est choisi par l'utilisateur (mode « Modifier ») ; on le garde toujours dans l'écran visible.
    override func setFrame(_ r: NSRect, display: Bool) {
        guard let ecran = screen ?? NSScreen.main else { return super.setFrame(r, display: display) }
        super.setFrame(Disposition.dansLEcran(r, ecran), display: display)
    }
    /// Remet le widget à son cadre mémorisé (ou par défaut).
    func placer() {
        guard let ecran = screen ?? NSScreen.main else { return }
        setFrame(Disposition.cadre(ecran), display: true)
        gardien?.verifier()
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
}

final class Delegue: NSObject, NSApplicationDelegate {
    var fenetre: FenetreBureau!
    var gardien: GardienBureau!
    let etat: Etat

    override init() {
        etat = MainActor.assumeIsolated { Etat() }
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let hc = NSHostingController(rootView: Widget(e: etat))
        hc.sizingOptions = []
        let w = FenetreBureau(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentViewController = hc
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = false
        w.appearance = NSAppearance(named: .darkAqua)
        fenetre = w
        fenetreWidget = w
        gardien = GardienBureau(fenetre: w)
        if Demo.active {
            // Démo : données inventées, taille fixe, rien de réel n'est lu ni enregistré.
            if let v = NSScreen.main?.visibleFrame {
                w.setFrame(NSRect(x: v.maxX - 476, y: v.minY + 16, width: 460, height: v.height - 32), display: true)
            }
            w.orderFront(nil)
            etat.remplirDemo()
            return
        }
        w.gardien = gardien
        w.placer()
        w.orderFront(nil)
        gardien.demarrer()
        // Écran branché/débranché, Dock déplacé : on remet le widget dans l'écran visible.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak w] _ in Task { @MainActor in w?.placer() } }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.etat.rafraichirTout() } }

        Task { @MainActor in await etat.demarrer() }
    }
}

@main
enum Lanceur {
    static func main() {
        let app = NSApplication.shared
        let d = Delegue()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.mainMenu = menuEdition()
        app.run()
    }

    /// Sans barre de menus, Cmd+C / Cmd+V / Cmd+X / Cmd+A ne font rien (ils passent par le menu Édition).
    /// On en installe un, invisible (Rainette n'a pas de barre de menus), pour que les raccourcis marchent
    /// dans la barre de discussion, les réponses aux mails et les fenêtres Outlook / Teams.
    static func menuEdition() -> NSMenu {
        let principal = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu(title: "Rainette")
        app.submenu?.addItem(withTitle: "Fermer Rainette", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        principal.addItem(app)
        let edition = NSMenuItem()
        let m = NSMenu(title: "Édition")
        m.addItem(withTitle: "Annuler", action: Selector(("undo:")), keyEquivalent: "z")
        let retablir = m.addItem(withTitle: "Rétablir", action: Selector(("redo:")), keyEquivalent: "z")
        retablir.keyEquivalentModifierMask = [.command, .shift]
        m.addItem(.separator())
        m.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        m.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        m.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edition.submenu = m
        principal.addItem(edition)
        let fenetre = NSMenuItem()
        fenetre.submenu = NSMenu(title: "Fenêtre")
        fenetre.submenu?.addItem(withTitle: "Fermer la fenêtre", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        principal.addItem(fenetre)
        return principal
    }
}
