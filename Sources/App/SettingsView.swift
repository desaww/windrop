import SwiftUI
import AppKit

/// Settings in tabs, the way macOS apps usually do it.
///
/// About the window height: every form gets fixedSize on the vertical axis.
/// That way it reports its real content height instead of stretching
/// greedily - otherwise the window opens far too tall and leaves an empty
/// area at the bottom.
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            general
                .tabItem { Label(tr("General", "Allgemein"), systemImage: "gearshape") }
            sending
                .tabItem { Label(tr("Sending", "Senden"), systemImage: "paperplane") }
            connection
                .tabItem { Label(tr("Connection", "Verbindung"), systemImage: "wifi") }
        }
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Picker(tr("Language", "Sprache"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                hint(tr("The receiving page switches over when the Windows tab is "
                        + "reloaded. The share sheet picks the change up the next "
                        + "time it is used, because it cannot read these settings "
                        + "from inside its sandbox.",
                        "Die Empfangsseite wechselt mit, sobald der Windows-Tab neu "
                        + "geladen wird. Das Teilen-Fenster übernimmt die Änderung "
                        + "beim übernächsten Senden, weil es diese Einstellungen aus "
                        + "seiner Abschottung heraus nicht lesen kann."))
            }

            Section {
                Toggle(tr("Start WinDrop at login", "WinDrop bei der Anmeldung starten"),
                       isOn: $settings.launchAtLogin)
                if let error = settings.launchAtLoginError {
                    hint(error, red: true)
                }
            }

            Section(tr("Notifications", "Mitteilungen")) {
                Toggle(tr("When something goes wrong", "Wenn etwas schiefgeht"),
                       isOn: $settings.notifyOnFailure)
                Toggle(tr("For every delivered file", "Bei jeder zugestellten Datei"),
                       isOn: $settings.notifyOnSuccess)
            }

            Section {
                Text("WinDrop \(WinDropInfo.version)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Sending

    private var sending: some View {
        Form {
            Section {
                Toggle(tr("Send several files as one ZIP archive",
                          "Mehrere Dateien als ein ZIP-Archiv senden"),
                       isOn: $settings.bundleAsZip)
                hint(tr("One archive is one download. Without bundling, the browser "
                        + "asks for permission once on the second download.",
                        "Ein Archiv ist ein Download. Ohne Bündelung fragt der Browser "
                        + "beim zweiten Download einmal nach Erlaubnis."))
            }

            Section {
                hint(tr("Folders are always packed, they cannot be transferred any "
                        + "other way. The share menu cannot do it, use the drop "
                        + "window for those.",
                        "Ordner werden immer gepackt, anders lassen sie sich nicht "
                        + "übertragen. Über das Teilen-Menü geht das nicht, dafür "
                        + "gibt es das Ablagefenster."))
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Connection

    private var connection: some View {
        Form {
            Section(tr("Address for the Windows laptop", "Adresse für den Windows-Laptop")) {
                Text(state.addressByName)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button(tr("Copy address", "Adresse kopieren")) { state.copyAddress() }
                    Button(tr("Copy IP address", "IP-Adresse kopieren")) { state.copyIPAddress() }
                }
                .controlSize(.small)
            }

            Section {
                HStack {
                    Button(tr("New access token", "Neuer Zugangscode")) { state.regenerateToken() }
                    Spacer()
                    Button(tr("Restart server", "Server neu starten")) { state.restartServer() }
                }
                .controlSize(.small)
                hint(tr("A new token invalidates the old address. The tab on the "
                        + "Windows laptop has to be opened once more.",
                        "Ein neuer Code macht die alte Adresse ungültig. Der Tab auf "
                        + "dem Windows-Laptop muss einmal neu geöffnet werden."))
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    Text("\(WinDropInfo.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                hint(tr("Fixed in code, because the share extension cannot read the "
                        + "app's settings from inside its sandbox.",
                        "Steht fest im Code, weil die Teilen-Erweiterung die "
                        + "Einstellungen der App aus ihrer Abschottung heraus nicht "
                        + "lesen kann."))
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hint(_ text: String, red: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(red ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
