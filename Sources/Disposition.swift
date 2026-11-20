// Disposition du widget : où il se place, comment on le déplace / redimensionne (mode « Modifier »),
// l'aimantation aux bords de l'écran et aux widgets Apple, et la mémorisation de son cadre.
import AppKit
import SwiftUI

@MainActor weak var fenetreWidget: FenetreBureau?

enum Disposition {
    static let marge: CGFloat = 16          // écart entre widgets et avec les bords, comme macOS
    static let aimant: CGFloat = 24         // distance à laquelle un bord est attiré
    static let tailleMin = NSSize(width: 340, height: 280)
    private static let cle = "RainetteCadre"

    // MARK: Widgets Apple

    /// Les widgets Apple posés sur le bureau, en coordonnées AppKit (origine en bas à gauche).
    /// Ce sont des fenêtres du Centre de notifications, avec 8 pt de marge autour du contenu visible.
    static func widgetsApple(_ ecran: NSScreen) -> [NSRect] {
        let infos = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let h = ecran.frame.maxY
        return infos.compactMap { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Centre de notifications"
                    || (w[kCGWindowOwnerName as String] as? String) == "Notification Center",
                  let d = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: d as CFDictionary),
                  b.width < ecran.frame.width * 0.9 else { return nil }
            return NSRect(x: b.minX, y: h - b.maxY, width: b.width, height: b.height).insetBy(dx: 8, dy: 8)
        }
    }

    // MARK: Cadre

    /// Par défaut : à droite des widgets Apple, du haut jusqu'au-dessus du Dock.
    static func cadreParDefaut(_ ecran: NSScreen) -> NSRect {
        let v = ecran.visibleFrame
        let droite = v.maxX - marge
        var gauche = droite - 440
        if let bord = widgetsApple(ecran).map(\.maxX).max(), droite - (bord + marge) >= tailleMin.width {
            gauche = bord + marge
        }
        return NSRect(x: gauche, y: v.minY + marge, width: droite - gauche, height: v.height - 2 * marge)
    }

    static func cadre(_ ecran: NSScreen) -> NSRect {
        if let s = UserDefaults.standard.string(forKey: cle) {
            let r = NSRectFromString(s)
            if r.width >= tailleMin.width, r.height >= tailleMin.height { return dansLEcran(r, ecran) }
        }
        return cadreParDefaut(ecran)
    }

    static func memoriser(_ r: NSRect) { UserDefaults.standard.set(NSStringFromRect(r), forKey: cle) }
    static func oublier() { UserDefaults.standard.removeObject(forKey: cle) }

    /// Garde le widget entier dans la zone visible (ni sous la barre des menus, ni sous le Dock).
    static func dansLEcran(_ r: NSRect, _ ecran: NSScreen) -> NSRect {
        let v = ecran.visibleFrame
        var r = r
        r.size.width = min(max(r.width, tailleMin.width), v.width)
        r.size.height = min(max(r.height, tailleMin.height), v.height)
        r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
        r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
        return r
    }

    // MARK: Aimantation

    enum Geste { case deplacer, redimensionner(gauche: Bool, haut: Bool) }

    static func aimanter(_ r: NSRect, _ geste: Geste, _ ecran: NSScreen) -> NSRect {
        let v = ecran.visibleFrame
        let ws = widgetsApple(ecran)
        let gauches = [v.minX + marge] + ws.flatMap { [$0.maxX + marge, $0.minX] }
        let droites = [v.maxX - marge] + ws.flatMap { [$0.minX - marge, $0.maxX] }
        let hauts = [v.maxY - marge] + ws.flatMap { [$0.minY - marge, $0.maxY] }
        let bas = [v.minY + marge] + ws.flatMap { [$0.maxY + marge, $0.minY] }
        func proche(_ x: CGFloat, _ cs: [CGFloat]) -> CGFloat? {
            cs.map { $0 - x }.filter { abs($0) <= aimant }.min { abs($0) < abs($1) }
        }
        func meilleur(_ a: CGFloat?, _ b: CGFloat?) -> CGFloat {
            [a, b].compactMap { $0 }.min { abs($0) < abs($1) } ?? 0
        }
        var r = r
        switch geste {
        case .deplacer:
            r.origin.x += meilleur(proche(r.minX, gauches), proche(r.maxX, droites))
            r.origin.y += meilleur(proche(r.minY, bas), proche(r.maxY, hauts))
        case .redimensionner(let g, let h):
            if g, let d = proche(r.minX, gauches) { r.origin.x += d; r.size.width -= d }
            if !g, let d = proche(r.maxX, droites) { r.size.width += d }
            if h, let d = proche(r.maxY, hauts) { r.size.height += d }
            if !h, let d = proche(r.minY, bas) { r.origin.y += d; r.size.height -= d }
        }
        return dansLEcran(r, ecran)
    }
}

/// Calque du mode « Modifier » : on glisse pour déplacer, on tire les coins pour redimensionner.
struct CalqueEdition: View {
    @ObservedObject var e: Etat
    @State private var depart: (cadre: NSRect, souris: NSPoint)?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.45))
                .contentShape(Rectangle())
                .gesture(glisser(.deplacer))
            VStack(spacing: 12) {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(or)
                Text("Glisse-moi où tu veux.\nTire un coin pour changer ma taille.")
                    .multilineTextAlignment(.center).font(.system(size: 14)).foregroundStyle(.white.opacity(0.9))
                HStack(spacing: 10) {
                    Button("Remets-moi à ma place") { e.dispositionParDefaut() }.buttonStyle(.bordered)
                    Button("C'est bon") { e.edition = false }
                        .buttonStyle(.borderedProminent).tint(or).keyboardShortcut(.defaultAction)
                }
            }
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(or, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .allowsHitTesting(false)
            VStack {
                HStack { poignee(gauche: true, haut: true); Spacer(); poignee(gauche: false, haut: true) }
                Spacer()
                HStack { poignee(gauche: true, haut: false); Spacer(); poignee(gauche: false, haut: false) }
            }
            .padding(4)
        }
    }

    private func poignee(gauche: Bool, haut: Bool) -> some View {
        Circle().fill(or).frame(width: 18, height: 18)
            .overlay(Circle().stroke(Color.black.opacity(0.5), lineWidth: 1))
            .padding(6).contentShape(Rectangle())
            .gesture(glisser(.redimensionner(gauche: gauche, haut: haut)))
    }

    /// On suit la souris à l'écran (et non dans la vue, qui bouge avec la fenêtre).
    private func glisser(_ geste: Disposition.Geste) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in
                guard let w = fenetreWidget else { return }
                let souris = NSEvent.mouseLocation
                if depart == nil { depart = (w.frame, souris) }
                guard let d = depart else { return }
                let dx = souris.x - d.souris.x, dy = souris.y - d.souris.y
                var r = d.cadre
                switch geste {
                case .deplacer:
                    r.origin.x += dx; r.origin.y += dy
                case .redimensionner(let g, let h):
                    if g { r.origin.x += dx; r.size.width -= dx } else { r.size.width += dx }
                    if h { r.size.height += dy } else { r.origin.y += dy; r.size.height -= dy }
                    // Taille minimale : le bord opposé ne bouge pas.
                    if r.width < Disposition.tailleMin.width {
                        if g { r.origin.x = r.maxX - Disposition.tailleMin.width }
                        r.size.width = Disposition.tailleMin.width
                    }
                    if r.height < Disposition.tailleMin.height {
                        if !h { r.origin.y = r.maxY - Disposition.tailleMin.height }
                        r.size.height = Disposition.tailleMin.height
                    }
                }
                w.setFrame(r, display: true)
            }
            .onEnded { _ in
                depart = nil
                guard let w = fenetreWidget, let ecran = w.screen ?? NSScreen.main else { return }
                let r = Disposition.aimanter(w.frame, geste, ecran)
                w.setFrame(r, display: true, animate: true)
                Disposition.memoriser(r)
                w.gardien?.verifier()
            }
    }
}
