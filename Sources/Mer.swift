// Conditions en mer pour deux spots choisis dans les réglages : un pour naviguer (catamaran, voile), un pour surfer.
// Données gratuites et sans clé : Open-Meteo (vent) et Open-Meteo Marine (vagues, houle, eau).
import SwiftUI

enum Mer {
    struct Heure: Sendable {
        let date: Date
        let vent: Double, rafales: Double, dirVent: Double   // nœuds, degrés (d'où il vient)
        let vague: Double?                                    // hauteur des vagues (m)
        let houle: Double?, periode: Double?, dirHoule: Double?
        let eau: Double?
    }

    enum Avis: Int, Sendable { case mauvais, moyen, bon }

    struct Conditions: Sendable {
        let navigation: [Heure]?
        let surf: [Heure]?
    }

    /// Spots pris dans les réglages ([latitude, longitude] pour le vent, puis pour la houle).
    static var spots: (navigation: Reglages.Spot?, surf: Reglages.Spot?) {
        (Reglages.actuels.mer?.navigation, Reglages.actuels.mer?.surf)
    }
    static var active: Bool { spots.navigation != nil || spots.surf != nil }

    private static func point(_ p: [Double]) -> (Double, Double)? { p.count == 2 ? (p[0], p[1]) : nil }

    private static func heures(_ s: Reglages.Spot?) async throws -> [Heure]? {
        guard let s, let pv = point(s.vent), let pm = point(s.mer) else { return nil }
        async let v = vent(pv)
        async let m = mer(pm)
        return fusion(try await v, try await m)
    }

    static func charger() async throws -> Conditions {
        async let n = heures(spots.navigation)
        async let s = heures(spots.surf)
        return Conditions(navigation: try await n, surf: try await s)
    }

    private typealias Series = (temps: [Double], valeurs: [String: [Double?]])

    private static func lire(_ url: String) async throws -> Series {
        var req = URLRequest(url: URL(string: url)!)
        req.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let h = json["hourly"] as? [String: Any] ?? [:]
        let temps = (h["time"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.doubleValue }
        var valeurs: [String: [Double?]] = [:]
        for (k, v) in h where k != "time" {
            valeurs[k] = (v as? [Any] ?? []).map { ($0 as? NSNumber)?.doubleValue }
        }
        return (temps, valeurs)
    }

    private static func vent(_ p: (Double, Double)) async throws -> Series {
        try await lire("https://api.open-meteo.com/v1/forecast?latitude=\(p.0)&longitude=\(p.1)"
            + "&hourly=wind_speed_10m,wind_direction_10m,wind_gusts_10m&wind_speed_unit=kn"
            + "&timeformat=unixtime&forecast_days=3")
    }

    private static func mer(_ p: (Double, Double)) async throws -> Series {
        try await lire("https://marine-api.open-meteo.com/v1/marine?latitude=\(p.0)&longitude=\(p.1)"
            + "&hourly=wave_height,swell_wave_height,swell_wave_period,swell_wave_direction,sea_surface_temperature"
            + "&timeformat=unixtime&forecast_days=3")
    }

    private static func fusion(_ v: Series, _ m: Series) -> [Heure] {
        var indexMer: [Double: Int] = [:]
        for (i, t) in m.temps.enumerated() { indexMer[t] = i }
        func val(_ s: Series, _ k: String, _ i: Int?) -> Double? {
            guard let i, let a = s.valeurs[k], i < a.count else { return nil }
            return a[i]
        }
        return v.temps.enumerated().compactMap { i, t in
            guard let vt = val(v, "wind_speed_10m", i), let dv = val(v, "wind_direction_10m", i) else { return nil }
            let j = indexMer[t]
            return Heure(date: Date(timeIntervalSince1970: t), vent: vt,
                         rafales: val(v, "wind_gusts_10m", i) ?? vt, dirVent: dv,
                         vague: val(m, "wave_height", j), houle: val(m, "swell_wave_height", j),
                         periode: val(m, "swell_wave_period", j), dirHoule: val(m, "swell_wave_direction", j),
                         eau: val(m, "sea_surface_temperature", j))
        }
    }

    // MARK: Avis

    /// Catamaran de sport, pilote confirmé : on cherche du vent. Idéal 10 à 25 nœuds ;
    /// moins de 6 c'est la pétole, plus de 25 (rafales 30) c'est engagé, plus de 30 (rafales 36) trop fort.
    /// Spot supposé abrité (baie) : la houle du modèle (celle du large) ne compte pas dans l'avis.
    static func avisNavigation(_ h: Heure) -> (Avis, String) {
        if h.vent > 30 || h.rafales > 36 { return (.mauvais, "Trop fort") }
        if h.vent < 6 { return (.mauvais, "Pétole") }
        if h.vent > 25 || h.rafales > 30 { return (.moyen, "Engagé") }
        if h.vent < 10 { return (.moyen, "Léger") }
        return (.bon, "Top")
    }
    /// Pour le meilleur créneau : à avis égal, le vent le plus proche de 17 nœuds.
    static func noteNavigation(_ h: Heure) -> Double {
        Double(avisNavigation(h).0.rawValue) * 100 - abs(h.vent - 17)
    }

    /// Surfeur débutant sur un spot exposé à l'ouest : houle de 0,5 à 1,5 m, peu de vent ou vent de terre (secteur est).
    /// Au-delà de 2 m c'est trop gros ; un vent de mer fort hache les vagues.
    static func avisSurf(_ h: Heure) -> (Avis, String) {
        guard let houle = h.houle ?? h.vague else { return (.mauvais, "Inconnu") }
        if houle < 0.5 { return (.mauvais, "Plat") }
        if houle > 2 { return (.mauvais, "Trop gros") }
        if deMer(h) && h.vent > 18 { return (.mauvais, "Haché") }
        if houle > 1.5 { return (.moyen, "Gros pour toi") }
        if deMer(h) && h.vent > 12 { return (.moyen, "Haché") }
        if h.vent > 18 { return (.moyen, "Venté") }
        return (.bon, "Bon")
    }
    /// Pour le meilleur créneau : à avis égal, une houle proche d'1 m et le moins de vent possible.
    static func noteSurf(_ h: Heure) -> Double {
        Double(avisSurf(h).0.rawValue) * 100 - abs((h.houle ?? h.vague ?? 0) - 1) * 20 - (deTerre(h) ? 0 : h.vent)
    }

    static func deTerre(_ h: Heure) -> Bool { (20...140).contains(h.dirVent) }
    static func deMer(_ h: Heure) -> Bool { (200...320).contains(h.dirVent) }

    /// L'heure actuelle et le meilleur créneau de jour (9 h – 17 h) des 36 prochaines heures.
    static func maintenant(_ hs: [Heure]) -> Heure? {
        let n = Date()
        return hs.last { $0.date <= n } ?? hs.first
    }

    static func meilleur(_ hs: [Heure], note: (Heure) -> Double) -> Heure? {
        let n = Date().addingTimeInterval(-1800), fin = n.addingTimeInterval(36 * 3600)
        let jour = hs.filter { h in
            let hr = Calendar.current.component(.hour, from: h.date)
            return h.date >= n && h.date <= fin && (9...17).contains(hr)
        }
        return jour.max { note($0) < note($1) }
    }

    // MARK: Textes

    static func cap(_ d: Double) -> String {
        let p = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]
        return p[Int((d / 22.5).rounded()) % 16]
    }

    static func m(_ x: Double) -> String { String(format: "%.1f", x).replacingOccurrences(of: ".", with: ",") + " m" }

    static func quand(_ d: Date) -> String {
        let cal = Calendar.current
        let jour = cal.isDateInToday(d) ? "aujourd'hui" : cal.isDateInTomorrow(d) ? "demain" : "après-demain"
        return "\(jour) \(cal.component(.hour, from: d)) h"
    }

    static func texteNavigation(_ h: Heure) -> String {
        var t = "Vent \(Int(h.vent.rounded())) nds \(cap(h.dirVent)), rafales \(Int(h.rafales.rounded()))"
        if let v = h.vague { t += " · houle au large \(m(v))" }
        return t
    }

    static func texteSurf(_ h: Heure) -> String {
        var t = ""
        if let s = h.houle ?? h.vague {
            t = "Houle \(m(s))"
            if let p = h.periode { t += " · \(Int(p.rounded())) s" }
            if let d = h.dirHoule { t += " \(cap(d))" }
            t += " · "
        }
        t += "vent \(Int(h.vent.rounded())) nds \(cap(h.dirVent))"
        if deTerre(h) { t += " (de terre)" } else if deMer(h) { t += " (de mer)" }
        if let e = h.eau { t += " · eau \(Int(e.rounded())) °C" }
        return t
    }
}

/// Les conditions en mer, en texte simple sous la date (sans cadre).
struct LignesMer: View {
    let c: Mer.Conditions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let n = c.navigation { ligne("⛵ Catamaran", n, avis: Mer.avisNavigation, note: Mer.noteNavigation) { h in
                "\(Int(h.vent.rounded())) nds \(Mer.cap(h.dirVent)), rafales \(Int(h.rafales.rounded()))"
            } }
            if let s = c.surf { ligne("🏄 Surf", s, avis: Mer.avisSurf, note: Mer.noteSurf) { h in
                var t = (h.houle ?? h.vague).map { "houle \(Mer.m($0))" } ?? ""
                if let p = h.periode { t += " · \(Int(p.rounded())) s" }
                return t
            } }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

    private func ligne(_ titre: String, _ hs: [Mer.Heure], avis: (Mer.Heure) -> (Mer.Avis, String),
                       note: (Mer.Heure) -> Double, detail: (Mer.Heure) -> String) -> Text {
        guard let h = Mer.maintenant(hs) else { return Text("") }
        let (a, mot) = avis(h)
        var t = Text("\(titre) ").foregroundStyle(.secondary)
            + Text(mot).fontWeight(.semibold).foregroundStyle(Mer.couleur(a))
            + Text(" · \(detail(h))").foregroundStyle(.secondary)
        if a != .bon, let b = Mer.meilleur(hs, note: note), avis(b).0.rawValue > a.rawValue {
            t = t + Text(" · mieux \(Mer.quand(b.date))").foregroundStyle(.tertiary)
        }
        return t
    }
}

extension Mer {
    static func couleur(_ a: Avis) -> Color {
        a == .bon ? .green : a == .moyen ? or : Color(red: 0.95, green: 0.42, blue: 0.36)
    }
}
