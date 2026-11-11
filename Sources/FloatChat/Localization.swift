import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case ru
    case en

    var id: String { rawValue }
    var shortTitle: String { rawValue.uppercased() }
}

/// Tiny in-code localization. Add new UI strings with
/// `L10n.t("по-русски", "in English")`.
enum L10n {
    static let key = "floatchat.language"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "ru") ?? .ru
    }

    static func t(_ ru: String, _ en: String) -> String {
        current == .ru ? ru : en
    }
}
