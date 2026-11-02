import Foundation

/// UI language. Strings are written inline as `L("中文", "English")` next to where they're used,
/// so both versions stay in sync and switching takes effect without a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }

    static var setting: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: Pref.language) ?? "") ?? .system
    }

    /// `.zh` or `.en`. "System" means Chinese when the Mac's preferred language is Chinese.
    static var resolved: AppLanguage {
        switch setting {
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
        case let language: return language
        }
    }

    static var isEnglish: Bool { resolved == .en }

    /// For dates and numbers.
    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_CN") }
}

/// The string for the current UI language.
func L(_ zh: String, _ en: String) -> String {
    AppLanguage.isEnglish ? en : zh
}
