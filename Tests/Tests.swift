// Tests des règles fragiles de Rainette (dates, Teams, JSON du modèle, tri, cours, mer).
// Lancer : ./tests.sh  — compile ce fichier avec les sources testables, sans l'interface.
import Foundation
import SwiftUI

let or = Color.yellow   // couleur du widget, utilisée par Mer.swift

var reussis = 0, rates = 0
func verifie(_ ok: Bool, _ nom: String, _ detail: @autoclosure () -> String = "") {
    if ok { reussis += 1 } else { rates += 1; print("❌ \(nom) \(detail())") }
}

let cal = Calendar.current
func date(_ t: String) -> Date {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: t)!
}
func texte(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: d)
}

@main enum Tests {
    static func main() {
        MainActor.assumeIsolated { lancer() }
        print(rates == 0 ? "✅ \(reussis) tests réussis" : "\(rates) test(s) raté(s), \(reussis) réussis")
        exit(rates == 0 ? 0 : 1)
    }

    @MainActor static func lancer() {
        // MARK: Dates d'évènements (maintenant = jeudi 26 novembre 2026, 13 h)
        let jeudi = date("2026-11-26 13:00")
        func recale(_ d: String, _ msg: String, journee: Bool = false, corriger: Bool = true) -> String {
            texte(Dates.recaler(date(d), journee: journee, message: msg, corrigerJour: corriger, maintenant: jeudi))
        }
        verifie(recale("2026-12-02 09:00", "ajoute lundi prochain de 9h a 13h rdv avec Studio Nova") == "2026-11-30 09:00",
                "lundi mal compris → recalé au lundi 30", recale("2026-12-02 09:00", "ajoute lundi prochain de 9h"))
        verifie(recale("2026-12-02 10:30", "rajoute dentiste mardi prochain à 10h30") == "2026-12-01 10:30",
                "mardi prochain → mardi 1er décembre")
        verifie(recale("2026-09-17 00:00", "mets l'anniv de léa le 17 septembre", journee: true) == "2027-09-17 00:00",
                "date passée → l'an prochain")
        verifie(recale("2026-12-03 18:00", "ajoute foot jeudi 18h") == "2026-12-03 18:00",
                "bon jour de semaine → inchangé")
        verifie(recale("2026-11-26 14:30", "ajoute rdv école aujourd'hui 14h30 et lundi studio nova") == "2026-11-26 14:30",
                "« aujourd'hui » → jamais recalé")
        verifie(recale("2026-12-02 09:00", "lundi et mardi j'ai des rdv") == "2026-12-02 09:00",
                "deux jours cités → pas de recalage")
        verifie(recale("2026-12-02 09:00", "ajoute rdv lundi", corriger: false) == "2026-12-02 09:00",
                "plusieurs évènements dans le tour → pas de recalage")
        verifie(recale("2026-11-26 10:00", "ajoute réunion jeudi 10h") == "2026-11-26 10:00",
                "même jour déjà juste → inchangé")
        verifie(recale("2026-11-27 10:00", "réunion mardi 10h") == "2026-12-01 10:00",
                "vendredi proposé pour « mardi » → mardi suivant")

        // MARK: Dates affichées par Outlook / Teams
        let hier = PageWeb.age("Hier") ?? -1
        verifie((23 * 3600...25 * 3600).contains(hier), "« Hier » ≈ 24 h", "\(hier)")
        for t in ["jeu.", "Mercredi", "mer. 14:05", "lun", "Lun 16/11"] {
            let a = PageWeb.age(t) ?? -1
            verifie(a >= 0 && (t.contains("/") || a <= 8 * 86400), "« \(t) » reconnu comme une date récente", "\(a)")
        }
        verifie((PageWeb.age("16/11/2025") ?? 0) > 300 * 86400, "date avec année")
        for t in ["Martin", "Samuel", "Léa BERNARD", "Alex DURAND", "[ EXTERNE ] -"] {
            verifie(PageWeb.age(t) == nil, "« \(t) » n'est pas une date")
        }
        verifie((PageWeb.age("12:48") ?? -1) >= 0, "heure seule jamais négative")

        // MARK: Teams : groupes et personnes
        for g in ["Alex: Tout le monde pour ceux qui sont intéressés", "LEROY Julie: La correction du TP", "SIMON Marc: Réel"] {
            verifie(PageWeb.estGroupe(apercu: g), "groupe reconnu : \(g)")
        }
        for p in ["ça marche, tu as proposé quelle date ?", "Rdv : demain 10h", "Nouveau message"] {
            verifie(!PageWeb.estGroupe(apercu: p), "message privé : \(p)")
        }
        for n in ["Alex DURAND", "PETIT Sam", "Jean-Pierre Martin"] { verifie(PageWeb.ressembleAPersonne(n), "personne : \(n)") }
        for n in ["TEAM PROJET 2026 🚀", "D43 BACKEND", "Entretien Alternance - Camille Martin", "Délégués"] {
            verifie(!PageWeb.ressembleAPersonne(n), "pas une personne : \(n)")
        }

        // MARK: JSON du modèle
        let tronque = Ollama.objetJSON(#"{"mails": [{"id": 1, "categorie": "inutile"}]"#)
        verifie((tronque?["mails"] as? [[String: Any]])?.count == 1, "JSON sans accolade finale réparé")
        verifie((Ollama.objetJSON(#"voilà {"a": [1,2], "b": "x}y"} fin"#)?["b"] as? String) == "x}y",
                "accolade dans un texte ignorée")
        verifie((Ollama.objetJSON(#"{"m": [{"r": "coupé"#)?["m"] as? [[String: Any]])?.first?["r"] as? String == "coupé",
                "texte coupé refermé")
        verifie(Ollama.objetJSON("pas de json") == nil, "pas de JSON → nil")

        // MARK: Tri des mails
        verifie(Resumeur.sansId("Confirme ta présence (mail id 13).") == "Confirme ta présence.", "« (mail id 13) » retiré")
        verifie(Resumeur.sansId("Regarde l'offre dans le mail id 20.") == "Regarde l'offre.", "« dans le mail id 20 » retiré")
        for r in ["Rappel sur la garantie des dépôts, rien d'urgent ni d'actionnable pour toi.",
                  "Une offre de Dev Senior ne te correspond pas.", "Contrat signé, rien à faire.",
                  "Offre pas compatible avec ton profil."] {
            verifie(r.range(of: Resumeur.motifInutile, options: [.regularExpression, .caseInsensitive]) != nil, "caché : \(r)")
        }
        for r in ["Ils t'invitent à un entretien mardi 10h, faut confirmer.", "Ta banque te demande des infos, faut répondre vite."] {
            verifie(r.range(of: Resumeur.motifInutile, options: [.regularExpression, .caseInsensitive]) == nil, "gardé : \(r)")
        }

        // MARK: Cours (format Pepal)
        let json = #"[{"uuid":"a","startDate":1795939200000,"endDate":1795951800000,"remote":false,"lessonStatus":"Actif","cancelDesc":null,"teachers":[{"firstName":"Julie","lastName":"LEROY"}],"rooms":[{"name":"Salle 4"}],"schoolSubject":{"name":"Développement web"}},{"uuid":"b","startDate":1795957200000,"endDate":1795969800000,"remote":true,"lessonStatus":"Annulé","cancelDesc":"Prof absent","teachers":[],"rooms":[],"schoolSubject":{"name":"Anglais"}}]"#
        let c = EmploiDuTemps.decoder(json)
        verifie(c.count == 2, "deux séances lues")
        verifie(c.first?.matiere == "Développement web" && c.first?.salle == "Salle 4" && c.first?.prof == "Julie Leroy",
                "matière, salle, prof", "\(String(describing: c.first))")
        verifie(c.last?.annule == true && c.last?.distanciel == true, "séance annulée à distance")
        verifie(EmploiDuTemps.decoder("pas du json").isEmpty, "page sans séances → vide")

        // MARK: Mer
        func h(vent: Double, rafales: Double? = nil, dir: Double = 270, houle: Double? = nil, periode: Double? = nil) -> Mer.Heure {
            Mer.Heure(date: Date(), vent: vent, rafales: rafales ?? vent + 4, dirVent: dir, vague: houle, houle: houle,
                      periode: periode, dirHoule: 270, eau: 13)
        }
        verifie(Mer.avisNavigation(h(vent: 3)).1 == "Pétole", "3 nds → Pétole")
        verifie(Mer.avisNavigation(h(vent: 16)).1 == "Top", "16 nds → Top")
        verifie(Mer.avisNavigation(h(vent: 27)).1 == "Engagé", "27 nds → Engagé")
        verifie(Mer.avisNavigation(h(vent: 32)).1 == "Trop fort", "32 nds → Trop fort")
        verifie(Mer.avisSurf(h(vent: 5, houle: 0.3)).1 == "Plat", "0,3 m → Plat")
        verifie(Mer.avisSurf(h(vent: 5, dir: 90, houle: 1.0, periode: 10)).1 == "Bon", "1 m, vent de terre → Bon")
        verifie(Mer.avisSurf(h(vent: 5, houle: 2.6)).1 == "Trop gros", "2,6 m → Trop gros")
        verifie(Mer.avisSurf(h(vent: 15, dir: 270, houle: 1.0)).1 == "Haché", "vent de mer 15 nds → Haché")
        verifie(Mer.estPluie(code: 61, precipitation: 0), "code 61 (pluie) → parapluie")
        verifie(Mer.estPluie(code: 3, precipitation: 0.5), "0,5 mm mesurés → parapluie")
        verifie(!Mer.estPluie(code: 2, precipitation: 0), "nuageux sec → pas de parapluie")
        verifie(!Mer.estPluie(code: 45, precipitation: 0.1), "brouillard → pas de parapluie")
    }
}
