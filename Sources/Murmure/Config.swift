import Foundation

/// Réglages persistés + emplacements des binaires/modèles.
enum ReformMode: String, CaseIterable {
    case off        // texte brut, aucune IA
    case light      // correction légère (ponctuation + fautes)
    case full       // reformulation complète

    var label: String {
        switch self {
        case .off:   return L.tr("Raw text (no AI)", "Texte brut (aucune IA)")
        case .light: return L.tr("Light cleanup", "Correction légère")
        case .full:  return L.tr("Full rewrite", "Reformulation complète")
        }
    }
}

enum Config {
    // MARK: - Réglages utilisateur (persistés)

    private static let d = UserDefaults.standard

    static var reformMode: ReformMode {
        get { ReformMode(rawValue: d.string(forKey: "reformMode") ?? "") ?? .light }
        set { d.set(newValue.rawValue, forKey: "reformMode") }
    }

    static var ollamaModel: String {
        get { d.string(forKey: "ollamaModel") ?? "gemma3:4b" }
        set { d.set(newValue, forKey: "ollamaModel") }
    }

    /// Moteur de reformulation : "lmstudio" (par défaut — MLX, bien meilleur sur Apple Silicon ;
    /// repli auto sur Ollama s'il est éteint) ou "ollama".
    static var reformBackend: String {
        get { d.string(forKey: "reformBackend") ?? "lmstudio" }
        set { d.set(newValue, forKey: "reformBackend") }
    }

    static var lmstudioModel: String {
        get { d.string(forKey: "lmstudioModel") ?? "gemma-4-e4b-it-mlx" }
        set { d.set(newValue, forKey: "lmstudioModel") }
    }

    static let lmstudioURL = URL(string: "http://localhost:1234/v1/chat/completions")!

    /// Langue passée à whisper ("fr", "en", "auto").
    static var language: String {
        get { d.string(forKey: "language") ?? "fr" }
        set { d.set(newValue, forKey: "language") }
    }

    /// Langue de l'INTERFACE ("en" par défaut, ou "fr"). Distincte de `language` (dictée).
    static var uiLanguage: String {
        get { d.string(forKey: "uiLanguage") ?? "en" }
        set { d.set(newValue, forKey: "uiLanguage") }
    }

    static var playSounds: Bool {
        get { d.object(forKey: "playSounds") == nil ? true : d.bool(forKey: "playSounds") }
        set { d.set(newValue, forKey: "playSounds") }
    }

    /// Couper le son du système pendant l'enregistrement (façon Typeless).
    static var muteWhileRecording: Bool {
        get { d.object(forKey: "muteWhileRecording") == nil ? true : d.bool(forKey: "muteWhileRecording") }
        set { d.set(newValue, forKey: "muteWhileRecording") }
    }

    /// Réduction de bruit Apple (voice processing) : isole la voix, nettoie le fond.
    static var noiseReduction: Bool {
        get { d.object(forKey: "noiseReduction") == nil ? true : d.bool(forKey: "noiseReduction") }
        set { d.set(newValue, forKey: "noiseReduction") }
    }

    // MARK: - Emplacements

    /// ~/Library/Application Support/Murmure/
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Murmure", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Fichier du modèle whisper utilisé pour la transcription (dans supportDir).
    static var whisperModel: String {
        get { d.string(forKey: "whisperModel") ?? "ggml-large-v3-turbo.bin" }
        set { d.set(newValue, forKey: "whisperModel") }
    }

    static var modelPath: URL {
        supportDir.appendingPathComponent(whisperModel)
    }

    /// Modèles whisper INSTALLÉS (fichiers `ggml-*.bin` du dossier support). Jamais de téléchargement.
    static func installedWhisperModels() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: supportDir.path) else { return [] }
        return files.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
    }

    /// Libellé lisible d'un fichier modèle whisper : `ggml-large-v3-turbo.bin` → `large-v3-turbo`.
    static func whisperLabel(_ file: String) -> String {
        var s = file
        if s.hasPrefix("ggml-") { s.removeFirst(5) }
        if s.hasSuffix(".bin") { s.removeLast(4) }
        return s
    }

    /// Cherche le binaire whisper-cli là où Homebrew/whisper.cpp l'installe.
    static func whisperBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper-cpp",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let ollamaURL = URL(string: "http://localhost:11434/api/generate")!

    // MARK: - Raccourcis configurables

    /// Démarrer / arrêter la dictée. Par défaut : Fn (modificateur seul).
    static var scDictation: Shortcut {
        get { shortcut("scDictation", Shortcut(keyCode: -1, modifiers: Shortcut.fn)) }
        set { setShortcut("scDictation", newValue) }
    }
    /// Annuler la dictée ou le traitement. Par défaut : Échap.
    static var scCancel: Shortcut {
        get { shortcut("scCancel", Shortcut(keyCode: 53, modifiers: 0)) }
        set { setShortcut("scCancel", newValue) }
    }
    /// Coller la dernière dictée. Par défaut : ⌘L.
    static var scPasteLast: Shortcut {
        get { shortcut("scPasteLast", Shortcut(keyCode: 37, modifiers: Shortcut.cmd)) }
        set { setShortcut("scPasteLast", newValue) }
    }
    /// Reformuler le texte sélectionné. Par défaut : ⌘R.
    static var scSummarize: Shortcut {
        get { shortcut("scSummarize", Shortcut(keyCode: 15, modifiers: Shortcut.cmd)) }
        set { setShortcut("scSummarize", newValue) }
    }

    private static func shortcut(_ key: String, _ def: Shortcut) -> Shortcut {
        if let data = d.data(forKey: key), let s = try? JSONDecoder().decode(Shortcut.self, from: data) { return s }
        return def
    }
    private static func setShortcut(_ key: String, _ s: Shortcut) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: key) }
    }

    /// Remet les quatre raccourcis à leurs valeurs par défaut.
    static func resetShortcuts() {
        ["scDictation", "scCancel", "scPasteLast", "scSummarize"].forEach { d.removeObject(forKey: $0) }
    }
}
