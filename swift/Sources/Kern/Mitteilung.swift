import Foundation
import UserNotifications

/// Kurze Systemmitteilungen. Sinnvoll vor allem bei Fehlern, weil die App
/// sonst still in der Menueleiste sitzt und man einen Fehlschlag uebersieht.
enum Mitteilung {

    static func erlaubnisHolen() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func zeigen(titel: String, text: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let inhalt = UNMutableNotificationContent()
        inhalt.title = titel
        inhalt.body = text
        let anfrage = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: inhalt, trigger: nil)
        UNUserNotificationCenter.current().add(anfrage, withCompletionHandler: nil)
    }
}
