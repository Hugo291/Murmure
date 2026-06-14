import Foundation

/// Langue de l'INTERFACE (menus, toasts, fenêtres). Distincte de la langue de dictée (whisper).
enum AppLanguage: String, CaseIterable {
    case en, fr
    var nativeName: String { self == .en ? "English" : "Français" }
}

/// Traduction légère de l'interface. Anglais par défaut.
/// Convention : `L.tr("English", "Français")` au point d'usage.
enum L {
    static var lang: AppLanguage {
        get { AppLanguage(rawValue: Config.uiLanguage) ?? .en }
        set { Config.uiLanguage = newValue.rawValue }
    }

    /// Renvoie la variante anglaise ou française selon la langue d'interface courante.
    static func tr(_ en: String, _ fr: String) -> String { lang == .fr ? fr : en }
}
