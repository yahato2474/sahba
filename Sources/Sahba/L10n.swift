import Foundation

/// The app's language: the Mac's own (automatic), Arabic, English, or Japanese. Picked from the menu.
enum Language: String, CaseIterable {
    case auto, arabic, english, japanese
}

enum L10n {
    private static let key = "language"
    /// Set by the command-line test modes (`--lang ar|en`) so they don't touch the saved choice.
    static var override: Language?

    static var setting: Language {
        get { override ?? Language(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            // System panels (Move, AirDrop) follow this after the app is reopened.
            switch newValue {
            case .auto: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            case .arabic: UserDefaults.standard.set(["ar"], forKey: "AppleLanguages")
            case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
            case .japanese: UserDefaults.standard.set(["ja"], forKey: "AppleLanguages")
            }
        }
    }

    /// The language the app speaks now: the menu choice, or for "automatic" the Mac's language (English if it is neither).
    static var current: Language {
        guard setting == .auto else { return setting }
        // The Mac's language, not AppleLanguages for this app (which the menu choice may have changed).
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        let first = global?.first ?? Locale.preferredLanguages.first ?? ""
        if first.hasPrefix("ar") { return .arabic }
        if first.hasPrefix("ja") { return .japanese }
        return .english
    }

    /// Right-to-left layout and Arabic wording.
    static var arabic: Bool { current == .arabic }
    static var japanese: Bool { current == .japanese }

    /// File size in the app's language (English digits even on an Arabic Mac).
    static func size(_ bytes: Int64) -> String {
        if arabic { return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        guard value >= 1000 else { return "\(bytes) bytes" }
        var i = -1
        repeat { value /= 1000; i += 1 } while value >= 1000 && i < units.count - 1
        return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[i])
    }
}

/// The text in the language the app speaks.
func tr(_ arabic: String, _ english: String, _ japanese: String) -> String {
    switch L10n.current {
    case .arabic: return arabic
    case .japanese: return japanese
    default: return english
    }
}
