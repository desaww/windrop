import SwiftUI
import AppKit

struct MenuView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            sendSection
            if !state.transfers.isEmpty {
                Divider()
                list
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 330)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(state.statusText)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Button {
                    state.quit()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(tr("Quit WinDrop", "WinDrop beenden"))
            }
            if let error = state.startError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(state.addressByName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
    }

    private var dotColor: Color {
        if state.startError != nil { return .red }
        if !state.receiverNames.isEmpty { return .green }
        return state.running ? .orange : .gray
    }

    // MARK: Sending

    /// No drag and drop in this menu: the menu bar window is a
    /// non-activating panel and closes as soon as the Finder takes over the
    /// drag. Hence the file picker and a button for the drop window, which
    /// stays open.
    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                FilePicker.show(state)
            } label: {
                Label(tr("Choose files …", "Dateien wählen …"),
                      systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }

            Button {
                showWindow("drop")
            } label: {
                Label(tr("Open drop window", "Ablagefenster öffnen"),
                      systemImage: "rectangle.dashed.and.paperclip")
                    .frame(maxWidth: .infinity)
            }

            if state.packing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(tr("Packing the archive …", "Archiv wird gepackt …"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if !state.connected, !state.transfers.isEmpty {
                Text(tr("No receiver connected. Open the address above in a browser "
                        + "on the Windows laptop and everything continues by itself.",
                        "Kein Empfänger verbunden. Die Adresse oben im Browser des "
                        + "Windows-Laptops öffnen, dann läuft alles von selbst weiter."))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Queue

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.transfers.prefix(6)) { transfer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(transfer.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(detail(transfer))
                            .font(.system(size: 10))
                            .foregroundStyle(transfer.status == "failed" ? Color.red : Color.secondary)
                        if transfer.status == "failed" {
                            Button(tr("Retry", "Erneut")) { state.retry(transfer.id) }
                                .controlSize(.mini)
                        }
                    }
                    if transfer.status == "sending" {
                        ProgressView(value: transfer.fraction)
                            .progressViewStyle(.linear)
                    }
                }
            }
            if state.transfers.contains(where: { $0.status == "done" || $0.status == "failed" }) {
                Button(tr("Clear finished", "Erledigte entfernen")) { state.clearFinished() }
                    .controlSize(.mini)
            }
        }
    }

    private func detail(_ transfer: TransferSnapshot) -> String {
        switch transfer.status {
        case "waiting": return tr("waiting", "wartet")
        case "offered": return tr("offered", "angeboten")
        case "sending": return "\(Int(transfer.fraction * 100)) %"
        case "done":    return Format.size(transfer.size)
        case "failed":  return transfer.reason.isEmpty
                               ? tr("failed", "fehlgeschlagen") : transfer.reason
        default:        return transfer.status
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(tr("History", "Verlauf")) { showWindow("history") }
                Button(tr("Settings", "Einstellungen")) { showWindow("settings") }
                Spacer()
                Button(showLog ? tr("Hide log", "Protokoll aus") : tr("Log", "Protokoll")) {
                    showLog.toggle()
                }
            }
            .controlSize(.small)

            if showLog {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.log.suffix(40).enumerated()), id: \.offset) { _, line in
                            Text(line)
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

    /// Without activating the app first, a window of a menu bar app
    /// (LSUIElement) opens behind everything else.
    private func showWindow(_ id: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
