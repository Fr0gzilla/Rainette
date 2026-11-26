// Le compte rendu : une fenêtre au centre de l'écran avec TOUT ce qu'il a reçu et pas encore traité,
// y compris ce que le widget n'affiche pas. Ouverte le matin (une fois par jour) et à la demande.
import AppKit
import EventKit
import SwiftUI

/// Fenêtre sans bord, au-dessus des autres. Elle ne se ferme QUE par lui : « C'est bon, j'ai vu », la croix ou Échap.
final class FenetreCompteRendu: NSWindow {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { CompteRendu.fermer() }
}

@MainActor
enum CompteRendu {
    private static var fenetre: FenetreCompteRendu?

    static func afficher(_ e: Etat) {
        fermer()
        let ecran = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let taille = NSSize(width: min(980, ecran.width - 80), height: min(760, ecran.height - 60))
        let w = FenetreCompteRendu(contentRect: NSRect(origin: .zero, size: taille),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = NSHostingView(rootView: VueCompteRendu(e: e))
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.level = .floating
        w.hidesOnDeactivate = false          // reste affichée même s'il passe à une autre app
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.setFrameOrigin(NSPoint(x: ecran.midX - taille.width / 2, y: ecran.midY - taille.height / 2))
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; w.animator().alphaValue = 1 }
        fenetre = w
    }

    static func fermer() {
        guard let w = fenetre else { return }
        fenetre = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; w.animator().alphaValue = 0 }) { w.orderOut(nil) }
    }
}

struct VueCompteRendu: View {
    @ObservedObject var e: Etat
    @State private var voirCaches = false

    private var cal: Calendar { .current }
    private var j0: Date { cal.startOfDay(for: Date()) }
    private var j1: Date { cal.date(byAdding: .day, value: 1, to: j0)! }
    private var j2: Date { cal.date(byAdding: .day, value: 2, to: j0)! }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            entete
            HStack(alignment: .top, spacing: 18) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        bloc("À faire", "checklist", e.aFaire.filter { !e.faits.contains($0) }.count) { aFaire }
                        bloc("Mails et messages importants", "envelope.fill", e.importants.count) { importants }
                        if e.teams != nil {
                            bloc("Teams", "bubble.left.and.bubble.right.fill", e.conversationsTeams.count) { teams }
                        }
                        bloc("Pas importants", "tray.full", e.mailsCaches().count) { caches }
                    }
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        bloc("Aujourd'hui", "calendar", nil) { agenda(e.aujourdhui, e.coursDu(j0, j1), vide: "Plus rien aujourd'hui.") }
                        bloc("Demain", "moon.stars.fill", nil) { agenda(e.demain, e.coursDu(j1, j2), vide: "Rien de calé demain.") }
                        bloc("Les 7 jours suivants", "calendar.badge.clock", nil) {
                            agenda(e.aVenir, e.coursDu(j2, cal.date(byAdding: .day, value: 7, to: j2)!),
                                   vide: "Rien de prévu.", avecJour: true)
                        }
                        if let m = e.mer { bloc("La mer", "water.waves", nil) { LignesMer(c: m) } }
                    }
                }
                .scrollIndicators(.never)
                .frame(width: 380)
            }
            HStack {
                Text("Échap pour fermer").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button { CompteRendu.fermer() } label: { Text("C'est bon, j'ai vu").frame(minWidth: 140) }
                    .buttonStyle(.borderedProminent).tint(or).keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                Verre()
                LinearGradient(colors: [Color(red: 0.16, green: 0.14, blue: 0.08).opacity(0.85), Color.black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(or.opacity(0.4), lineWidth: 1))
    }

    // MARK: En-tête

    private var entete: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(or.opacity(0.18))
                Circle().stroke(or.opacity(0.6), lineWidth: 1)
                Grenouille(style: .pleine, humeur: e.humeur).padding(7)
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text("LE POINT DU JOUR").font(.system(size: 11, weight: .heavy)).kerning(2).foregroundStyle(or)
                Text(Fmt.jourLong.string(from: Date()).capitalizedPremier).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(resume).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { CompteRendu.fermer() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help("Fermer (Échap)")
        }
    }

    /// Une phrase qui résume tout : ce qu'il y a à faire, les mails, les cours du jour.
    private var resume: String {
        let taches = e.aFaire.filter { !e.faits.contains($0) }.count
        let cours = e.coursDu(j0, j1).filter { !$0.annule }.count
        var morceaux: [String] = []
        morceaux.append(taches == 0 ? "rien à faire 🎉" : "\(taches) truc\(taches > 1 ? "s" : "") à faire")
        morceaux.append("\(e.importants.count) important\(e.importants.count > 1 ? "s" : "") sur \(e.mails.count) non lus")
        if e.teamsNonLus > 0 { morceaux.append("\(e.teamsNonLus) sur Teams") }
        if cours > 0 { morceaux.append("\(cours) cours aujourd'hui") }
        // Chaque chevauchement est compté deux fois (une fois de chaque côté) : on prend les évènements.
        let chevauchements = e.conflits.keys.filter { $0.hasPrefix("e:") }.count
        if chevauchements > 0 { morceaux.append("⚠️ \(chevauchements) chevauchement\(chevauchements > 1 ? "s" : "")") }
        return morceaux.joined(separator: " · ").capitalizedPremier
    }

    // MARK: Colonne de gauche

    @ViewBuilder private var aFaire: some View {
        let taches = e.aFaire
        if taches.isEmpty {
            Text("Rien à faire, t'es à jour 🎉").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(taches, id: \.self) { t in
                    let fait = e.faits.contains(t)
                    Button { withAnimation { e.cocher(t) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 9) {
                            Image(systemName: fait ? "checkmark.circle.fill" : "circle").foregroundStyle(or)
                            Text(t).strikethrough(fait, color: .secondary).foregroundStyle(fait ? .secondary : .primary)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var importants: some View {
        if e.importants.isEmpty {
            Text("Aucun mail important.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(e.importants) { r in
                    Button { r.mail.ouvrir() } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: r.mail.estTeams ? "bubble.left.and.bubble.right.fill"
                                  : (r.prioritaire ? "star.fill" : "circle.fill"))
                                .font(.system(size: r.prioritaire || r.mail.estTeams ? 11 : 6))
                                .foregroundStyle(r.prioritaire || r.mail.estTeams ? or : Color.secondary)
                                .frame(width: 14).padding(.top, r.prioritaire || r.mail.estTeams ? 3 : 6)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.mail.nom).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(depuis(r.mail.ilYa)).font(.system(size: 11)).foregroundStyle(.tertiary)
                                }
                                Text(r.resume).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if !r.mail.sujet.isEmpty, !r.mail.estTeams {
                                    Text(r.mail.sujet).font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Ouvrir")
                }

            }
        }
    }

    /// Les conversations Teams non lues, groupes compris : nom, dernier message, quand. Un clic l'ouvre dans Teams.
    @ViewBuilder private var teams: some View {
        if e.conversationsTeams.isEmpty {
            Text(e.teamsNonLus > 0
                 ? "\(e.teamsNonLus) notification\(e.teamsNonLus > 1 ? "s" : "") Teams, mais aucune conversation non lue dans la liste (sans doute des canaux ou des mentions)."
                 : "Rien de nouveau sur Teams.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(e.conversationsTeams) { c in
                    Button { e.teams?.ouvrirConversationTeams(c.nom) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: c.groupe ? "person.3.fill" : "person.fill")
                                .font(.system(size: 11)).foregroundStyle(c.groupe ? Color.secondary : or)
                                .frame(width: 18).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(c.nom).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                    if c.groupe { Text("groupe").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                                    Spacer(minLength: 6)
                                    if let a = c.ilYa { Text(depuis(a)).font(.system(size: 11)).foregroundStyle(.tertiary) }
                                }
                                Text(c.apercu.isEmpty ? "Nouveau message" : c.apercu).font(.system(size: 13)).foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Ouvrir dans Teams")
                }
                if e.teamsNonLus > e.conversationsTeams.count {
                    Button { e.teams?.afficher(pourConnexion: false) } label: {
                        Text("Teams compte \(e.teamsNonLus) non lus en tout (canaux, mentions…) — ouvrir Teams")
                            .font(.system(size: 12)).foregroundStyle(or)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder private var caches: some View {
        let liste = e.mailsCaches()
        if liste.isEmpty {
            Text("Rien de caché.").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                Button { withAnimation { voirCaches.toggle() } } label: {
                    HStack(spacing: 5) {
                        Text(voirCaches ? "Masquer la liste" : "Voir les \(liste.count) mails que j'ai jugés pas importants")
                        Image(systemName: voirCaches ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                if voirCaches {
                    ForEach(liste, id: \.idMessage) { m in
                        HStack(spacing: 8) {
                            Button { m.ouvrir() } label: {
                                HStack(spacing: 6) {
                                    Text(m.nom).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                        .frame(width: 150, alignment: .leading)
                                    Text(m.sujet).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("Ouvrir")
                            Button { withAnimation { e.remonter(m) } } label: {
                                Image(systemName: "arrow.up.circle").foregroundStyle(or)
                            }
                            .buttonStyle(.plain).help("C'est important : l'afficher")
                        }
                    }
                }
            }
        }
    }

    // MARK: Colonne de droite

    private enum Ligne: Identifiable {
        case ev(EKEvent), cours(Cours)
        var id: String {
            switch self { case .ev(let e): return "e" + (e.eventIdentifier ?? UUID().uuidString)
                          case .cours(let c): return "c" + c.id }
        }
        var debut: Date {
            switch self { case .ev(let e): return e.startDate; case .cours(let c): return c.debut }
        }
    }

    @ViewBuilder
    private func agenda(_ evs: [EKEvent], _ cours: [Cours], vide: String, avecJour: Bool = false) -> some View {
        let tout = (evs.map(Ligne.ev) + cours.map(Ligne.cours)).sorted { $0.debut < $1.debut }
        if tout.isEmpty {
            Text(vide).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(tout) { l in
                    HStack(alignment: .top, spacing: 9) {
                        switch l {
                        case .ev(let ev):
                            Capsule().fill(ev.calendar.map { Color(nsColor: $0.color) } ?? or).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ev.title ?? "(sans titre)").font(.system(size: 13.5, weight: .medium)).lineLimit(2)
                                Text(jour(ev.startDate, avecJour) + (ev.isAllDay ? "Toute la journée"
                                     : "\(Fmt.heure.string(from: ev.startDate)) – \(Fmt.heure.string(from: ev.endDate))")
                                     + ((ev.location ?? "").isEmpty ? "" : " · \(ev.location!)"))
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                if let c = e.conflit(ev) {
                                    Text("⚠️ en même temps que \(c)").font(.system(size: 11.5)).foregroundStyle(.orange)
                                }
                            }
                        case .cours(let k):
                            Capsule().fill(k.annule ? Color.secondary : or).frame(width: 4, height: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("🎓 \(k.matiere)").font(.system(size: 13.5, weight: .medium))
                                    .strikethrough(k.annule, color: .secondary).lineLimit(1)
                                Text(jour(k.debut, avecJour) + "\(Fmt.heure.string(from: k.debut))–\(Fmt.heure.string(from: k.fin))"
                                     + (k.annule ? " · annulé" : k.distanciel ? " · à distance" : k.salle.map { " · \($0)" } ?? ""))
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                                if let c = e.conflit(k) {
                                    Text("⚠️ en même temps que \(c)").font(.system(size: 11.5)).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func jour(_ d: Date, _ avec: Bool) -> String {
        avec ? Fmt.jourCourt.string(from: d).capitalizedPremier + " · " : ""
    }

    // MARK: Outils

    private func bloc<C: View>(_ titre: String, _ icone: String, _ compte: Int?, @ViewBuilder _ contenu: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icone).font(.system(size: 12, weight: .semibold)).foregroundStyle(or)
                Text(titre.uppercased()).font(.system(size: 11.5, weight: .bold)).kerning(1.2).foregroundStyle(or)
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

    private func depuis(_ s: Int) -> String {
        if s < 3600 { return "\(max(1, s / 60)) min" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) j"
    }
}
