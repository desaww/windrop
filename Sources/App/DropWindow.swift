import SwiftUI
import UniformTypeIdentifiers
import AppKit

/// A separate window used as a drop target.
///
/// Why a second window: SwiftUI's menu bar window (MenuBarExtra) is a
/// non-activating panel. It closes as soon as another application takes over
/// - which is exactly what happens when you pick up a file in the Finder, so
/// there is no way to drop anything there. An ordinary window stays open and
/// accepts files reliably.
struct DropWindowView: View {
    @EnvironmentObject var state: AppState
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.connected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(state.statusText)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
            }

            dropArea

            Button {
                FilePicker.show(state)
            } label: {
                Text("Choose files …").frame(maxWidth: .infinity)
            }

            if !state.transfers.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.transfers.prefix(5)) { transfer in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(transfer.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(transfer.status == "sending"
                                     ? "\(Int(transfer.fraction * 100)) %"
                                     : Format.size(transfer.size))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            if transfer.status == "sending" {
                                ProgressView(value: transfer.fraction)
                                    .progressViewStyle(.linear)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
        .background(WindowAccessor { window in
            // Float above other windows so the window does not slip behind
            // the Finder while dragging.
            window.level = .floating
            window.isMovableByWindowBackground = true
        })
    }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text(isTargeted ? "Release to send" : "Drop files here")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            )
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                DropHandler.accept(providers, state)
                return true
            }
    }
}

/// Takes the dragged file references. Used by more than one view.
enum DropHandler {
    static func accept(_ providers: [NSItemProvider], _ state: AppState) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { state.send([url]) }
            }
        }
    }
}

/// The system file picker, for when dragging is not wanted.
enum FilePicker {
    static func show(_ state: AppState) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Send files to the Windows laptop"
        panel.prompt = "Send"
        // Without activating first, the panel stays invisible behind other
        // apps for a menu bar app (LSUIElement).
        NSApplication.shared.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            state.send(panel.urls)
        }
    }
}

/// Reaches the NSWindow behind a SwiftUI view.
struct WindowAccessor: NSViewRepresentable {
    let action: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window { action(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
