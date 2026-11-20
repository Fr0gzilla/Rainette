// Gardien du bureau : le Finder ne sait pas que Rainette occupe le coin haut droit,
// alors tout fichier du bureau qui se retrouve sous le widget est déplacé juste à sa gauche.
import AppKit

@MainActor
final class GardienBureau {
    private weak var fenetre: NSWindow?
    private var source: DispatchSourceFileSystemObject?
    private var minuteur: Timer?
    private var enCours = false

    init(fenetre: NSWindow) { self.fenetre = fenetre }

    func demarrer() {
        // Un fichier ajouté ou retiré du bureau : on vérifie tout de suite (le Finder met un instant à le placer).
        let dossier = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
        let fd = open(dossier, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
            s.setEventHandler { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.verifier() }
            }
            s.setCancelHandler { close(fd) }
            s.resume()
            source = s
        }
        // Un fichier glissé à la main sous le widget : on repasse régulièrement.
        minuteur = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.verifier() }
        }
        verifier()
    }

    func verifier() {
        guard !enCours, let w = fenetre, let ecran = w.screen ?? NSScreen.main else { return }
        // Le Finder compte depuis le haut gauche de l'écran ; AppKit depuis le bas gauche.
        let h = ecran.frame.maxY
        let f = w.frame
        let marge: CGFloat = 45
        let zone = [f.minX - marge, h - f.maxY - marge, f.maxX + marge, h - f.minY + marge]
        // Places libres (coordonnées Finder, centre de l'icône) : une grille sur tout l'écran,
        // en colonnes depuis la droite (comme le Finder), hors du widget et des widgets Apple.
        let obstacles = (Disposition.widgetsApple(ecran) + [f]).map { $0.insetBy(dx: -45, dy: -45) }
        let v = ecran.visibleFrame
        var places: [CGFloat] = []
        for x in stride(from: v.maxX - 60, through: v.minX + 50, by: -100) {
            for yf in stride(from: h - v.maxY + 50, through: h - v.minY - 75, by: 100) {
                let p = NSPoint(x: x, y: h - yf)   // même point en coordonnées AppKit
                if !obstacles.contains(where: { $0.contains(p) }) { places += [x, yf] }
            }
        }
        let args = (zone + places).map { String(Int($0)) }
        enCours = true
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", GardienBureau.script] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            await MainActor.run { self.enCours = false }
        }
    }

    /// Arguments : zone (gauche, haut, droite, bas), puis les places libres (x, y) dans l'ordre de préférence.
    nonisolated static let script = """
    on run argv
        set zl to (item 1 of argv) as integer
        set zt to (item 2 of argv) as integer
        set zr to (item 3 of argv) as integer
        set zb to (item 4 of argv) as integer
        set places to {}
        set k to 5
        repeat while k < (count of argv)
            set end of places to {(item k of argv) as integer, (item (k + 1) of argv) as integer}
            set k to k + 2
        end repeat
        tell application "Finder"
            set lst to every item of desktop
            set occ to {}
            repeat with i in lst
                set end of occ to desktop position of i
            end repeat
            repeat with i in lst
                set p to desktop position of i
                set px to item 1 of p
                set py to item 2 of p
                if px > zl and px < zr and py > zt and py < zb then
                    repeat with pl in places
                        set x to item 1 of pl
                        set y to item 2 of pl
                        set libre to true
                        repeat with o in occ
                            if (((item 1 of o) - x) ^ 2 + ((item 2 of o) - y) ^ 2) < 3600 then set libre to false
                        end repeat
                        if libre then
                            set desktop position of i to {x, y}
                            set end of occ to {x, y}
                            exit repeat
                        end if
                    end repeat
                end if
            end repeat
        end tell
    end run
    """
}
