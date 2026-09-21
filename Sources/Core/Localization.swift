import Foundation

/// The language of everything the user sees: menu, windows, notifications,
/// the receiving page in the browser and the share sheet.
///
/// English is the default. The value lives in UserDefaults, so code that has
/// no access to the settings object can read it as well.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Every language is offered in its own words, never translated.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    static let defaultsKey = "language"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "")
            ?? .english
    }
}

/// Both languages sit right where the text is used.
///
/// There is no table of keys that could drift out of sync with the views: a
/// new string is written twice, next to each other, and that is the whole
/// procedure. To add a third language, give `tr` one more parameter and add
/// a case above - the compiler then points at every place that needs it.
func tr(_ english: String, _ german: String) -> String {
    AppLanguage.current == .german ? german : english
}
