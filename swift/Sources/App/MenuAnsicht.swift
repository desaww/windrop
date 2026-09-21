import SwiftUI
import AppKit

struct MenuAnsicht: View {
    @EnvironmentObject var zustand: AppZustand
    @Environment(\.openWindow) private var fensterOeffnen
    @State private var zeigtProtokoll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            kopf
            Divider()
            sendebereich
            if !zustand.transfers.isEmpty {
                Divider()
                liste
            }
            Divider()
            fussleiste
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: Kopf

    private var kopf: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(punktfarbe)
                    .frame(width: 8, height: 8)
                Text(zustand.statustext)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    zustand.beenden()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("WinDrop beenden")
            }
            if let fehler = zustand.startfehler {
                Text(fehler)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(zustand.adresseName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private var punktfarbe: Color {
        if zustand.startfehler != nil { return .red }
        if !zustand.empfaengerNamen.isEmpty { return .green }
        return zustand.laeuft ? .orange : .gray
    }

    // MARK: Senden

    /// Kein Ziehen und Ablegen in diesem Menue: Das Menueleisten-Fenster ist
    /// ein nicht aktivierbares Panel und klappt zu, sobald der Finder das
    /// Ziehen uebernimmt. Deshalb hier die Dateiauswahl und ein Knopf fuer das
    /// eigene Ablagefenster, das offen bleibt.
    private var sendebereich: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Dateiwahl.zeigen(zustand)
            } label: {
                Label("Dateien wählen …", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }

            Button {
                oeffne("ablage")
            } label: {
                Label("Ablagefenster öffnen", systemImage: "rectangle.dashed.and.paperclip")
                    .frame(maxWidth: .infinity)
            }

            if zustand.packtGerade {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Archiv wird gepackt …")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !zustand.verbunden, !zustand.transfers.isEmpty {
                Text("Kein Empfänger verbunden. Die Adresse oben am Windows-Laptop "
                     + "im Browser öffnen, dann geht es von allein weiter.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Warteschlange

    private var liste: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(zustand.transfers.prefix(6)) { t in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(t.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(zeile(t))
                            .font(.system(size: 10))
                            .foregroundStyle(t.status == "fehler" ? Color.red : Color.secondary)
                        if t.status == "fehler" {
                            Button("Erneut") { zustand.erneutVersuchen(t.id) }
                                .controlSize(.mini)
                        }
                    }
                    if t.status == "laeuft" {
                        ProgressView(value: t.anteil)
                            .progressViewStyle(.linear)
                    }
                }
            }
            if zustand.transfers.contains(where: { $0.status == "fertig" || $0.status == "fehler" }) {
                Button("Liste aufräumen") { zustand.listeLeeren() }
                    .controlSize(.mini)
            }
        }
    }

    private func zeile(_ t: TransferAnsicht) -> String {
        switch t.status {
        case "wartend":   return "wartet"
        case "angeboten": return "wird angeboten"
        case "laeuft":    return "\(Int(t.anteil * 100)) %"
        case "fertig":    return Format.groesse(t.groesse)
        case "fehler":    return t.grund.isEmpty ? "fehlgeschlagen" : t.grund
        default:          return t.status
        }
    }

    // MARK: Fussleiste

    private var fussleiste: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Verlauf") { oeffne("verlauf") }
                Button("Einstellungen") { oeffne("einstellungen") }
                Spacer()
                Button(zeigtProtokoll ? "Protokoll aus" : "Protokoll") {
                    zeigtProtokoll.toggle()
                }
            }
            .controlSize(.small)

            if zeigtProtokoll {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(zustand.protokoll.suffix(40).enumerated()), id: \.offset) { _, zeile in
                            Text(zeile)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 120)
            }
        }
    }

    /// Ohne Aktivierung bleibt ein Fenster bei einer Menueleisten-App
    /// (LSUIElement) hinter allem anderen liegen.
    private func oeffne(_ kennung: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        fensterOeffnen(id: kennung)
    }
}
