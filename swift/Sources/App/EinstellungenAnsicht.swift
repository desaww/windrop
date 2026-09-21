import SwiftUI
import AppKit

/// Einstellungen in Reitern, wie bei macOS-Programmen ueblich.
///
/// Zur Fensterhoehe: Jedes Formular bekommt fixedSize in der Senkrechten.
/// Damit meldet es seine tatsaechliche Inhaltshoehe nach oben, statt sich
/// gierig auszudehnen - sonst oeffnet sich das Fenster viel zu hoch und
/// unten bleibt eine leere Flaeche stehen.
struct EinstellungenAnsicht: View {
    @EnvironmentObject var zustand: AppZustand
    @ObservedObject private var einstellungen = Einstellungen.geteilt

    var body: some View {
        TabView {
            allgemein
                .tabItem { Label("Allgemein", systemImage: "gearshape") }
            senden
                .tabItem { Label("Senden", systemImage: "paperplane") }
            verbindung
                .tabItem { Label("Verbindung", systemImage: "wifi") }
        }
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Allgemein

    private var allgemein: some View {
        Form {
            Section {
                Toggle("WinDrop beim Anmelden starten", isOn: $einstellungen.autostart)
                if let fehler = einstellungen.autostartFehler {
                    hinweis(fehler, rot: true)
                }
            }

            Section("Mitteilungen") {
                Toggle("Wenn etwas schiefgeht", isOn: $einstellungen.mitteilungBeiFehler)
                Toggle("Bei jeder angekommenen Datei", isOn: $einstellungen.mitteilungBeiErfolg)
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

    // MARK: Senden

    private var senden: some View {
        Form {
            Section {
                Toggle("Mehrere Dateien als ein ZIP-Archiv senden",
                       isOn: $einstellungen.alsZipBuendeln)
                hinweis("Ein Archiv ist ein Download. Ohne Bündelung fragt der Browser "
                        + "beim zweiten Download einmalig nach Erlaubnis.")
            }

            Section {
                hinweis("Ordner werden immer gepackt, anders lassen sie sich nicht "
                        + "übertragen. Über das Teilen-Menü geht das nicht, dafür das "
                        + "Ablagefenster benutzen.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Verbindung

    private var verbindung: some View {
        Form {
            Section("Adresse für den Windows-Laptop") {
                Text(zustand.adresseName)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack {
                    Button("Adresse kopieren") { zustand.adresseKopieren() }
                    Button("IP-Adresse") { zustand.adresseIPKopieren() }
                }
                .controlSize(.small)
            }

            Section {
                HStack {
                    Button("Zugangscode neu erzeugen") { zustand.neuerZugangscode() }
                    Spacer()
                    Button("Server neu starten") { zustand.serverNeuStarten() }
                }
                .controlSize(.small)
                hinweis("Ein neuer Code macht die alte Adresse ungültig. Der Tab am "
                        + "Windows-Laptop muss dann einmal neu geöffnet werden.")
            }

            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    Text("\(WinDropInfo.port)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                hinweis("Fest eingebaut, weil die Teilen-Erweiterung in ihrer "
                        + "Abschottung keine Einstellungen der App lesen kann.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func hinweis(_ text: String, rot: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(rot ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
