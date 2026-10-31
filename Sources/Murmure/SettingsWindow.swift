import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

/// Glisser-déposer d'un moteur : la ligne survolée prend la place de celle qu'on glisse, en direct ;
/// l'ordre est enregistré à chaque déplacement (un lâcher hors liste garde donc le dernier ordre vu).
private struct EngineDropDelegate: DropDelegate {
    let target: String
    @Binding var engines: [String]
    @Binding var dragged: String?

    func dropEntered(info: DropInfo) {
        guard let d = dragged, d != target,
              let from = engines.firstIndex(of: d), let to = engines.firstIndex(of: target) else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            engines.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
        Config.engineOrder = engines
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// Fenêtre « Réglages » — liste groupée façon macOS (Form .grouped), icônes teintées,
/// toggles, pickers. Remplace le gros sous-menu de la barre de menus.
final class SettingsWindowController: NSWindowController {
    let model = SettingsModel()

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
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
    @Published var benchTimes: [String: Double] = [:] // « moteur|modèle » → secondes (négatif = indisponible)
    @Published var testingKey: String?                // moteur en cours de test (indicateur sur sa ligne)

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
        let done: (Bool) -> Void = { [weak self] ok in
            self?.downloading.remove(id); self?.downloadPct[id] = nil
            if ok {
                DispatchQueue.global(qos: .userInitiated).async {
                    let oll = Reformulator.ollamaModels(), lms = Reformulator.lmStudioModels()
                    if let key = Reformulator.gemmaKey(backend: backend, ollama: oll, lmStudio: lms) {
                        DispatchQueue.main.async { Config.promoteEngine(key) }
                    }
                }
            }
            self?.scan()
        }
        if backend == "ollama" {
            ModelDownloader.shared.downloadOllama(model: "gemma3:4b", progress: progress, done: done)
        } else {
            ModelDownloader.shared.downloadLMStudio(search: "gemma", progress: progress, done: done)
        }
    }

    /// Temps de réponse de chaque moteur, dans l'ordre de la liste ; chacun s'affiche sur sa ligne.
    func benchmark() {
        guard !benchmarking else { return }
        benchmarking = true; benchTimes = [:]
        let keys = Config.engineOrder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for key in keys {
                guard let engine = Reformulator.Engine(key: key) else { continue }
                DispatchQueue.main.async { self?.testingKey = key }
                let secs = Reformulator.benchmark(engine)
                DispatchQueue.main.async { self?.benchTimes[key] = secs ?? -1 }
            }
            DispatchQueue.main.async {
                self?.benchmarking = false
                self?.testingKey = nil
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
    @State private var retainAudio = Config.retainAudio
    @ObservedObject var model: SettingsModel

    @AppStorage("reformMode") private var reformMode = "light"
    @AppStorage("language") private var dictationLang = "fr"
    @AppStorage("uiLanguage") private var uiLang = "en"
    @AppStorage("liveTranscript") private var live = true
    @AppStorage("showModel") private var showModel = true
    @AppStorage("playSounds") private var sounds = true
    @AppStorage("muteWhileRecording") private var mute = true
    @AppStorage("whisperModel") private var whisperModel = "ggml-large-v3-turbo.bin"
    @AppStorage("gpuAuto") private var gpuAuto = true
    @State private var engines = Config.engineOrder
    @State private var draggedEngine: String?
    @AppStorage("screenContext") private var screenContext = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    // Éditeur de prompts système : quel prompt on édite + son contenu courant.
    @State private var promptKind: PromptKind = .light
    @State private var promptLight = Config.promptLight
    @State private var promptFull = Config.promptFull
    @State private var promptSummarize = Config.promptSummarize

    private enum PromptKind: String, CaseIterable, Identifiable {
        case light, full, summarize
        var id: String { rawValue }
        var title: String {
            switch self {
            case .light:     return L.tr("Light", "Légère")
            case .full:      return L.tr("Full", "Complète")
            case .summarize: return L.tr("Selection ⌘R", "Sélection ⌘R")
            }
        }
    }

    /// Binding vers le prompt en cours d'édition (selon l'onglet segmenté).
    private var currentPrompt: Binding<String> {
        switch promptKind {
        case .light:     return $promptLight
        case .full:      return $promptFull
        case .summarize: return $promptSummarize
        }
    }

    /// Restaure le prompt affiché à sa valeur d'usine.
    private func resetCurrentPrompt() {
        switch promptKind {
        case .light:     promptLight = Config.defaultPromptLight
        case .full:      promptFull = Config.defaultPromptFull
        case .summarize: promptSummarize = Config.defaultPromptSummarize
        }
    }

    // MARK: Moteurs de retouche (maquette : https://claude.ai/artifact/9EVm58Ad22gBU7bqQh7KnB)

    private enum EngineState { case ok, serverOff, missing }

    /// Nom du modèle, moteur, icône et couleur de sa famille (MLX, CPU, Cloud).
    private func engineInfo(_ key: String) -> (model: String, detail: String, symbol: String, color: Color) {
        switch Reformulator.Engine(key: key) {
        case .lmStudio(let m)?:   return (m, "LM Studio · GPU", "square.stack.3d.up.fill", .purple)
        case .ollama(let m, let cpu)?:
            return cpu ? (m, "Ollama · CPU", "cpu", .gray) : (m, "Ollama · MLX (GPU)", "bolt.fill", .indigo)
        case .ollamaCloud(let m)?: return (m, "Ollama Cloud · ollama.com", "cloud.fill", .cyan)
        case nil:                  return (key, "", "questionmark", .gray)
        }
    }

    /// Serveur éteint (sa liste de modèles est vide) ou modèle absent de cette liste.
    private func engineState(_ key: String) -> EngineState {
        let k = Reformulator.Engine(key: key)?.key ?? key
        let list = k.hasPrefix("lmstudio|") ? model.lmStudioModels.map { "lmstudio|\($0)" }
                                             : model.ollamaModels.map(Reformulator.ollamaKey)
        if list.isEmpty { return .serverOff }
        return list.contains(k) ? .ok : .missing
    }

    private func setEngines(_ keys: [String]) {
        engines = keys
        Config.engineOrder = keys
    }

    private func moveEngine(_ key: String, by delta: Int) {
        guard let i = engines.firstIndex(of: key), engines.indices.contains(i + delta) else { return }
        var e = engines
        e.swapAt(i, i + delta)
        setEngines(e)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
    }

    /// Une ligne : poignée, rang, famille, modèle, état, temps du dernier test, retrait.
    /// Glisser la ligne la déplace (l'ordre est enregistré à chaque déplacement) ; clic droit : monter, descendre…
    private func engineRow(_ key: String, rank: Int, used: Bool) -> some View {
        let info = engineInfo(key)
        let state = engineState(key)
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .help(L.tr("Drag to reorder", "Glisser pour réordonner"))
            Text("\(rank)")
                .font(.system(size: 11, weight: .bold)).monospacedDigit()
                .foregroundStyle(rank == 1 ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(rank == 1 ? Color.accentColor : Color.secondary.opacity(0.2)))
            IconBadge(symbol: info.symbol, color: info.color)
                .opacity(state == .ok ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.model).foregroundStyle(state == .ok ? .primary : .secondary)
                Text(info.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch state {
            case .serverOff: chip(L.tr("server off", "serveur éteint"), .yellow)
            case .missing:   chip(L.tr("not found", "introuvable"), .yellow)
            case .ok:        if used { chip(L.tr("in use", "utilisé"), .green) }
            }
            if key.hasPrefix("ollamacloud|") || Reformulator.isCloud(info.model) { chip("Cloud", .cyan) }
            Group {
                if model.testingKey == key {
                    ProgressView().controlSize(.small)
                } else if let t = model.benchTimes[key] {
                    Text(t < 0 ? L.tr("unavailable", "indisponible") : String(format: "%.1f s", t))
                        .foregroundStyle(t < 0 ? Color.orange : Color.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .font(.caption).monospacedDigit()
            .frame(width: 72, alignment: .trailing)
            Button { setEngines(engines.filter { $0 != key }) } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L.tr("Remove from the list", "Retirer de la liste"))
            .accessibilityLabel(L.tr("Remove \(info.model)", "Retirer \(info.model)"))
        }
        .contentShape(Rectangle())
        .onDrag {
            draggedEngine = key
            return NSItemProvider(object: key as NSString)
        }
        .onDrop(of: [.text], delegate: EngineDropDelegate(target: key, engines: $engines, dragged: $draggedEngine))
        .contextMenu {
            Button(L.tr("Move to top", "Mettre en tête")) { setEngines([key] + engines.filter { $0 != key }) }
                .disabled(rank == 1)
            Button(L.tr("Move up", "Monter")) { moveEngine(key, by: -1) }.disabled(rank == 1)
            Button(L.tr("Move down", "Descendre")) { moveEngine(key, by: 1) }.disabled(rank == engines.count)
            Divider()
            Button(L.tr("Remove", "Retirer"), role: .destructive) { setEngines(engines.filter { $0 != key }) }
        }
    }

    /// Un menu « Ajouter » par famille ; les modèles déjà dans la liste y sont cochés et grisés.
    private func familyMenu(_ title: String, symbol: String, keys: [String], note: String? = nil) -> some View {
        Menu {
            Section(note ?? "") {
                if keys.isEmpty { Text(L.tr("No model installed", "Aucun modèle installé")) }
                ForEach(keys, id: \.self) { key in
                    let added = engines.contains(key)
                    Button { setEngines(engines + [key]) } label: {
                        if added { Label(engineInfo(key).model, systemImage: "checkmark") } else { Text(engineInfo(key).model) }
                    }
                    .disabled(added)
                }
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private var addBar: some View {
        let oll = model.ollamaModels
        return HStack(spacing: 8) {
            Text(L.tr("Add", "Ajouter")).font(.caption).foregroundStyle(.secondary)
            familyMenu("Ollama · CPU", symbol: "cpu",
                       keys: oll.filter { !Reformulator.isCloud($0) && !Reformulator.isMLX($0) }.map(Reformulator.ollamaKey))
            familyMenu("Ollama Cloud", symbol: "cloud",
                       keys: oll.filter(Reformulator.isCloud).map(Reformulator.ollamaKey),
                       note: L.tr("Dictated text is processed on ollama.com", "Le texte dicté est traité sur ollama.com"))
            familyMenu("Ollama · MLX", symbol: "bolt.fill",
                       keys: oll.filter { !Reformulator.isCloud($0) && Reformulator.isMLX($0) }.map(Reformulator.ollamaKey))
            familyMenu("LM Studio", symbol: "square.stack.3d.up",
                       keys: model.lmStudioModels.map { "lmstudio|\($0)" },
                       note: model.lmStudioModels.isEmpty ? L.tr("LM Studio server is off", "Serveur LM Studio éteint") : nil)
            Spacer()
        }
    }

    var body: some View {
        Form {
            Section(L.tr("Transcription", "Transcription")) {
                Picker(selection: $dictationLang) {
                    Text(L.tr("French", "Français")).tag("fr")
                    Text(L.tr("English", "Anglais")).tag("en")
                    Text(L.tr("Auto", "Auto")).tag("auto")
                } label: {
                    Label { Text(L.tr("Dictation language", "Langue de dictée")) } icon: { IconBadge(symbol: "globe", color: .gray) }
                }
            }

            // UNE seule liste : chaque modèle affiche son état réel (utilisé / installé / à télécharger),
            // pour qu'on voie d'un coup d'œil ce qu'on a déjà et lequel sert vraiment à transcrire.
            Section {
                ForEach(whisperRows, id: \.file) { row in whisperRow(row) }
            } header: {
                Text(L.tr("Transcription model", "Modèle de transcription"))
            } footer: {
                Text(L.tr("Ranked best to worst for dictation. Downloaded from Hugging Face (ggerganov/whisper.cpp).",
                          "Classés du meilleur au moins bon pour la dictée. Téléchargés depuis Hugging Face (ggerganov/whisper.cpp)."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L.tr("AI", "IA")) {
                Picker(selection: $reformMode) {
                    ForEach(ReformMode.allCases, id: \.rawValue) { m in Text(m.label).tag(m.rawValue) }
                } label: {
                    Label { Text(L.tr("AI touch-up", "Retouche IA")) } icon: { IconBadge(symbol: "sparkles", color: .purple) }
                }
                Toggle(isOn: $screenContext) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.tr("Read the screen to fix mis-heard words", "Lire l'écran pour corriger les mots mal entendus"))
                            Text(L.tr("Reuses the names in the visible conversation. Never sent to a Cloud engine.",
                                      "Reprend les noms de la conversation affichée. Jamais envoyé à un moteur Cloud."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { IconBadge(symbol: "eye", color: .orange) }
                }
                Toggle(isOn: $gpuAuto) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.tr("GPU busy: MLX engines last", "GPU occupé : moteurs MLX en dernier"))
                            Text(L.tr("When another app takes the GPU, the touch-up goes through the CPU first.",
                                      "Quand une autre app prend le GPU, la retouche passe d'abord par le CPU."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { IconBadge(symbol: "gauge.with.dots.needle.33percent", color: .teal) }
                }
            }

            Section {
                if engines.isEmpty {
                    Text(L.tr("No engine: add one below.", "Aucun moteur : ajoute-en un ci-dessous."))
                        .foregroundStyle(.secondary)
                }
                let usedKey = engines.first { engineState($0) == .ok }
                ForEach(Array(engines.enumerated()), id: \.element) { i, key in
                    engineRow(key, rank: i + 1, used: key == usedKey)
                }
                addBar
            } header: {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L.tr("Touch-up engines", "Moteurs de retouche"))
                        Text(L.tr("Drag a row to change the order. The first one that answers does the touch-up, the next ones are fallbacks.",
                                  "Glisse une ligne pour changer l'ordre. Le premier qui répond fait la retouche, les suivants servent de repli."))
                            .font(.caption).foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                    Spacer()
                    Button(model.benchmarking ? L.tr("Testing…", "Test…") : L.tr("Test engines", "Tester les moteurs")) {
                        model.benchmark()
                    }
                    .disabled(model.benchmarking || engines.isEmpty)
                    .controlSize(.small)
                    .textCase(nil)
                }
            } footer: {
                Label(L.tr("Ollama Cloud processes the dictated text on ollama.com. Screen content is never sent to it.",
                           "Ollama Cloud traite le texte dicté sur ollama.com. Le contenu de l'écran ne lui est jamais envoyé."),
                      systemImage: "cloud")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if (Config.ollamaBinary() != nil && !model.hasOllamaGemma) || (Config.lmsBinary() != nil && !model.hasLMSGemma) {
                Section {
                    if Config.ollamaBinary() != nil && !model.hasOllamaGemma {
                        downloadRow(title: "Gemma 3 4B · Ollama", id: "ollama:gemma3:4b") { model.downloadChat("ollama") }
                    }
                    if Config.lmsBinary() != nil && !model.hasLMSGemma {
                        downloadRow(title: "Gemma 3 4B · LM Studio (MLX)", id: "lmstudio:gemma") { model.downloadChat("lmstudio") }
                    }
                }
            }

            Section {
                Label {
                    Picker("", selection: $promptKind) {
                        ForEach(PromptKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } icon: { IconBadge(symbol: "text.quote", color: .purple) }

                TextEditor(text: currentPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 150)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                    .onChange(of: promptLight) { _, v in Config.promptLight = v }
                    .onChange(of: promptFull) { _, v in Config.promptFull = v }
                    .onChange(of: promptSummarize) { _, v in Config.promptSummarize = v }

                HStack(alignment: .top) {
                    Text(L.tr("Sent to the local AI as the system prompt. Leave empty to fall back to the default.",
                              "Envoyé à l'IA locale comme prompt système. Laisse vide pour revenir au défaut."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button(L.tr("Reset", "Réinitialiser")) { resetCurrentPrompt() }
                }
            } header: {
                Text(L.tr("Reformulation prompt", "Prompt de reformulation"))
            }

            Section(L.tr("Feedback", "Retours")) {
                Toggle(isOn: $live) {
                    Label { Text(L.tr("Live transcript preview", "Aperçu de transcription en direct")) } icon: { IconBadge(symbol: "eye", color: .teal) }
                }
                Toggle(isOn: $showModel) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L.tr("Show the model under the spectrum", "Afficher le modèle sous le spectre"))
                            Text(L.tr("Transcription model, then touch-up model.", "Modèle de transcription, puis modèle de retouche."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { IconBadge(symbol: "cpu", color: .indigo) }
                }
                Toggle(isOn: $sounds) {
                    Label { Text(L.tr("Sounds (beeps)", "Sons (bips)")) } icon: { IconBadge(symbol: "speaker.wave.2", color: .pink) }
                }
                Toggle(isOn: $mute) {
                    Label { Text(L.tr("Mute system audio while recording", "Couper le son pendant l'enregistrement")) } icon: { IconBadge(symbol: "speaker.slash", color: .orange) }
                }
            }

            Section(L.tr("Audio replay", "Replay audio")) {
                Toggle(L.tr("Keep audio for 20 minutes", "Conserver l’audio pendant 20 minutes"),
                       isOn: $retainAudio)
                    .onChange(of: retainAudio) { _, value in Config.retainAudio = value }
                Text(L.tr("Local storage, limited to 50 MB. Oldest recordings are removed first. Disabling clears saved audio.",
                          "Stockage local limité à 50 Mo. Les plus anciens enregistrements sont supprimés en premier. Désactiver efface l’audio conservé."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(L.tr("Delete saved audio", "Effacer l’audio conservé")) { AudioReplayStore.shared.clear() }
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
        .task {
            model.scan()
            engines = Config.engineOrder
        }
    }

    // MARK: - Modèles de transcription (installés + téléchargeables, dans une seule liste)

    /// Une ligne de la liste des modèles : le catalogue PLUS les fichiers ggml déjà sur le disque.
    private struct WhisperRow {
        let file: String
        let name: String
        let size: String?    // nil pour un fichier posé à la main (taille inconnue du catalogue)
        let installed: Bool
        let rank: Int        // classement du catalogue (0 = meilleur)
    }

    /// Les modèles installés d'abord (celui en service en tête), puis ceux à télécharger.
    private var whisperRows: [WhisperRow] {
        let installed = Set(model.whisperModels)
        var rows: [WhisperRow] = Config.whisperCatalog.enumerated().map { i, item in
            WhisperRow(file: item.file, name: item.name, size: item.size,
                       installed: installed.contains(item.file), rank: i)
        }
        // Fichiers ggml déposés à la main dans le dossier support : listés aussi, pour pouvoir les choisir.
        let known = Set(Config.whisperCatalog.map(\.file))
        rows += installed.subtracting(known).sorted().map {
            WhisperRow(file: $0, name: Config.whisperLabel($0), size: nil,
                       installed: true, rank: Config.whisperCatalog.count)
        }
        // Clé de tri explicite (le tri de Swift n'est pas garanti stable) : en service, puis installés, puis catalogue.
        func key(_ r: WhisperRow) -> (Int, Int, Int) {
            (r.installed && r.file == whisperModel ? 0 : 1, r.installed ? 0 : 1, r.rank)
        }
        return rows.sorted { key($0) < key($1) }
    }

    private func whisperRow(_ row: WhisperRow) -> some View {
        let id = "whisper:" + row.file
        let inUse = row.installed && row.file == whisperModel
        return HStack(spacing: 10) {
            IconBadge(symbol: "waveform", color: inUse ? .blue : (row.installed ? .teal : .gray))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.rank < Config.whisperCatalog.count ? "#\(row.rank + 1)  \(row.name)" : row.name)
                if let size = row.size, let item = Config.whisperCatalog.first(where: { $0.file == row.file }) {
                    Text("\(size) · \(L.tr(item.noteEN, item.noteFR))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.downloading.contains(id), row.file == Config.parakeetID {
                ProgressView().controlSize(.small)   // FluidAudio ne remonte pas de progression
            } else if model.downloading.contains(id) {
                ProgressView(value: model.downloadPct[id] ?? 0).frame(width: 90)
            } else if inUse {
                Label(L.tr("In use", "Utilisé"), systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            } else if row.installed {
                Button(L.tr("Use", "Utiliser")) { whisperModel = row.file }
            } else if let item = Config.whisperCatalog.first(where: { $0.file == row.file }) {
                Button(L.tr("Download", "Télécharger")) { model.downloadWhisper(item) }
            }
        }
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
