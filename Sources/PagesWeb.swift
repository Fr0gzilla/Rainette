// Outlook web, Teams web et emploi du temps dans des fenêtres cachées : on s'y connecte une fois, Rainette y lit ce qu'il faut.
// Pour ne pas garder des centaines de Mo en mémoire, une page n'existe que le temps d'une lecture :
// on la crée, on attend qu'elle soit prête, on lit, puis on la détruit (les cookies restent : on reste connecté).
import AppKit
import WebKit

@MainActor
final class PageWeb: NSObject, WKNavigationDelegate, NSWindowDelegate {
    enum Etat: Equatable { case chargement, connexionRequise, connecte }

    let nom: String
    let adresse: URL
    let hotes: [String]          // hôtes où l'on est « dans l'appli » (et non sur la page de connexion)
    /// Test JavaScript qui dit si la page a fini d'afficher ce qu'on veut lire.
    var pret = "true"
    private(set) var vue: WKWebView?
    let fenetre: NSWindow
    var quandConnecte: (() -> Void)?
    private(set) var visible = false
    /// Fenêtre ouverte pour se connecter (elle se recache toute seule une fois connecté),
    /// et non pour lire un mail (là, elle reste ouverte).
    private var pourConnexion = true
    private var occupe = false
    /// Dernier état connu (la page est le plus souvent détruite entre deux lectures).
    private(set) var dernierEtat: Etat = .chargement
    /// Teams : pendant une lecture en arrière-plan, rien ne doit être marqué comme lu.
    var discret = false
    private var vueDiscrete = false

    /// Filtre réseau : bloque l'accusé de lecture de Teams (requête « consumptionhorizon » vers son service de chat).
    /// Il agit sur toutes les requêtes de la page, y compris celles des processus en arrière-plan de Teams.
    private static var filtreLu: WKContentRuleList?
    static func preparerFiltre() async {
        guard filtreLu == nil else { return }
        let regles = """
        [{"trigger": {"url-filter": "consumptionhorizon", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}},
         {"trigger": {"url-filter": "readreceipt", "url-filter-is-case-sensitive": false}, "action": {"type": "block"}}]
        """
        filtreLu = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "rainette-pas-lu", encodedContentRuleList: regles)
    }

    /// La page croit être dans un onglet caché et sans focus.
    private static let scriptCache = """
    (() => {
      try {
        Object.defineProperty(Document.prototype, 'visibilityState', { get: () => 'hidden', configurable: true });
        Object.defineProperty(Document.prototype, 'hidden', { get: () => true, configurable: true });
        Document.prototype.hasFocus = () => false;
        for (const t of ['focus', 'visibilitychange', 'pageshow']) {
          window.addEventListener(t, e => e.stopImmediatePropagation(), true);
          document.addEventListener(t, e => e.stopImmediatePropagation(), true);
        }
      } catch (e) {}
    })();
    """

    init(nom: String, adresse: String, hotes: [String]) {
        self.nom = nom
        self.adresse = URL(string: adresse)!
        self.hotes = hotes
        fenetre = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: true)
        super.init()
        fenetre.title = "Rainette · \(nom)"
        fenetre.isReleasedWhenClosed = false
        fenetre.delegate = self
    }

    // MARK: Cycle de vie

    /// Crée la page (si elle n'existe pas) et la charge, dans la fenêtre cachée.
    func reveiller() {
        guard vue == nil else { return }
        let conf = WKWebViewConfiguration()
        conf.websiteDataStore = .default()   // cookies conservés : on reste connecté
        vueDiscrete = discret && !visible
        if vueDiscrete {
            if let f = PageWeb.filtreLu { conf.userContentController.add(f) }
            conf.userContentController.addUserScript(WKUserScript(source: PageWeb.scriptCache,
                                                                  injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let v = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 860), configuration: conf)
        v.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15"
        v.navigationDelegate = self
        fenetre.contentView = v
        vue = v
        if !visible { cacher() }
        v.load(URLRequest(url: adresse))
    }

    /// Détruit la page : c'est ce qui libère vraiment la mémoire (le processus web s'arrête).
    func endormir() {
        guard !visible, !occupe, let v = vue else { return }
        v.stopLoading()
        v.navigationDelegate = nil
        fenetre.contentView = nil
        vue = nil
        fenetre.orderOut(nil)
    }

    /// Attend que la page soit connectée et prête (60 s au plus).
    func attendrePret(_ secondes: Double = 60) async -> Bool {
        let fin = Date().addingTimeInterval(secondes)
        var depuisConnexion: Date?
        while Date() < fin {
            let e = etat
            if e == .connecte, (await js(pret) as? Bool) == true { return true }
            if e == .connexionRequise {
                // L'écran « Choisir un compte » est cliqué tout seul ; s'il reste là 25 s, il faut se reconnecter.
                if depuisConnexion == nil { depuisConnexion = Date() }
                if Date().timeIntervalSince(depuisConnexion!) > 25 { return false }
            } else { depuisConnexion = nil }
            try? await Task.sleep(for: .seconds(1.5))
        }
        return false
    }

    /// Ouvre la page, attend qu'elle soit prête, fait la lecture, puis la referme.
    /// Vrai si la dernière lecture a échoué alors qu'on est connecté : la page a sans doute changé.
    private(set) var lectureCassee = false

    func session<T>(_ action: () async -> T) async -> T? {
        guard !occupe else { return nil }
        occupe = true
        if discret { await PageWeb.preparerFiltre() }
        reveiller()
        let ok = await attendrePret()
        if !ok {
            diagnostic = "pas prête à temps : \(etat), \(vue?.url?.absoluteString.prefix(70) ?? "-"), titre « \(await js("document.title") as? String ?? "?") », "
                + "prêt=\(await js(pret) as? Bool ?? false)"
        }
        let r: T? = ok ? await action() : nil
        // Connecté mais jamais « prête » (le repère de la page a disparu) : lecture cassée.
        lectureCassee = !ok && dernierEtat == .connecte
        occupe = false
        endormir()
        return r
    }

    var etat: Etat {
        guard let v = vue else { return dernierEtat }
        guard let h = v.url?.host?.lowercased() else { return .chargement }
        var e: Etat
        if h.contains("login.") || h.contains("microsoftonline") || h.contains("live.com") { e = .connexionRequise }
        else if let p = v.url?.path.lowercased(), p.hasPrefix("/connexion") || p.hasPrefix("/login") { e = .connexionRequise }
        else { e = hotes.contains(where: { h.hasSuffix($0) }) ? .connecte : .chargement }
        if e != .chargement { dernierEtat = e }
        return e
    }

    /// Fenêtre visible, pour se connecter (ou pour lire un mail).
    func afficher(pourConnexion: Bool = true) {
        self.pourConnexion = pourConnexion
        visible = true
        // Page « discrète » d'une lecture : on la recrée normale, pour qu'il l'utilise comme d'habitude.
        if vueDiscrete, let v = vue {
            v.stopLoading(); v.navigationDelegate = nil
            fenetre.contentView = nil
            vue = nil
        }
        reveiller()
        fenetre.alphaValue = 1
        fenetre.ignoresMouseEvents = false
        fenetre.level = .normal
        fenetre.center()
        fenetre.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Fenêtre « cachée » : transparente et inerte, mais affichée pour que la page vive pendant la lecture.
    func cacher() {
        visible = false
        fenetre.alphaValue = 0
        fenetre.ignoresMouseEvents = true
        if let s = NSScreen.main?.frame {
            fenetre.setFrame(NSRect(x: s.minX, y: s.minY, width: 1280, height: 860), display: false)
        }
        fenetre.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        fenetre.orderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cacher()
        if etat == .connecte { quandConnecte?() } else { endormir() }
        return false
    }

    /// Le compte de l'école : sur l'écran Microsoft « Choisir un compte », Rainette clique dessus toute seule
    /// (seulement sur ce compte-là, déjà connecté ; jamais de saisie de mot de passe).
    var compte: String?
    /// Ce que la dernière lecture a vu (pour le journal).
    var diagnostic = ""
    /// Résultats de la preuve « rien n'est marqué comme lu » (pour le journal).
    var preuves: [String] = []
    /// Nombre d'éléments reconnus lors de la dernière lecture (0 sur une page prête = lecture sans doute cassée).
    var lignesLues = 0

    private func choisirCompte() {
        guard let v = vue else { return }
        if let p = v.url?.path.lowercased(), p.hasPrefix("/connexion") {
            Task { _ = await js("document.querySelector('a[href*=\"login.microsoftonline.com\"]')?.click(); true") }
            return
        }
        guard let c = compte, let h = v.url?.host?.lowercased(), h.contains("login.microsoftonline") else { return }
        let code = """
        (() => {
          const c = \(String(reflecting: c)).toLowerCase();
          const tuile = document.querySelector('[data-test-id="' + c + '"]')
            || [...document.querySelectorAll('[role="button"], .table, .tile, button')]
                 .find(el => (el.innerText || '').toLowerCase().includes(c));
          if (tuile) { tuile.click(); return true; }
          return false;
        })()
        """
        Task {
            for _ in 0..<3 {
                if (await js(code) as? Bool) == true { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        choisirCompte()
        if visible, pourConnexion, etat == .connecte {
            // Connexion réussie : on laisse la page se charger puis on referme.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.visible, self.pourConnexion, self.etat == .connecte else { return }
                self.cacher()
                self.quandConnecte?()
            }
        }
    }

    func recharger() { vue?.load(URLRequest(url: adresse)) }

    func js(_ code: String) async -> Any? {
        guard let v = vue else { return nil }
        return try? await v.evaluateJavaScript(code)
    }

    // MARK: Lecture

    /// Outlook : les mails non lus de la boîte de réception, des dernières `heures`.
    /// La liste ne charge que ce qui est à l'écran : on la fait défiler jusqu'à des mails plus vieux que ça.
    func nonLusOutlook(compte: String, premierId: Int, heures: Int = 72) async -> [Mail] {
        let lire = """
        JSON.stringify([...document.querySelectorAll('[role="option"][data-convid]')].map(el => ({
          id: el.getAttribute('data-convid'),
          nonLu: (el.getAttribute('aria-label') || '').startsWith('Non lu'),
          lignes: el.innerText.split('\\n').map(s => s.trim()).filter(s => s) })))
        """
        let defiler = """
        (() => {
          let el = document.querySelector('[role="option"][data-convid]');
          while (el && !(el.scrollHeight > el.clientHeight + 10 && /auto|scroll/.test(getComputedStyle(el).overflowY))) el = el.parentElement;
          if (!el) return false;
          const avant = el.scrollTop;
          el.scrollTop += el.clientHeight * 0.9;
          return el.scrollTop > avant;
        })()
        """
        var vus = Set<String>()
        var res: [Mail] = []
        lignesLues = 0
        for _ in 0..<10 {
            guard let brut = await js(lire) as? String,
                  let liste = try? JSONSerialization.jsonObject(with: Data(brut.utf8)) as? [[String: Any]] else { break }
            var plusVieux = 0
            for o in liste {
                guard let id = o["id"] as? String, var l = o["lignes"] as? [String], l.count >= 3 else { continue }
                // Initiales de l'avatar, mention « Externe ».
                if let p = l.first, p.count <= 3, p == p.uppercased() { l.removeFirst() }
                if l.first == "Externe" { l.removeFirst() }
                guard let iDate = l.firstIndex(where: { PageWeb.age($0) != nil }), iDate >= 1,
                      let age = PageWeb.age(l[iDate]) else { continue }
                plusVieux = max(plusVieux, age)
                if vus.contains(id) { continue }
                vus.insert(id)
                lignesLues += 1
                guard o["nonLu"] as? Bool == true, age <= heures * 3600 else { continue }
                let sujet = l[1..<iDate].joined(separator: " ")
                    .replacingOccurrences(of: #"^\[\s*EXTERNE\s*\]\s*-?\s*"#, with: "", options: .regularExpression)
                let corps = l[(iDate + 1)...].joined(separator: "\n")
                    .replacingOccurrences(of: #"ATTENTION : Cet e-mail provient.*?(sûr|sure)\.\s*"#, with: "",
                                          options: .regularExpression)
                res.append(Mail(id: premierId + res.count, compte: compte, idMessage: "outlook:" + id,
                                expediteur: l[0], sujet: sujet.isEmpty ? "(sans objet)" : sujet, ilYa: age, corps: corps))
            }
            // Arrivé à des mails plus vieux que la limite, ou en bas de la liste : c'est fini.
            if plusVieux > heures * 3600 { break }
            guard (await js(defiler) as? Bool) == true else { break }
            try? await Task.sleep(for: .seconds(1))
        }
        return res
    }

    /// Groupes capturés si tout le texte correspond au motif (nil sinon ; groupe absent = "").
    static func groupes(_ t: String, _ motif: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: "^" + motif + "$"),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        return (1..<m.numberOfRanges).map { k in
            Range(m.range(at: k), in: t).map { String(t[$0]) } ?? ""
        }
    }

    /// Âge (en secondes) d'une date affichée par Outlook : « 12:48 », « Hier », « Lun 16/11 », « 16/11/2025 ».
    static func age(_ t: String) -> Int? {
        let cal = Calendar.current, maintenant = Date()
        func ecart(_ d: Date?) -> Int? { d.map { max(0, Int(maintenant.timeIntervalSince($0))) } }
        if let g = groupes(t, #"(\d{1,2}):(\d{2})"#),
           var d = cal.date(bySettingHour: Int(g[0])!, minute: Int(g[1])!, second: 0, of: maintenant) {
            // Une heure pas encore passée aujourd'hui, c'est la veille (juste après minuit).
            if d > maintenant { d = cal.date(byAdding: .day, value: -1, to: d) ?? d }
            return ecart(d)
        }
        if t.hasPrefix("Hier") { return ecart(cal.date(byAdding: .hour, value: -24, to: maintenant)) }
        // Jour de la semaine seul (« jeu. », « Mercredi », « mer. 14:05 ») : le plus récent passé.
        let jours = ["dim", "lun", "mar", "mer", "jeu", "ven", "sam"]
        let debut = String(t.lowercased().prefix(3))
        // Seulement de vrais noms de jours (abrégés ou complets) : « Martin » ou « Samuel » ne sont pas des dates.
        let motif = #"(?i)(?:dim(?:anche)?|lun(?:di)?|mar(?:di)?|mer(?:credi)?|jeu(?:di)?|ven(?:dredi)?|sam(?:edi)?)\.?(?:\s+\d{1,2}:\d{2})?"#
        if let j = jours.firstIndex(of: debut), PageWeb.groupes(t, motif) != nil {
            var d = cal.startOfDay(for: maintenant)
            for _ in 0..<7 where cal.component(.weekday, from: d) != j + 1 {
                d = cal.date(byAdding: .day, value: -1, to: d)!
            }
            if d == cal.startOfDay(for: maintenant) { d = cal.date(byAdding: .day, value: -7, to: d)! }
            return ecart(cal.date(byAdding: .hour, value: 12, to: d))
        }
        if let g = groupes(t, #"(?:\p{L}{3}\.?\s+)?(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?"#) {
            var c = cal.dateComponents([.year], from: maintenant)
            c.day = Int(g[0]); c.month = Int(g[1]); c.hour = 12
            if var an = Int(g[2]) { if an < 100 { an += 2000 }; c.year = an }
            guard var d = cal.date(from: c) else { return nil }
            if d > maintenant, g[2].isEmpty { d = cal.date(byAdding: .year, value: -1, to: d) ?? d }
            return ecart(d)
        }
        return nil
    }

    /// Outlook : ouvre la fenêtre sur ce mail.
    func ouvrirConversation(_ convid: String) {
        afficher(pourConnexion: false)
        let id = convid.replacingOccurrences(of: "\"", with: "")
        Task {
            _ = await attendrePret()
            _ = await js("document.querySelector('[data-convid=\"\(id)\"]')?.click(); true")
        }
    }

    /// Teams : le nombre de messages non lus, que Teams met dans le titre de la page (« (3) Conversation | … »).
    func nonLusTeams() async -> Int {
        guard let titre = await js("document.title") as? String,
              let g = PageWeb.groupes(titre, #"\((\d+)\).*"#) else { return 0 }
        return Int(g[0]) ?? 0
    }

    /// Teams : passe sur l'onglet « Conversation » (barre de gauche) s'il n'y est pas déjà.
    func allerAuxConversations() async {
        let code = """
        (() => {
          const b = [...document.querySelectorAll('button, [role="button"], [role="tab"]')]
            .find(el => /^(Conversation|Chat)\\b/i.test((el.getAttribute('aria-label') || el.innerText || '').trim()));
          if (b) { b.click(); return true; }
          return false;
        })()
        """
        _ = await js(code)
    }

    /// Teams : derniers messages des contacts suivis, lus dans la liste des conversations
    /// (on ne lit que l'aperçu : la conversation n'est pas ouverte, donc rien n'est marqué comme lu).
    func messagesTeams(de contacts: [String], premierId: Int, heures: Int = 72) async -> [Mail] {
        if visible { return [] }   // il s'en sert : on ne touche à rien
        await allerAuxConversations()
        // La liste des conversations met un moment à se remplir après l'ouverture de la page.
        for _ in 0..<10 {
            try? await Task.sleep(for: .seconds(1.5))
            let n = await js("[...document.querySelectorAll('[role=\"treeitem\"]')].filter(e => /\\d{1,2}[:/]\\d{2}/.test(e.innerText || '')).length") as? Int ?? 0
            if n >= 3 { break }
        }
        let code = """
        JSON.stringify([...document.querySelectorAll('[role="treeitem"]')]
          .map(el => (el.innerText || '').split('\\n').map(s => s.trim()).filter(s => s))
          .filter(l => l.length >= 3 && l.length <= 6))
        """
        guard let brut = await js(code) as? String,
              let listes = try? JSONSerialization.jsonObject(with: Data(brut.utf8)) as? [[String]] else { lignesLues = 0; return [] }
        lignesLues = listes.count
        func plier(_ t: String) -> String { t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil) }
        let vis = await js("document.visibilityState + (document.hasFocus() ? ' avec focus' : ' sans focus')") as? String ?? "?"
        let lus = await js("performance.getEntriesByType('resource').filter(r => /consumptionhorizon|readreceipt/i.test(r.name)).length") as? Int ?? -1
        diagnostic = "onglet vu \(vis), accusés de lecture passés : \(lus) · titre « \(await js("document.title") as? String ?? "?") », \(listes.count) conversations : "
            + listes.prefix(8).map { $0.prefix(3).joined(separator: " | ") }.joined(separator: " ; ")
        var res: [Mail] = []
        var vus = Set<String>()
        // Preuve de la lecture discrète : une conversation ouverte alors qu'elle était « Non lu »
        // doit l'être encore à la lecture suivante (la page est rechargée depuis les serveurs de Teams).
        var aVerifier = UserDefaults.standard.dictionary(forKey: "RainetteTeamsAVerifier") as? [String: Double] ?? [:]
        for var l in listes {
            let nonLu = l.first == "Non lu"
            if nonLu { l.removeFirst() }
            if let nom = l.first, aVerifier[nom] != nil {
                preuves.append(nonLu
                    ? "✅ \(nom) : toujours « non lu » après la lecture discrète, rien n'a été marqué comme lu"
                    : "ℹ️ \(nom) : plus « non lu » (lu ailleurs entre-temps, ou un accusé de lecture est passé)")
                aVerifier[nom] = nil
            }
            guard l.count >= 3, let age = PageWeb.age(l[1]), age <= heures * 3600 else { continue }
            let nom = l[0]
            let mots = Set(plier(nom).split(whereSeparator: { !$0.isLetter }).map(String.init))
            guard contacts.contains(where: { c in
                plier(c).split(separator: " ").allSatisfy { mots.contains(String($0)) }
            }), !vus.contains(nom) else { continue }
            let apercu = l[2...].joined(separator: " ")
            if apercu.hasPrefix("Vous") { continue }      // c'est lui qui a écrit en dernier
            vus.insert(nom)
            // Tous ses messages depuis ta dernière réponse (5 au plus), lus dans la conversation, en mode discret.
            var messages = await messagesDepuisTaReponse(de: nom)
            if messages.isEmpty { messages = [apercu] }
            if nonLu { aVerifier[nom] = Date().timeIntervalSince1970 }
            let n = messages.count
            res.append(Mail(id: premierId + res.count, compte: "Teams", idMessage: "teams:" + nom,
                            expediteur: nom,
                            sujet: (n > 1 ? "\(n) messages Teams" : "Message Teams") + (nonLu ? " (pas lu)" : ""),
                            ilYa: age, corps: messages.joined(separator: "\n")))
        }
        UserDefaults.standard.set(aVerifier, forKey: "RainetteTeamsAVerifier")
        return res
    }

    /// Ouvre la conversation de cette personne (page discrète) et renvoie ses messages envoyés
    /// depuis ton dernier message, dans l'ordre, 5 au plus.
    private func messagesDepuisTaReponse(de nom: String) async -> [String] {
        let ouvrir = """
        (() => { const n = \(String(reflecting: nom));
          const el = [...document.querySelectorAll('[role="treeitem"]')]
            .find(e => (e.innerText || '').split('\\n').map(s => s.trim()).includes(n));
          if (el) el.click(); return !!el; })()
        """
        guard (await js(ouvrir) as? Bool) == true else { return [] }
        // Les messages s'affichent quand le dernier bloc est signé de cette personne ou de toi.
        let lire = """
        (() => {
          let auteur = '';
          return JSON.stringify([...document.querySelectorAll('[data-tid="chat-pane-item"]')].map(it => {
            const a = it.querySelector('[data-tid="message-author-name"]');
            if (a) auteur = a.innerText.trim();
            const m = it.querySelector('[data-tid="chat-pane-message"]');
            return m ? { auteur, texte: m.innerText.trim() } : null;
          }).filter(x => x && x.texte));
        })()
        """
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            guard let brut = await js(lire) as? String,
                  let liste = try? JSONSerialization.jsonObject(with: Data(brut.utf8)) as? [[String: String]],
                  liste.contains(where: { $0["auteur"] == nom }) else { continue }
            var suite: [String] = []
            for m in liste.reversed() {
                guard m["auteur"] == nom else { break }      // on remonte jusqu'à ton dernier message
                if let t = m["texte"] { suite.insert(t, at: 0) }
            }
            return Array(suite.suffix(5))
        }
        return []
    }

    /// Teams : ouvre la fenêtre sur la conversation de cette personne.
    func ouvrirConversationTeams(_ nom: String) {
        afficher(pourConnexion: false)
        Task {
            _ = await attendrePret()
            await allerAuxConversations()
            try? await Task.sleep(for: .seconds(1))
            _ = await js("""
            (() => { const n = \(String(reflecting: nom));
              const el = [...document.querySelectorAll('[role="treeitem"]')]
                .find(e => (e.innerText || '').split('\\n').map(s => s.trim()).includes(n));
              if (el) el.click(); return !!el; })()
            """)
        }
    }
}
