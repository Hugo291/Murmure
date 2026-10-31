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

    static var retainAudio: Bool {
        get { d.bool(forKey: "retainAudio") }
        set {
            d.set(newValue, forKey: "retainAudio")
            if !newValue { AudioReplayStore.shared.clear() }
        }
    }

    /// IP des appareils Cast dont le son est coupé pendant la dictée. Vide par défaut : on les active dans le menu.
    static var pausedDevices: [String] {
        get { d.stringArray(forKey: "pausedDevices") ?? [] }
        set { d.set(newValue, forKey: "pausedDevices") }
    }

    // MARK: - Prompts système de reformulation (éditables dans les Réglages)

    /// Prompts par défaut : source de vérité, servent au repli et au « Réinitialiser ».
    static let defaultPromptLight = """
    Tu nettoies un texte dicté à la voix. Corrige la ponctuation, les majuscules et les fautes d'orthographe/grammaire.
    SUPPRIME les répétitions involontaires, les bégaiements, les faux départs et les mots de remplissage parasites (euh, bah, « pour pour pour »).
    Garde les mots et le style de l'utilisateur (registre familier compris), ne reformule pas, ne change pas le sens, n'ajoute rien, ne commente pas.
    Réponds UNIQUEMENT avec le texte nettoyé, sans guillemets ni préambule.
    """

    static let defaultPromptFull = """
    Tu es un rédacteur. On te donne un texte dicté à la voix.
    Reformule-le pour qu'il soit clair, fluide et bien écrit, en conservant fidèlement le sens et la langue d'origine.
    Réponds UNIQUEMENT avec le texte final, sans guillemets ni préambule ni commentaire.
    """

    static let defaultPromptSummarize = """
    Reformule le texte suivant pour qu'il soit clair, fluide et concis.
    Supprime les répétitions, les hésitations et les tics de langage (« du coup », « en fait », « genre », « tu vois », « voilà »…).
    Garde fidèlement l'idée principale et le sens, dans la même langue. Ne commente pas.
    Réponds UNIQUEMENT avec le texte reformulé, sans guillemets ni préambule.
    """

    /// Consigne « correction légère » (mode .light). Repli sur le défaut si vidée.
    static var promptLight: String {
        get { storedPrompt("promptLight", default: defaultPromptLight) }
        set { d.set(newValue, forKey: "promptLight") }
    }
    /// Consigne « reformulation complète » (mode .full). Repli sur le défaut si vidée.
    static var promptFull: String {
        get { storedPrompt("promptFull", default: defaultPromptFull) }
        set { d.set(newValue, forKey: "promptFull") }
    }
    /// Consigne pour la reformulation de la sélection (⌘R). Repli sur le défaut si vidée.
    static var promptSummarize: String {
        get { storedPrompt("promptSummarize", default: defaultPromptSummarize) }
        set { d.set(newValue, forKey: "promptSummarize") }
    }

    /// Prompt système effectif pour un mode de retouche donné.
    static func prompt(for mode: ReformMode) -> String {
        switch mode {
        case .light: return promptLight
        case .full:  return promptFull
        case .off:   return ""
        }
    }

    /// Valeur stockée si non vide, sinon le défaut — l'IA ne reçoit jamais de consigne vide.
    private static func storedPrompt(_ key: String, default def: String) -> String {
        let s = (d.string(forKey: key) ?? "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? def : s
    }

    /// Moteurs de retouche, du plus prioritaire au moins prioritaire, « moteur|modèle »
    /// (`lmstudio|…` ou `ollama|…`). Le premier qui répond sert, les suivants sont des replis.
    /// Réglé par glisser-déposer (Réglages) et par le menu (clic = en tête). Migré depuis les
    /// anciens réglages GPU/CPU la première fois (ordre : moteur GPU, moteur choisi, puis l'autre).
    static var engineOrder: [String] {
        get {
            if let saved = d.stringArray(forKey: "engineOrder") { return saved }
            let backend = d.string(forKey: "reformBackend") ?? "lmstudio"
            let lm = "lmstudio|" + (d.string(forKey: "lmstudioModel") ?? "gemma-4-e4b-it-mlx")
            let oll = "ollama|" + (d.string(forKey: "ollamaModel") ?? "gemma3:4b")
            var seen = Set<String>()
            return ([d.string(forKey: "gpuEngine"), backend == "ollama" ? oll : lm, backend == "ollama" ? lm : oll]
                .compactMap { $0 }).filter { seen.insert($0).inserted }
        }
        set { d.set(newValue, forKey: "engineOrder") }
    }

    /// Met un moteur en tête (clic dans le menu, Gemma fraîchement téléchargé).
    static func promoteEngine(_ key: String) {
        engineOrder = [key] + engineOrder.filter { $0 != key }
    }

    /// Nom du modèle à l'œuvre sous le spectre : transcription pendant l'enregistrement et la
    /// transcription, moteur de retouche pendant la retouche.
    static var showModel: Bool {
        get { d.object(forKey: "showModel") as? Bool ?? true }
        set { d.set(newValue, forKey: "showModel") }
    }

    /// Lire ce qui est affiché dans la fenêtre (la conversation) pour corriger la dictée. Local uniquement.
    static var screenContext: Bool {
        get { d.object(forKey: "screenContext") as? Bool ?? true }
        set { d.set(newValue, forKey: "screenContext") }
    }

    static let lmstudioURL = URL(string: "http://localhost:1234/v1/chat/completions")!

    /// Mode auto : si le GPU est occupé par un autre processus, les moteurs MLX passent après
    /// les autres (cf. GPULoad). Libre → ordre de `engineOrder`.
    static var gpuAuto: Bool {
        get { d.object(forKey: "gpuAuto") as? Bool ?? true }
        set { d.set(newValue, forKey: "gpuAuto") }
    }

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

    /// Aperçu de transcription EN TEMPS RÉEL (reconnaissance vocale on-device d'Apple, au-dessus du toast).
    static var liveTranscript: Bool {
        get { d.object(forKey: "liveTranscript") == nil ? true : d.bool(forKey: "liveTranscript") }
        set { d.set(newValue, forKey: "liveTranscript") }
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
        set { d.set(newValue, forKey: "whisperModel"); if newValue == parakeetID { Parakeet.preload() } }
    }

    /// Identifiant de Parakeet dans `whisperModel` (pas un fichier ggml : moteur FluidAudio, cf. Parakeet.swift).
    static let parakeetID = "parakeet-tdt-0.6b-v3"

    static var modelPath: URL {
        supportDir.appendingPathComponent(whisperModel)
    }

    /// Modèles INSTALLÉS : fichiers `ggml-*.bin` du dossier support, plus Parakeet s'il est présent.
    static func installedWhisperModels() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: supportDir.path) else { return [] }
        return files.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
            + (Parakeet.isInstalled ? [parakeetID] : [])
    }

    /// Libellé lisible d'un fichier modèle whisper : `ggml-large-v3-turbo.bin` → `large-v3-turbo`.
    static func whisperLabel(_ file: String) -> String {
        if file == parakeetID { return "Parakeet v3 (NVIDIA)" }
        var s = file
        if s.hasPrefix("ggml-") { s.removeFirst(5) }
        if s.hasSuffix(".bin") { s.removeLast(4) }
        return "Whisper " + s
    }

    /// Cherche le binaire whisper-cli là où Homebrew/whisper.cpp l'installe.
    static func whisperBinary() -> String? {
        firstExecutable([
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper-cpp",
        ])
    }

    /// Binaire `ollama` (Homebrew ou installeur officiel).
    static func ollamaBinary() -> String? {
        firstExecutable(["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"])
    }

    /// Binaire `lms` (CLI de LM Studio, installé sous ~/.lmstudio/bin).
    static func lmsBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return firstExecutable([
            "\(home)/.lmstudio/bin/lms",
            "\(home)/.cache/lm-studio/bin/lms",
            "/opt/homebrew/bin/lms",
            "/usr/local/bin/lms",
        ])
    }

    private static func firstExecutable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Catalogue de modèles recommandés (téléchargeables en un clic)

    /// Un modèle whisper.cpp recommandé (téléchargé depuis Hugging Face à la demande).
    struct WhisperCatalogItem: Equatable {
        let name: String   // libellé court, ex. "small"
        let file: String   // fichier ggml, ex. "ggml-small.bin"
        let size: String   // taille réelle sur Hugging Face, ex. "488 MB"
        let noteEN: String // pourquoi le choisir (affiché sous le nom)
        let noteFR: String
    }

    /// Modèles whisper proposés, CLASSÉS du meilleur au moins bon pour la dictée (multilingue, FR) :
    /// précision d'abord, vitesse ensuite à précision voisine. Les `.en` sont exclus (anglais seul) ;
    /// les variantes q5/q8 d'un modèle dominé par un autre plus léger aussi.
    static let whisperCatalog: [WhisperCatalogItem] = [
        .init(name: "Parakeet v3 (NVIDIA)", file: parakeetID, size: "470 MB",
              noteEN: "Fastest · Neural Engine, stays loaded · ignores the dictionary",
              noteFR: "Le plus rapide · Neural Engine, reste chargé · ignore le dictionnaire"),
        .init(name: "Whisper large-v3-turbo", file: "ggml-large-v3-turbo.bin", size: "1.6 GB",
              noteEN: "Recommended · near large-v3 accuracy, ~6× faster",
              noteFR: "Recommandé · presque aussi précis que large-v3, ~6× plus rapide"),
        .init(name: "Whisper large-v3", file: "ggml-large-v3.bin", size: "3.1 GB",
              noteEN: "Most accurate · slow, lots of RAM",
              noteFR: "Le plus précis · lent, gourmand en mémoire"),
        .init(name: "Whisper large-v3-turbo (q8)", file: "ggml-large-v3-turbo-q8_0.bin", size: "874 MB",
              noteEN: "Turbo compressed · same quality, half the size",
              noteFR: "Turbo compressé · même qualité, moitié moins lourd"),
        .init(name: "Whisper large-v2", file: "ggml-large-v2.bin", size: "3.1 GB",
              noteEN: "Previous large · sometimes fewer hallucinations",
              noteFR: "Ancien large · parfois moins d'hallucinations"),
        .init(name: "Whisper large-v3-turbo (q5)", file: "ggml-large-v3-turbo-q5_0.bin", size: "574 MB",
              noteEN: "Turbo compressed more · slight accuracy loss",
              noteFR: "Turbo très compressé · léger recul de précision"),
        .init(name: "Whisper medium", file: "ggml-medium.bin", size: "1.5 GB",
              noteEN: "Decent · slower than turbo for less accuracy",
              noteFR: "Correct · plus lent que turbo et moins précis"),
        .init(name: "Whisper small", file: "ggml-small.bin", size: "488 MB",
              noteEN: "Fast · frequent errors on French",
              noteFR: "Rapide · erreurs fréquentes en français"),
        .init(name: "Whisper base", file: "ggml-base.bin", size: "148 MB",
              noteEN: "Very fast · rough", noteFR: "Très rapide · approximatif"),
        .init(name: "Whisper tiny", file: "ggml-tiny.bin", size: "78 MB",
              noteEN: "Testing only", noteFR: "Pour tester seulement"),
    ]

    /// URL de téléchargement Hugging Face pour un fichier ggml whisper.cpp.
    static func whisperURL(_ file: String) -> String {
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)"
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

    /// Passer la retouche IA : colle le texte brut de Whisper sans attendre le LLM.
    /// Par défaut : un appui SEUL sur Maj (tapé puis relâché sans autre touche) — rien à voir
    /// avec Échap, qui annule : l'ancien ⇧Échap se confondait avec lui.
    static var scSkipReform: Shortcut {
        get { shortcut("scSkipReform", Shortcut(keyCode: -1, modifiers: Shortcut.shift)) }
        set { setShortcut("scSkipReform", newValue) }
    }

    private static func shortcut(_ key: String, _ def: Shortcut) -> Shortcut {
        if let data = d.data(forKey: key), let s = try? JSONDecoder().decode(Shortcut.self, from: data) { return s }
        return def
    }
    private static func setShortcut(_ key: String, _ s: Shortcut) {
        if let data = try? JSONEncoder().encode(s) { d.set(data, forKey: key) }
    }

    /// Remet tous les raccourcis à leurs valeurs par défaut.
    static func resetShortcuts() {
        ["scDictation", "scCancel", "scPasteLast", "scSummarize", "scSkipReform"].forEach { d.removeObject(forKey: $0) }
    }
}
