import SwiftUI

@main
struct WinDropApp: App {
    @StateObject private var zustand = AppZustand()

    var body: some Scene {
        MenuBarExtra {
            MenuAnsicht().environmentObject(zustand)
        } label: {
            Image(systemName: zustand.empfaengerNamen.isEmpty
                  ? "paperplane" : "paperplane.fill")
        }
        .menuBarExtraStyle(.window)

        // Eigenes Fenster fuers Ziehen und Ablegen. Das Menueleisten-Fenster
        // kann das nicht: Es klappt zu, sobald der Finder das Ziehen uebernimmt.
        Window("WinDrop", id: "ablage") {
            AblageAnsicht().environmentObject(zustand)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        // Beide Fenster duerfen groesser gezogen werden, kleiner als der
        // Inhalt aber nicht. Sonst rutscht etwas aus dem Bild.
        Window("Verlauf", id: "verlauf") {
            VerlaufAnsicht().environmentObject(zustand)
        }
        .windowResizability(.contentMinSize)

        Window("Einstellungen", id: "einstellungen") {
            EinstellungenAnsicht().environmentObject(zustand)
        }
        .windowResizability(.contentMinSize)
    }
}
