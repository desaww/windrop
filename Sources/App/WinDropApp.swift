import SwiftUI

@main
struct WinDropApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            Image(systemName: state.receiverNames.isEmpty
                  ? "paperplane" : "paperplane.fill")
        }
        .menuBarExtraStyle(.window)

        // A separate window for drag and drop. The menu bar window cannot do
        // it: it closes the moment the Finder takes over the drag.
        Window("WinDrop", id: "drop") {
            DropWindowView().environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        // Both windows may be made larger, but not smaller than their
        // content, otherwise something would be cut off.
        Window("History", id: "history") {
            HistoryView().environmentObject(state)
        }
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentMinSize)
    }
}
