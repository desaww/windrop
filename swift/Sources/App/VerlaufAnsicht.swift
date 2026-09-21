import SwiftUI

struct VerlaufAnsicht: View {
    @EnvironmentObject var zustand: AppZustand

    var body: some View {
        VerlaufInhalt(verlauf: zustand.verlauf)
    }
}

/// Eigene Ansicht, damit SwiftUI direkt auf das Verlaufsobjekt schaut.
private struct VerlaufInhalt: View {
    @ObservedObject var verlauf: Verlauf

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Verlauf")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Leeren") { verlauf.leeren() }
                    .controlSize(.small)
                    .disabled(verlauf.eintraege.isEmpty)
            }
            .padding(12)

            Divider()

            if verlauf.eintraege.isEmpty {
                Text("Noch nichts gesendet.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(verlauf.eintraege) { eintrag in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: eintrag.erfolg
                                      ? "checkmark.circle" : "exclamationmark.circle")
                                    .font(.system(size: 11))
                                    .foregroundStyle(eintrag.erfolg ? Color.green : Color.red)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(eintrag.name)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(zeitpunkt(eintrag.zeit)
                                         + " · " + Format.groesse(eintrag.groesse)
                                         + (eintrag.grund.isEmpty ? "" : " · " + eintrag.grund))
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(minWidth: 360, idealWidth: 380, minHeight: 260, idealHeight: 420)
    }

    private func zeitpunkt(_ datum: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "dd.MM. HH:mm"
        return f.string(from: datum)
    }
}
