import Foundation
import ServiceManagement

/// All settings in one place. Named AppSettings because SwiftUI already
/// has a type called Settings.
/// They live in UserDefaults; launch at login is
/// stored by the system itself.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    private let store: UserDefaults

    /// Interface language. Changing it redraws the app right away; the
    /// receiving page follows on the next reload of the Windows tab.
    @Published var language: AppLanguage {
        didSet { store.set(language.rawValue, forKey: AppLanguage.defaultsKey) }
    }

    @Published var bundleAsZip: Bool {
        didSet { store.set(bundleAsZip, forKey: "bundleAsZip") }
    }

    @Published var notifyOnFailure: Bool {
        didSet { store.set(notifyOnFailure, forKey: "notifyOnFailure") }
    }

    @Published var notifyOnSuccess: Bool {
        didSet { store.set(notifyOnSuccess, forKey: "notifyOnSuccess") }
    }

    /// Set when registering the login item failed.
    @Published var launchAtLoginError: String?

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = tr("Could not change the login item: ",
                                        "Der Anmeldeeintrag ließ sich nicht ändern: ")
                    + error.localizedDescription
                    + tr(" The app has to live in /Applications for this to work.",
                         " Dafür muss die App in /Applications liegen.")
            }
        }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            AppLanguage.defaultsKey: AppLanguage.english.rawValue,
            "bundleAsZip": true,
            "notifyOnFailure": true,
            "notifyOnSuccess": false,
        ])
        store = defaults
        language = AppLanguage.current
        bundleAsZip = defaults.bool(forKey: "bundleAsZip")
        notifyOnFailure = defaults.bool(forKey: "notifyOnFailure")
        notifyOnSuccess = defaults.bool(forKey: "notifyOnSuccess")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
