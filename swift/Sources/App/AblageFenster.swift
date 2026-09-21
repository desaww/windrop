import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// Eigenes Fenster als Ablageflaeche fuer Drag-and-drop.
///
/// Warum ein zweites Fenster: Das Menueleisten-Fenster von SwiftUI
/// (MenuBarExtra) ist ein nicht aktivierbares Panel. Es klappt zu, sobald eine
/// andere Anwendung die Fuehrung uebernimmt - und genau das passiert, wenn man
/// im Finder eine Datei anfasst. Man kommt also gar nicht zum Ablegen. Ein
/// normales Fenster bleibt offen und nimmt Dateien zuverlaessig an.
struct AblageAnsicht: View {
    @EnvironmentObject var zustand: AppZustand
    @State private var ziehtDarueber = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(zustand.verbunden ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(zustand.statustext)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }

            flaeche

            Button {
                Dateiwahl.zeigen(zustand)
            } label: {
                Text("Dateien wählen …").frame(maxWidth: .infinity)
            }

            if !zustand.transfers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(zustand.transfers.prefix(5)) { t in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(t.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(t.status == "laeuft"
                                     ? "\(Int(t.anteil * 100)) %"
                                     : Format.groesse(t.groesse))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            if t.status == "laeuft" {
                                ProgressView(value: t.anteil)
                                    .progressViewStyle(.linear)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(FensterZugriff { fenster in
            // Immer im Vordergrund, damit das Fenster beim Ziehen aus dem
            // Finder nicht hinter andere Fenster rutscht.
            fenster.level = .floating
            fenster.isMovableByWindowBackground = true
        })
    }

    private var flaeche: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(ziehtDarueber ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(ziehtDarueber ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(ziehtDarueber ? "Loslassen zum Senden" : "Dateien hierher ziehen")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $ziehtDarueber) { anbieter in
                Ablegen.entgegennehmen(anbieter, zustand)
                return true
            }
    }
}

/// Nimmt die gezogenen Dateiverweise an. Von beiden Ansichten benutzt.
enum Ablegen {
    static func entgegennehmen(_ anbieter: [NSItemProvider], _ zustand: AppZustand) {
        for a in anbieter {
            a.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { eintrag, _ in
                guard let daten = eintrag as? Data,
                      let url = URL(dataRepresentation: daten, relativeTo: nil) else { return }
                DispatchQueue.main.async { zustand.senden([url]) }
            }
        }
    }
}

/// Dateiauswahl ueber den Systemdialog - der Weg, der ohne Ziehen auskommt.
enum Dateiwahl {
    static func zeigen(_ zustand: AppZustand) {
        let auswahl = NSOpenPanel()
        auswahl.allowsMultipleSelection = true
        auswahl.canChooseFiles = true
        auswahl.canChooseDirectories = false
        auswahl.message = "Dateien an den Windows-Laptop senden"
        auswahl.prompt = "Senden"
        // Ohne Aktivierung bleibt der Dialog bei einer Menueleisten-App
        // (LSUIElement) im Hintergrund unsichtbar.
        NSApplication.shared.activate(ignoringOtherApps: true)
        if auswahl.runModal() == .OK {
            zustand.senden(auswahl.urls)
        }
    }
}

/// Greift auf das NSWindow hinter einer SwiftUI-Ansicht zu.
struct FensterZugriff: NSViewRepresentable {
    let aktion: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let ansicht = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let fenster = ansicht.window { aktion(fenster) }
        }
        return ansicht
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
