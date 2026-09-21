import SwiftUI

@main
struct WinDropApp: App {
    @StateObject private var state = AppState()
    @ObservedObject private var settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            // Always filled: the outline version looks washed out next to the
            // other menu bar icons. Connection state is shown by the dot
            // inside the menu, not by the icon.
            Image(systemName: "paperplane.fill")
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
        Window(tr("History", "Verlauf"), id: "history") {
            HistoryView().environmentObject(state)
        }
        .windowResizability(.contentMinSize)

        Window(tr("Settings", "Einstellungen"), id: "settings") {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentMinSize)
    }
}
