import AppKit
import SwiftUI
import ServiceManagement

/// Fenêtre « Réglages » — liste groupée façon macOS (Form .grouped), icônes teintées,
/// toggles, pickers. Remplace le gros sous-menu de la barre de menus.
final class SettingsWindowController: NSWindowController {
    let model = SettingsModel()

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = L.tr("Settings", "Réglages")
        self.init(window: win)
        win.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        win.setFrameAutosaveName("MurmureSettings")
        win.center()
    }

    func showAndFront() {
        model.scan()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Modèle (scan des modèles installés, téléchargements, benchmark)

final class SettingsModel: ObservableObject {
    @Published var ollamaModels: [String] = []
    @Published var lmStudioModels: [String] = []
    @Published var whisperModels: [String] = Config.installedWhisperModels()
    @Published var downloading: Set<String> = []
    @Published var downloadPct: [String: Double] = [:]
    @Published var benchmarking = false
    @Published var benchResult: String?

    /// Câblés par l'AppDelegate (rebuild menu / éditeur de raccourcis).
    var onUILanguageChange: (() -> Void)?
    var onEditShortcuts: (() -> Void)?

    func scan() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let oll = Reformulator.ollamaModels()
            let lms = Reformulator.lmStudioModels()
            DispatchQueue.main.async {
                self?.ollamaModels = oll
                self?.lmStudioModels = lms
                self?.whisperModels = Config.installedWhisperModels()
                // Aligne le réglage sur un VRAI modèle si le configuré n'est plus détecté (préfère Gemma).
                if Config.reformBackend == "lmstudio", !lms.isEmpty, !lms.contains(Config.lmstudioModel) {
                    Config.lmstudioModel = lms.first { $0.lowercased().contains("gemma") } ?? lms[0]
                }
                if Config.reformBackend == "ollama", !oll.isEmpty, !oll.contains(Config.ollamaModel) {
                    Config.ollamaModel = oll.first { $0.lowercased().contains("gemma") } ?? oll[0]
                }
            }
        }
    }

    var hasOllamaGemma: Bool { ollamaModels.contains { $0.lowercased().contains("gemma") } }
    var hasLMSGemma: Bool { lmStudioModels.contains { $0.lowercased().contains("gemma") } }

    func downloadWhisper(_ item: Config.WhisperCatalogItem) {
        let id = "whisper:" + item.file
        guard !downloading.contains(id) else { return }
        downloading.insert(id); downloadPct[id] = 0
        ModelDownloader.shared.downloadWhisper(
            file: item.file, url: Config.whisperURL(item.file), label: item.name,
            progress: { [weak self] frac, _ in self?.downloadPct[id] = frac ?? 0 },
            done: { [weak self] ok in
                self?.downloading.remove(id); self?.downloadPct[id] = nil
                if ok { Config.whisperModel = item.file }
                self?.whisperModels = Config.installedWhisperModels()
            })
    }

    func downloadChat(_ backend: String) {
        let id = backend == "ollama" ? "ollama:gemma3:4b" : "lmstudio:gemma"
        guard !downloading.contains(id) else { return }
        downloading.insert(id); downloadPct[id] = 0
        let progress: (Double?, String) -> Void = { [weak self] frac, _ in self?.downloadPct[id] = frac ?? 0 }
        let done: (Bool) -> Void = { [weak self] _ in
            self?.downloading.remove(id); self?.downloadPct[id] = nil
            self?.scan()
        }
        if backend == "ollama" {
            ModelDownloader.shared.downloadOllama(model: "gemma3:4b", progress: progress, done: done)
        } else {
            ModelDownloader.shared.downloadLMStudio(search: "gemma", progress: progress, done: done)
        }
    }

    func benchmark() {
        guard !benchmarking else { return }
        benchmarking = true; benchResult = nil
        let backend = Config.reformBackend
        let m = backend == "lmstudio" ? Config.lmstudioModel : Config.ollamaModel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t = Reformulator.benchmark(backend: backend, model: m)
            DispatchQueue.main.async {
                self?.benchmarking = false
                self?.benchResult = t.map { String(format: "%.1f s", $0) }
                    ?? L.tr("unavailable", "indisponible")
            }
        }
    }
}

// MARK: - Pastille d'icône teintée (façon Réglages iOS/macOS)

struct IconBadge: View {
    let symbol: String
    let color: Color
    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .frame(width: 27, height: 27)
            .overlay(Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white))
    }
}

// MARK: - Vue Réglages

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    @AppStorage("reformMode") private var reformMode = "light"
    @AppStorage("language") private var dictationLang = "fr"
    @AppStorage("uiLanguage") private var uiLang = "en"
    @AppStorage("liveTranscript") private var live = true
    @AppStorage("playSounds") private var sounds = true
    @AppStorage("muteWhileRecording") private var mute = true
    @AppStorage("whisperModel") private var whisperModel = "ggml-large-v3-turbo.bin"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var engineSelection: Binding<String> {
        Binding(
            get: { "\(Config.reformBackend)|\(Config.reformBackend == "lmstudio" ? Config.lmstudioModel : Config.ollamaModel)" },
            set: { v in
                let p = v.split(separator: "|", maxSplits: 1).map(String.init)
                guard p.count == 2 else { return }
                Config.reformBackend = p[0]
                if p[0] == "lmstudio" { Config.lmstudioModel = p[1] } else { Config.ollamaModel = p[1] }
            })
    }

    /// Options du sélecteur de moteur. Inclut TOUJOURS le moteur actuellement configuré —
    /// même si son serveur est éteint (sinon le sélecteur s'affiche vide) — avec un repère « serveur éteint ».
    private var engineOptions: [(tag: String, label: String)] {
        var opts: [(String, String)] = []
        for m in model.ollamaModels { opts.append(("ollama|\(m)", "Ollama · \(m)")) }
        for m in model.lmStudioModels { opts.append(("lmstudio|\(m)", "LM Studio · \(m)")) }
        let cur = engineSelection.wrappedValue
        if !cur.isEmpty, !opts.contains(where: { $0.0 == cur }) {
            let p = cur.split(separator: "|", maxSplits: 1).map(String.init)
            let isLM = p.first == "lmstudio"
            let name = p.count == 2 ? p[1] : cur
            let off = isLM ? model.lmStudioModels.isEmpty : model.ollamaModels.isEmpty
            let label = "\(isLM ? "LM Studio" : "Ollama") · \(name)" + (off ? L.tr("  (server off)", "  (serveur éteint)") : "")
            opts.insert((cur, label), at: 0)
        }
        if opts.isEmpty { opts.append(("", L.tr("No local model found", "Aucun modèle trouvé"))) }
        return opts
    }

    var body: some View {
        Form {
            Section(L.tr("Transcription", "Transcription")) {
                Picker(selection: $whisperModel) {
                    ForEach(model.whisperModels, id: \.self) { f in
                        Text(Config.whisperLabel(f)).tag(f)
                    }
                } label: {
                    Label { Text(L.tr("Transcription model", "Modèle de transcription")) } icon: { IconBadge(symbol: "waveform", color: .blue) }
                }
                Picker(selection: $dictationLang) {
                    Text(L.tr("French", "Français")).tag("fr")
                    Text(L.tr("English", "Anglais")).tag("en")
                    Text(L.tr("Auto", "Auto")).tag("auto")
                } label: {
                    Label { Text(L.tr("Dictation language", "Langue de dictée")) } icon: { IconBadge(symbol: "globe", color: .gray) }
                }
            }

            let toGet = Config.whisperCatalog.filter { !model.whisperModels.contains($0.file) }
            if !toGet.isEmpty {
                Section(L.tr("Download a transcription model", "Télécharger un modèle de transcription")) {
                    ForEach(toGet, id: \.file) { item in
                        downloadRow(title: "\(item.name)  ·  \(item.size)", id: "whisper:" + item.file) {
                            model.downloadWhisper(item)
                        }
                    }
                }
            }

            Section(L.tr("AI", "IA")) {
                Picker(selection: $reformMode) {
                    ForEach(ReformMode.allCases, id: \.rawValue) { m in Text(m.label).tag(m.rawValue) }
                } label: {
                    Label { Text(L.tr("AI touch-up", "Retouche IA")) } icon: { IconBadge(symbol: "sparkles", color: .purple) }
                }
                Picker(selection: engineSelection) {
                    ForEach(engineOptions, id: \.tag) { opt in Text(opt.label).tag(opt.tag) }
                } label: {
                    Label { Text(L.tr("AI engine", "Moteur IA")) } icon: { IconBadge(symbol: "cpu", color: .indigo) }
                }
                HStack {
                    Button(model.benchmarking ? L.tr("Testing…", "Test…") : L.tr("Test current model", "Tester le modèle actuel")) {
                        model.benchmark()
                    }
                    .disabled(model.benchmarking)
                    if let r = model.benchResult { Text(r).foregroundStyle(.secondary) }
                    Spacer()
                }
                if Config.ollamaBinary() != nil && !model.hasOllamaGemma {
                    downloadRow(title: "Gemma 3 4B · Ollama", id: "ollama:gemma3:4b") { model.downloadChat("ollama") }
                }
                if Config.lmsBinary() != nil && !model.hasLMSGemma {
                    downloadRow(title: "Gemma 3 4B · LM Studio (MLX)", id: "lmstudio:gemma") { model.downloadChat("lmstudio") }
                }
            }

            Section(L.tr("Feedback", "Retours")) {
                Toggle(isOn: $live) {
                    Label { Text(L.tr("Live transcript preview", "Aperçu de transcription en direct")) } icon: { IconBadge(symbol: "eye", color: .teal) }
                }
                Toggle(isOn: $sounds) {
                    Label { Text(L.tr("Sounds (beeps)", "Sons (bips)")) } icon: { IconBadge(symbol: "speaker.wave.2", color: .pink) }
                }
                Toggle(isOn: $mute) {
                    Label { Text(L.tr("Mute system audio while recording", "Couper le son pendant l'enregistrement")) } icon: { IconBadge(symbol: "speaker.slash", color: .orange) }
                }
            }

            Section(L.tr("Shortcuts", "Raccourcis")) {
                shortcutRow(L.tr("Start / stop dictation", "Démarrer / arrêter la dictée"), Config.scDictation.display, "waveform", .blue)
                shortcutRow(L.tr("Cancel", "Annuler"), Config.scCancel.display, "xmark", .red)
                shortcutRow(L.tr("Paste last dictation", "Coller la dernière dictée"), Config.scPasteLast.display, "doc.on.clipboard", .gray)
                shortcutRow(L.tr("Rewrite selected text", "Reformuler la sélection"), Config.scSummarize.display, "text.badge.star", .purple)
                Button(L.tr("Edit shortcuts…", "Modifier les raccourcis…")) { model.onEditShortcuts?() }
            }

            Section(L.tr("Interface", "Interface")) {
                Picker(selection: $uiLang) {
                    Text("English").tag("en")
                    Text("Français").tag("fr")
                } label: {
                    Label { Text(L.tr("Language", "Langue")) } icon: { IconBadge(symbol: "character.bubble", color: .blue) }
                }
                .onChange(of: uiLang) { _, _ in model.onUILanguageChange?() }

                Toggle(isOn: $launchAtLogin) {
                    Label { Text(L.tr("Launch at login", "Lancer au démarrage")) } icon: { IconBadge(symbol: "power", color: .green) }
                }
                .onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            }

            Section(L.tr("Permissions", "Autorisations")) {
                permissionRow(L.tr("Accessibility (paste)", "Accessibilité (coller)"), Permissions.accessibilityGranted, "hand.point.up.left", .blue) { Permissions.openAccessibilitySettings() }
                permissionRow(L.tr("Input Monitoring (Fn)", "Surveillance des saisies (Fn)"), Permissions.inputMonitoringGranted, "keyboard", .gray) { Permissions.openInputMonitoringSettings() }
                permissionRow(L.tr("Microphone", "Microphone"), nil, "mic", .red) { Permissions.openMicrophoneSettings() }
                permissionRow(L.tr("Speech Recognition (preview)", "Reconnaissance vocale (aperçu)"), Permissions.speechGranted, "waveform.badge.mic", .orange) { Permissions.openSpeechSettings() }
            }

            Section {
                Button(L.tr("Open Murmure folder", "Ouvrir le dossier Murmure")) {
                    NSWorkspace.shared.open(Config.supportDir)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L.tr("Settings", "Réglages"))
        .frame(minWidth: 480, minHeight: 420)
        .task { model.scan() }
    }

    private func downloadRow(title: String, id: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            if model.downloading.contains(id) {
                ProgressView(value: model.downloadPct[id] ?? 0).frame(width: 90)
            } else {
                Button(L.tr("Download", "Télécharger"), action: action)
            }
        }
    }

    private func shortcutRow(_ title: String, _ key: String, _ symbol: String, _ color: Color) -> some View {
        Button { model.onEditShortcuts?() } label: {
            LabeledContent {
                HStack(spacing: 6) {
                    Text(key).font(.system(.body, design: .rounded)).foregroundStyle(.secondary)
                    Image(systemName: "pencil").font(.caption).foregroundStyle(.tertiary)
                }
            } label: {
                Label { Text(title) } icon: { IconBadge(symbol: symbol, color: color) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func permissionRow(_ title: String, _ granted: Bool?, _ symbol: String, _ color: Color, action: @escaping () -> Void) -> some View {
        HStack {
            Label { Text(title) } icon: { IconBadge(symbol: symbol, color: color) }
            Spacer()
            if let granted {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
            }
            Button(L.tr("Open", "Ouvrir"), action: action)
        }
    }
}
