import Foundation
import ServiceManagement

/// Alle Einstellungen an einem Ort. Gespeichert werden sie in den
/// Standardeinstellungen der App (UserDefaults), der Autostart dagegen im
/// System selbst.
final class Einstellungen: ObservableObject {

    static let geteilt = Einstellungen()

    private let speicher: UserDefaults

    @Published var alsZipBuendeln: Bool {
        didSet { speicher.set(alsZipBuendeln, forKey: "alsZipBuendeln") }
    }

    @Published var mitteilungBeiFehler: Bool {
        didSet { speicher.set(mitteilungBeiFehler, forKey: "mitteilungBeiFehler") }
    }

    @Published var mitteilungBeiErfolg: Bool {
        didSet { speicher.set(mitteilungBeiErfolg, forKey: "mitteilungBeiErfolg") }
    }

    /// Meldung, falls das Eintragen in den Autostart nicht geklappt hat.
    @Published var autostartFehler: String?

    @Published var autostart: Bool {
        didSet {
            guard autostart != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if autostart {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                autostartFehler = nil
            } catch {
                autostartFehler = "Autostart ließ sich nicht ändern: "
                    + error.localizedDescription
                    + " Die App muss dafür in /Applications liegen."
            }
        }
    }

    private init() {
        let vorgaben = UserDefaults.standard
        vorgaben.register(defaults: [
            "alsZipBuendeln": true,
            "mitteilungBeiFehler": true,
            "mitteilungBeiErfolg": false,
        ])
        speicher = vorgaben
        alsZipBuendeln = vorgaben.bool(forKey: "alsZipBuendeln")
        mitteilungBeiFehler = vorgaben.bool(forKey: "mitteilungBeiFehler")
        mitteilungBeiErfolg = vorgaben.bool(forKey: "mitteilungBeiErfolg")
        autostart = SMAppService.mainApp.status == .enabled
    }
}
