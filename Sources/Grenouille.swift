// La grenouille de Rainette, dessinée dans le code (nette à toutes les tailles), avec ses humeurs.
import SwiftUI

struct Grenouille: View {
    enum Style: CaseIterable { case trait, pleine, minimale }
    enum Humeur: CaseIterable { case normale, cligne, dort, pluie, contente }

    var style: Style = .trait
    var humeur: Humeur = .normale

    private let vert = Color(red: 0.42, green: 0.70, blue: 0.36)
    private let vertFonce = Color(red: 0.20, green: 0.42, blue: 0.20)
    private let rose = Color(red: 0.95, green: 0.55, blue: 0.55)

    var body: some View {
        Canvas { ctx, taille in
            let s = min(taille.width, taille.height)
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            func rond(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: (x - r) * s, y: (y - r) * s, width: 2 * r * s, height: 2 * r * s))
            }

            // Sous la pluie : un parapluie au-dessus, la grenouille un peu plus bas et plus petite.
            var c = ctx
            if humeur == .pluie {
                dessinerParapluie(ctx, s: s, p: p)
                c.translateBy(x: s * 0.09, y: s * 0.17)
                c.scaleBy(x: 0.82, y: 0.82)
            }

            let trait = s * 0.034
            let yeuxFermes = humeur == .cligne || humeur == .dort
            let contente = humeur == .contente

            // Tête et yeux
            let tete = Path(ellipseIn: CGRect(x: 0.19 * s, y: 0.40 * s, width: 0.62 * s, height: 0.40 * s))
            let oeilG = rond(0.34, 0.40, 0.125), oeilD = rond(0.66, 0.40, 0.125)
            switch style {
            case .trait:
                // Remplissage opaque (couleur du fond du widget) : les yeux sont posés sur la tête,
                // sans que les contours se croisent.
                let fond = Color(red: 0.20, green: 0.18, blue: 0.11)
                for f in [tete, oeilG, oeilD] {
                    c.fill(f, with: .color(fond))
                    c.fill(f, with: .color(or.opacity(0.16)))
                    c.stroke(f, with: .color(or), lineWidth: trait)
                }
            case .pleine:
                for f in [oeilG, oeilD, tete] {
                    c.fill(f, with: .color(vert))
                    c.stroke(f, with: .color(vertFonce), lineWidth: trait * 0.8)
                }
                // le contour des yeux passe derrière la tête : on la remplit à nouveau
                c.fill(tete, with: .color(vert))
                c.stroke(tete, with: .color(vertFonce), lineWidth: trait * 0.8)
                c.fill(rond(0.29, 0.63, 0.045), with: .color(rose.opacity(0.7)))
                c.fill(rond(0.71, 0.63, 0.045), with: .color(rose.opacity(0.7)))
            case .minimale:
                break
            }

            // Pupilles, ou yeux fermés
            let couleurOeil: Color = style == .pleine ? vertFonce : or
            for x in [0.34, 0.66] as [CGFloat] {
                if yeuxFermes {
                    var f = Path()
                    f.move(to: p(x - 0.065, 0.405))
                    f.addQuadCurve(to: p(x + 0.065, 0.405), control: p(x, humeur == .dort ? 0.45 : 0.43))
                    c.stroke(f, with: .color(couleurOeil), style: StrokeStyle(lineWidth: trait, lineCap: .round))
                } else if contente {
                    var f = Path()               // yeux rieurs « ^ ^ »
                    f.move(to: p(x - 0.06, 0.43))
                    f.addQuadCurve(to: p(x + 0.06, 0.43), control: p(x, 0.34))
                    c.stroke(f, with: .color(couleurOeil), style: StrokeStyle(lineWidth: trait, lineCap: .round))
                } else {
                    if style == .pleine { c.fill(rond(x, 0.40, 0.085), with: .color(.white)) }
                    if style == .minimale { c.stroke(rond(x, 0.40, 0.1), with: .color(or), lineWidth: trait) }
                    c.fill(rond(x + 0.01, 0.41, style == .pleine ? 0.045 : 0.05),
                           with: .color(style == .pleine ? .black.opacity(0.85) : couleurOeil))
                }
            }

            // Bouche
            var bouche = Path()
            bouche.move(to: p(0.37, 0.60))
            bouche.addQuadCurve(to: p(0.63, 0.60), control: p(0.5, contente ? 0.76 : (humeur == .dort ? 0.64 : 0.69)))
            let couleurBouche: Color = style == .pleine ? vertFonce : or
            if contente {
                var pleine = bouche
                pleine.closeSubpath()
                c.fill(pleine, with: .color(style == .pleine ? rose : or.opacity(0.35)))
            }
            c.stroke(bouche, with: .color(couleurBouche), style: StrokeStyle(lineWidth: trait, lineCap: .round))

            // La nuit : des « z »
            if humeur == .dort {
                for (i, (x, y, t)) in [(0.86, 0.24, 0.12), (0.94, 0.11, 0.09)].enumerated() {
                    c.draw(Text(i == 0 ? "z" : "Z").font(.system(size: s * t, weight: .bold, design: .rounded))
                        .foregroundColor(or.opacity(0.9)), at: p(x, y))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func dessinerParapluie(_ ctx: GraphicsContext, s: CGFloat, p: (CGFloat, CGFloat) -> CGPoint) {
        var toile = Path()
        toile.move(to: p(0.12, 0.30))
        toile.addQuadCurve(to: p(0.88, 0.30), control: p(0.5, -0.06))
        // bord festonné
        toile.addQuadCurve(to: p(0.69, 0.30), control: p(0.785, 0.24))
        toile.addQuadCurve(to: p(0.50, 0.30), control: p(0.595, 0.24))
        toile.addQuadCurve(to: p(0.31, 0.30), control: p(0.405, 0.24))
        toile.addQuadCurve(to: p(0.12, 0.30), control: p(0.215, 0.24))
        ctx.fill(toile, with: .color(or.opacity(0.85)))
        var manche = Path()
        manche.move(to: p(0.5, 0.14))
        manche.addLine(to: p(0.5, 0.40))
        ctx.stroke(manche, with: .color(or), style: StrokeStyle(lineWidth: s * 0.03, lineCap: .round))
        // gouttes
        for (x, y) in [(0.10, 0.45), (0.90, 0.50), (0.06, 0.70), (0.93, 0.78)] as [(CGFloat, CGFloat)] {
            var g = Path()
            g.move(to: p(x, y))
            g.addLine(to: p(x - 0.02, y + 0.07))
            ctx.stroke(g, with: .color(Color(red: 0.55, green: 0.75, blue: 0.95).opacity(0.8)),
                       style: StrokeStyle(lineWidth: s * 0.022, lineCap: .round))
        }
    }
}
