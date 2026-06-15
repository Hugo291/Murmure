import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let recorder = AudioRecorder()
    private let hotkey = FnHotkey()
    private let overlay = OverlayController()
    private let liveTranscriber = LiveTranscriber()
    private let editWatcher = EditWatcher()
    private let vocabToast = VocabToast()
    private var historyWindow: HistoryWindowController?
    private var commandsWindow: CommandsWindowController?
    private var settingsWindow: SettingsWindowController?
    private var mainWindow: MainWindowController?

    /// La dictée en cours d'enregistrement (une seule à la fois ; nil si on n'enregistre pas).
    private var recordingJob: DictationJob?
    /// Tous les jobs actifs : l'enregistrement + ceux en cours de traitement (parallèles).
    private var jobs: [DictationJob] = []
    private var isRecording: Bool { recordingJob != nil }
    private var trackTimer: Timer? // suivi en direct des pastilles

    /// File de collage SÉRIALISÉE : les dictées sont collées une par une, dans l'ordre de
    /// démarrage, pour ne pas mélanger le texte ni se marcher dessus sur le presse-papiers.
    private var pasteQueue: [(job: DictationJob, text: String)] = []
    private var pasting = false

    // Catalogue dynamique des modèles INSTALLÉS (listés depuis Ollama / LM Studio, jamais téléchargés).
    private var ollamaModelList: [String] = []
    private var lmStudioModelList: [String] = []
    private var modelsLoading = false
    private var engineTimes: [String: Double] = [:] // "backend|model" → secondes (négatif = indispo)
    private var testingEngines = false
    private var testingKey: String?                  // "backend|model" en cours de test (pour l'indicateur …)

    // Rebuild différé du menu si on veut le régénérer pendant qu'il est ouvert.
    private var menuIsOpen = false
    private var pendingRebuild = false

    // MARK: - Cycle de vie

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        SystemAudio.shared.recoverIfNeeded() // rétablit le son si un crash l'avait laissé coupé

        AudioRecorder.requestPermission { _ in }
        Permissions.promptAccessibility()
        Permissions.promptInputMonitoring()
        LiveTranscriber.requestAuthorization() // reconnaissance vocale on-device (aperçu temps réel)

        recorder.onLevels = { [weak self] levels in self?.overlay.updateLevels(levels) }
        recorder.onBuffer = { [weak self] buf in self?.liveTranscriber.append(buf) }
        liveTranscriber.onText = { [weak self] text in self?.overlay.setLive(text) }
        editWatcher.onCorrection = { [weak self] inserted, corrected, id in
            let learned = CorrectionStore.shared.applyCorrection(id: id, inserted: inserted, corrected: corrected)
            guard !learned.isEmpty else { return }
            self?.vocabToast.onUndo = { CorrectionStore.shared.unlearn(learned) }
            self?.vocabToast.show(terms: learned)
        }
        hotkey.onToggle = { [weak self] in self?.handleToggle() }
        hotkey.onCancel = { [weak self] in self?.cancelCurrent() }
        hotkey.onPasteLast = { [weak self] in self?.pasteLast() }
        hotkey.onSummarize = { [weak self] in self?.summarizeSelection() }
        // Échap est consommé (et n'atteint pas l'app au premier plan) tant qu'une dictée est active
        // OU en cours de collage — sinon un Échap pendant les ~0.7 s de collage fuiterait vers le champ.
        hotkey.isActive = { [weak self] in
            guard let self else { return false }
            return !self.jobs.isEmpty || self.pasting || !self.pasteQueue.isEmpty
        }
        hotkey.start()

        // Si le modèle whisper configuré n'existe pas mais qu'un autre est installé, on s'aligne dessus.
        let installed = Config.installedWhisperModels()
        if !installed.contains(Config.whisperModel), let first = installed.first { Config.whisperModel = first }

        rebuildMenu()
        showFirstRunIfNeeded()

        // Catalogue de modèles : scan initial (re-scanné ensuite à chaque ouverture du menu).
        refreshModels()

        buildMainMenu()
        openMain(.accueil)   // vraie app : la fenêtre principale s'ouvre au lancement
    }

    /// Garde l'app vivante (barre de menus + overlay) même quand la fenêtre principale est fermée.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clic sur l'icône du Dock → rouvre la fenêtre principale.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMain(.accueil) }
        return true
    }

    // MARK: - Barre de menus

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let (symbol, color): (String, NSColor?)
        if isRecording { (symbol, color) = ("mic.fill", .systemRed) }
        else if !jobs.isEmpty { (symbol, color) = ("brain.head.profile", .systemOrange) }
        else { (symbol, color) = ("mic", nil) }
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmure")
        if let color {
            let cfg = NSImage.SymbolConfiguration(paletteColors: [color])
            button.image = img?.withSymbolConfiguration(cfg)
            button.image?.isTemplate = false
        } else {
            img?.isTemplate = true
            button.image = img
        }
    }

    private func rebuildMenu() {
        // Ne jamais remplacer le menu pendant qu'il est ouvert (glitch) : on diffère à la fermeture.
        if menuIsOpen { pendingRebuild = true; return }
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        addItem(menu, L.tr("Open Murmure", "Ouvrir Murmure"), #selector(openMainWindow))
        addItem(menu, L.tr("Dictionary & history…", "Dictionnaire & historique…"), #selector(openHistory))
        menu.addItem(.separator())

        // ----- Sous-menu Réglages -----
        let settings = NSMenu()

        // Commandes (raccourcis, modifiables) : sous-menu listant les raccourcis actuels,
        // + un item « Modifier les raccourcis… » qui ouvre l'enregistreur de touches.
        let cmdMenu = NSMenu()
        let commands: [(String, String)] = [
            (L.tr("Start / stop dictation", "Démarrer / arrêter la dictée"), Config.scDictation.display),
            (L.tr("Cancel (dictation or processing)", "Annuler (dictée ou traitement)"), Config.scCancel.display),
            (L.tr("Paste last dictation", "Coller la dernière dictée"), Config.scPasteLast.display),
            (L.tr("Rewrite selected text", "Reformuler le texte sélectionné"), Config.scSummarize.display),
        ]
        for (desc, key) in commands {
            let it = NSMenuItem(title: "\(desc)   —   \(key)", action: nil, keyEquivalent: "")
            it.isEnabled = false
            cmdMenu.addItem(it)
        }
        cmdMenu.addItem(.separator())
        addItem(cmdMenu, L.tr("Edit shortcuts…", "Modifier les raccourcis…"), #selector(openCommands))
        let cmdRoot = NSMenuItem(title: L.tr("Commands", "Commandes"), action: nil, keyEquivalent: "")
        cmdRoot.submenu = cmdMenu
        settings.addItem(cmdRoot)
        settings.addItem(.separator())

        // Retouche IA
        let modeMenu = NSMenu()
        for m in ReformMode.allCases {
            let it = NSMenuItem(title: m.label, action: #selector(setMode(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.rawValue
            it.state = (Config.reformMode == m) ? .on : .off
            modeMenu.addItem(it)
        }
        let modeRoot = NSMenuItem(title: L.tr("AI touch-up", "Retouche IA"), action: nil, keyEquivalent: "")
        modeRoot.submenu = modeMenu
        settings.addItem(modeRoot)

        // Moteur de reformulation : modèles INSTALLÉS listés dynamiquement (Ollama + LM Studio).
        let engineMenu = NSMenu()
        addEngineSection(engineMenu, title: "Ollama", backend: "ollama", models: ollamaModelList)
        if !ollamaModelList.isEmpty && !lmStudioModelList.isEmpty { engineMenu.addItem(.separator()) }
        addEngineSection(engineMenu, title: "LM Studio", backend: "lmstudio", models: lmStudioModelList)
        if ollamaModelList.isEmpty && lmStudioModelList.isEmpty {
            let none = NSMenuItem(title: modelsLoading ? L.tr("Scanning…", "Recherche…")
                                                       : L.tr("No local model found", "Aucun modèle trouvé"),
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            engineMenu.addItem(none)
        }
        engineMenu.addItem(.separator())
        let testItem = NSMenuItem(title: testingEngines ? L.tr("Testing…", "Test en cours…")
                                                        : L.tr("Test current model", "Tester le modèle actuel"),
                                  action: #selector(runEngineTest), keyEquivalent: "")
        testItem.target = self
        testItem.isEnabled = !testingEngines
        engineMenu.addItem(testItem)
        addItem(engineMenu, L.tr("Refresh list", "Rafraîchir la liste"), #selector(refreshModelsAction))

        // Aucun modèle de reformulation pour un moteur → proposer Gemma en un clic (Ollama + LM Studio).
        let hasOllamaGemma = ollamaModelList.contains { $0.lowercased().contains("gemma") }
        let hasLMSGemma = lmStudioModelList.contains { $0.lowercased().contains("gemma") }
        let offerOllama = Config.ollamaBinary() != nil && !hasOllamaGemma
        let offerLMS = Config.lmsBinary() != nil && !hasLMSGemma
        if offerOllama || offerLMS {
            engineMenu.addItem(.separator())
            let dlMenu = NSMenu()
            if offerOllama {
                let busy = ModelDownloader.shared.isDownloading("ollama:gemma3:4b")
                let it = NSMenuItem(title: "Gemma 3 4B   (Ollama, 3.3 GB)" + (busy ? "   …" : ""),
                                    action: busy ? nil : #selector(downloadChat(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = "ollama"; it.isEnabled = !busy
                dlMenu.addItem(it)
            }
            if offerLMS {
                let busy = ModelDownloader.shared.isDownloading("lmstudio:gemma")
                let it = NSMenuItem(title: "Gemma 3 4B   (LM Studio, MLX)" + (busy ? "   …" : ""),
                                    action: busy ? nil : #selector(downloadChat(_:)), keyEquivalent: "")
                it.target = self; it.representedObject = "lmstudio"; it.isEnabled = !busy
                dlMenu.addItem(it)
            }
            let dlRoot = NSMenuItem(title: L.tr("Download a model…", "Télécharger un modèle…"), action: nil, keyEquivalent: "")
            dlRoot.submenu = dlMenu
            engineMenu.addItem(dlRoot)
        }

        let modelRoot = NSMenuItem(title: L.tr("AI engine", "Moteur IA"), action: nil, keyEquivalent: "")
        modelRoot.submenu = engineMenu
        settings.addItem(modelRoot)

        // Modèle de TRANSCRIPTION (whisper) : modèles installés dans le dossier support.
        let whisperMenu = NSMenu()
        let whisperInstalled = Config.installedWhisperModels()
        if whisperInstalled.isEmpty {
            let it = NSMenuItem(title: L.tr("No model installed", "Aucun modèle installé"), action: nil, keyEquivalent: "")
            it.isEnabled = false
            whisperMenu.addItem(it)
        } else {
            for f in whisperInstalled {
                let it = NSMenuItem(title: Config.whisperLabel(f), action: #selector(setWhisperModel(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = f
                it.state = (Config.whisperModel == f) ? .on : .off
                whisperMenu.addItem(it)
            }
        }
        // Modèles whisper recommandés NON installés → téléchargement en un clic.
        let whisperToGet = Config.whisperCatalog.filter { !whisperInstalled.contains($0.file) }
        if !whisperToGet.isEmpty {
            whisperMenu.addItem(.separator())
            let dlMenu = NSMenu()
            for item in whisperToGet {
                let busy = ModelDownloader.shared.isDownloading("whisper:" + item.file)
                let it = NSMenuItem(title: "\(item.name)   (\(item.size))" + (busy ? "   …" : ""),
                                    action: busy ? nil : #selector(downloadWhisper(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = item.file
                it.isEnabled = !busy
                dlMenu.addItem(it)
            }
            let dlRoot = NSMenuItem(title: L.tr("Download a model…", "Télécharger un modèle…"), action: nil, keyEquivalent: "")
            dlRoot.submenu = dlMenu
            whisperMenu.addItem(dlRoot)
        }

        let whisperRoot = NSMenuItem(title: L.tr("Transcription model", "Modèle de transcription"), action: nil, keyEquivalent: "")
        whisperRoot.submenu = whisperMenu
        settings.addItem(whisperRoot)

        // Langue de DICTÉE (ce que whisper transcrit)
        let langMenu = NSMenu()
        for (code, label) in [("fr", L.tr("French", "Français")), ("en", L.tr("English", "Anglais")), ("auto", L.tr("Auto", "Auto"))] {
            let it = NSMenuItem(title: label, action: #selector(setLang(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = code
            it.state = (Config.language == code) ? .on : .off
            langMenu.addItem(it)
        }
        let langRoot = NSMenuItem(title: L.tr("Dictation language", "Langue de dictée"), action: nil, keyEquivalent: "")
        langRoot.submenu = langMenu
        settings.addItem(langRoot)

        // Langue de l'INTERFACE (menus, toasts, fenêtres)
        let uiLangMenu = NSMenu()
        for l in AppLanguage.allCases {
            let it = NSMenuItem(title: l.nativeName, action: #selector(setUILang(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.rawValue
            it.state = (L.lang == l) ? .on : .off
            uiLangMenu.addItem(it)
        }
        let uiLangRoot = NSMenuItem(title: L.tr("Language", "Langue"), action: nil, keyEquivalent: "")
        uiLangRoot.submenu = uiLangMenu
        settings.addItem(uiLangRoot)

        settings.addItem(.separator())

        let sounds = NSMenuItem(title: L.tr("Sounds (beeps)", "Sons (bips)"), action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = Config.playSounds ? .on : .off
        settings.addItem(sounds)

        let mute = NSMenuItem(title: L.tr("Mute system audio while recording", "Couper le son pendant l'enregistrement"), action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = Config.muteWhileRecording ? .on : .off
        settings.addItem(mute)

        let live = NSMenuItem(title: L.tr("Live transcript preview", "Aperçu de transcription en direct"), action: #selector(toggleLive), keyEquivalent: "")
        live.target = self
        live.state = Config.liveTranscript ? .on : .off
        settings.addItem(live)

        settings.addItem(.separator())

        // Autorisations
        let permMenu = NSMenu()
        addItem(permMenu, L.tr("Accessibility (paste)", "Accessibilité (coller)") + "  \(mark(Permissions.accessibilityGranted))", #selector(openAccessibility))
        addItem(permMenu, L.tr("Input Monitoring (Fn key)", "Surveillance des saisies (Fn)") + "  \(mark(Permissions.inputMonitoringGranted))", #selector(openInputMonitoring))
        addItem(permMenu, L.tr("Microphone…", "Microphone…"), #selector(openMic))
        addItem(permMenu, L.tr("Speech Recognition (live preview)", "Reconnaissance vocale (aperçu)") + "  \(mark(Permissions.speechGranted))", #selector(openSpeech))
        let permRoot = NSMenuItem(title: L.tr("Permissions", "Autorisations"), action: nil, keyEquivalent: "")
        permRoot.submenu = permMenu
        settings.addItem(permRoot)

        let login = NSMenuItem(title: L.tr("Launch at login", "Lancer au démarrage"), action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        settings.addItem(login)

        settings.addItem(.separator())
        addItem(settings, L.tr("Open Murmure folder", "Ouvrir le dossier Murmure"), #selector(openSupport))

        _ = settings // (ancien sous-menu conservé temporairement, non attaché — nettoyage à venir)
        addItem(menu, L.tr("Settings…", "Réglages…"), #selector(openSettings))
        // -------------------------------

        menu.addItem(.separator())
        addItem(menu, L.tr("Quit Murmure", "Quitter Murmure"), #selector(quit))

        menu.delegate = self
        statusItem.menu = menu
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
    }

    /// Ajoute une section de moteur (en-tête + un item par modèle installé) au sous-menu « Moteur IA ».
    private func addEngineSection(_ menu: NSMenu, title: String, backend: String, models: [String]) {
        guard !models.isEmpty else { return }
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let selected = backend == "lmstudio" ? Config.lmstudioModel : Config.ollamaModel
        for model in models {
            var label = "  " + model
            let key = "\(backend)|\(model)"
            if let t = engineTimes[key] {
                label += t < 0 ? L.tr("  (unavailable)", "  (indispo)") : String(format: "  (%.1f s)", t)
            } else if testingEngines && testingKey == key {
                label += "  (…)"
            }
            let it = NSMenuItem(title: label, action: #selector(setEngine(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = (Config.reformBackend == backend && selected == model) ? .on : .off
            menu.addItem(it)
        }
    }

    /// Liste les modèles installés (Ollama + LM Studio) en tâche de fond, puis met le menu à jour.
    private func refreshModels() {
        guard !modelsLoading else { return }
        modelsLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let oll = Reformulator.ollamaModels()
            let lms = Reformulator.lmStudioModels()
            DispatchQueue.main.async {
                guard let self else { return }
                let changed = oll != self.ollamaModelList || lms != self.lmStudioModelList
                self.ollamaModelList = oll
                self.lmStudioModelList = lms
                self.modelsLoading = false
                if changed { self.rebuildMenu() } // rebuildMenu se diffère lui-même si le menu est ouvert
            }
        }
    }

    private func mark(_ ok: Bool) -> String { ok ? "✓" : "✗" }

    private func statusLine() -> String {
        if Config.whisperBinary() == nil { return L.tr("⚠︎ whisper-cli missing", "⚠︎ whisper-cli manquant") }
        if !FileManager.default.fileExists(atPath: Config.modelPath.path) {
            return Config.installedWhisperModels().isEmpty
                ? L.tr("⚠︎ no transcription model", "⚠︎ aucun modèle de transcription")
                : L.tr("⚠︎ pick a transcription model", "⚠︎ choisis un modèle de transcription")
        }
        let key = Config.scDictation.display
        if isRecording { return L.tr("🔴 Recording… (\(key) to stop)", "🔴 Enregistrement… (\(key) pour stopper)") }
        if !jobs.isEmpty { return L.tr("⏳ \(jobs.count) in progress…", "⏳ \(jobs.count) en cours…") }
        return L.tr("● Ready — press \(key)", "● Prêt — appuie sur \(key)")
    }

    private func refreshUI() {
        updateIcon()
        if let first = statusItem.menu?.items.first { first.title = statusLine() }
    }

    // MARK: - Pipeline

    private func handleToggle() {
        if let rec = recordingJob { stopRecording(rec) } else { startRecording() }
    }

    private func startRecording() {
        editWatcher.finalize() // clôt une éventuelle correction de la dictée précédente
        Reformulator.warmUp()  // précharge le modèle pendant que tu parles
        let number = (jobs.map { $0.number }.max() ?? 0) + 1
        let job = DictationJob(number: number)
        job.target.capture() // mémorise où coller AVANT de parler

        guard recorder.start() else {
            play("Basso")
            overlay.notice(job, L.tr("⚠︎ Mic unavailable", "⚠︎ Micro indisponible"), duration: 1.4)
            return
        }
        recordingJob = job
        jobs.append(job)
        ensureTracking()
        play("Tink")
        overlay.showRecording(job)
        if Config.liveTranscript { liveTranscriber.start(localeID: speechLocaleID()) } // aperçu temps réel

        let pos = markerAnchor(for: job)
        job.anchor = pos
        job.marker.setNumber(number > 1 ? number : nil)
        job.marker.onDismiss = { [weak self, weak job] in
            guard let job else { return }
            self?.cancelJob(job)
        }
        job.marker.show(at: pos)

        refreshUI()
        // Coupe le son APRÈS le Tink, et seulement si on enregistre toujours ce job.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.recordingJob === job else { return }
            SystemAudio.shared.mute()
        }
    }

    /// Place la pastille au caret/champ/souris, décalée si elle chevauche une autre pastille active.
    private func markerAnchor(for job: DictationJob) -> CGPoint {
        let base = job.target.anchorPointCocoa() ?? NSEvent.mouseLocation
        let others = jobs.filter { $0 !== job }.map { $0.anchor }
        var off: CGFloat = 0
        var p = base
        while others.contains(where: { hypot($0.x - p.x, $0.y - p.y) < 26 }) {
            off += 28
            p = CGPoint(x: base.x + off, y: base.y)
        }
        job.offsetX = off
        return p
    }

    // MARK: - Suivi en direct des pastilles (le champ peut bouger/grandir)

    private func ensureTracking() {
        guard trackTimer == nil else { return }
        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in self?.trackMarkers() }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func trackMarkers() {
        for job in jobs {
            guard let base = job.target.anchorPointCocoa() else { continue } // garde la dernière position connue
            let p = CGPoint(x: base.x + job.offsetX, y: base.y)
            job.anchor = p
            job.marker.reposition(at: p)
        }
    }

    private func stopTrackingIfIdle() {
        if jobs.isEmpty { trackTimer?.invalidate(); trackTimer = nil }
    }

    private func stopRecording(_ job: DictationJob) {
        SystemAudio.shared.restore()
        let wav = recorder.stop()   // retire le tap d'ABORD → plus aucun buffer vers l'aperçu
        liveTranscriber.stop()      // puis on arrête le moteur d'aperçu (fenêtre de course fermée)
        overlay.hideLive()          // la bande disparaît à la fin du transcript
        recordingJob = nil

        guard let wav else { // trop court → on jette ce job
            overlay.remove(job)
            job.marker.hide()
            removeJob(job)
            refreshUI()
            return
        }
        job.wav = wav
        play("Pop")
        overlay.showProcessing(job)              // carte « réfléchit » dans la pile
        job.marker.setIcon("brain.head.profile") // pastille → cerveau (traitement LLM)
        refreshUI()
        processJob(job, wav: wav)
    }

    private func processJob(_ job: DictationJob, wav: URL) {
        let token = job.token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let raw = try Transcriber.transcribe(wav, token: token)
                if token.cancelled { return }
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    DispatchQueue.main.async { if !token.cancelled { self.finishJob(job, error: L.tr("Nothing was heard.", "Rien n'a été entendu.")) } }
                    return
                }
                let final = Reformulator.process(trimmed, mode: Config.reformMode, token: token)
                if token.cancelled { return }
                DispatchQueue.main.async {
                    guard !token.cancelled else { return }
                    self.markReady(job, text: final)
                }
            } catch {
                DispatchQueue.main.async { if !token.cancelled { self.finishJob(job, error: "\(error)") } }
            }
        }
    }

    /// Le traitement d'un job est terminé : on mémorise son texte et on tente de vider la file.
    private func markReady(_ job: DictationJob, text: String) {
        job.readyText = text
        flushDeliveries()
    }

    /// La prochaine dictée livrable = la PLUS ANCIENNE (numéro le plus petit) si elle est prête.
    /// Une dictée prête attend que toutes celles démarrées AVANT elle soient livrées (ou annulées),
    /// pour que le texte reste dans l'ordre où on l'a dicté.
    private func nextDeliverable() -> (DictationJob, String)? {
        guard let first = jobs.min(by: { $0.number < $1.number }) else { return nil }
        guard first !== recordingJob, let text = first.readyText else { return nil }
        return (first, text)
    }

    /// Sort de `jobs` toutes les dictées prêtes, dans l'ordre, et les met en file de collage.
    private func flushDeliveries() {
        while let (job, text) = nextDeliverable() {
            job.readyText = nil
            job.marker.hide()
            removeJob(job)
            pasteQueue.append((job, text))
        }
        pumpPaste()
        refreshUI()
    }

    /// Colle les dictées de la file UNE PAR UNE (chacune attend que la précédente ait atterri).
    private func pumpPaste() {
        guard !pasting, !pasteQueue.isEmpty else { return }
        pasting = true
        let (job, text) = pasteQueue.removeFirst()
        var finished = false
        let finish: () -> Void = { [weak self] in
            guard let self, !finished else { return } // une seule fois (collage normal OU watchdog)
            finished = true
            self.pasting = false
            self.pumpPaste()
        }
        // Filet de sécurité : si un collage ne rappelait jamais son done(), la file ne gèle pas.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: finish)
        performPaste(job, text, done: finish)
    }

    private func performPaste(_ job: DictationJob, _ text: String, done: @escaping () -> Void) {
        let id = CorrectionStore.shared.addTranscript(text)

        guard Permissions.accessibilityGranted else {
            // Pas d'accessibilité → on ne peut pas coller : presse-papiers + invite.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            overlay.notice(job, L.tr("Copied — ⌘V to paste", "Copié — ⌘V pour coller"), duration: 1.8)
            Permissions.promptAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done() }
            return
        }

        let confirmed = editWatcher.isFocusedElementEditable()   // champ vu par l'AX (natif)
        let needsRefocus = !confirmed && job.target.hasTarget    // curseur parti ailleurs → ramener la cible
        // Sûr d'avoir un champ ? Sinon (input web non vu par l'AX) on garde le texte au presse-papiers en secours.
        let keepClip = !(confirmed || job.target.hasTarget)

        let doPaste: () -> Void = { [weak self] in
            guard let self else { done(); return }
            let valueBefore = self.editWatcher.focusedValue()
            TextInserter.insert(text, keepOnClipboard: keepClip)
            // Confirmation à chaque livraison (sur la carte du job).
            self.overlay.notice(job, keepClip ? L.tr("Copied — ⌘V to paste", "Copié — ⌘V pour coller") : L.tr("Pasted", "Collé"),
                                 duration: keepClip ? 1.8 : 1.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.editWatcher.startWatching(inserted: text, valueBefore: valueBefore, transcriptID: id)
            }
            // Laisse le ⌘V atterrir et le presse-papiers se restaurer avant la dictée suivante.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { done() }
        }

        if needsRefocus, job.target.refocus() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: doPaste)
        } else {
            doPaste() // colle dans le focus courant : champ natif, OU input web que l'AX ne voit pas
        }
    }

    private func finishJob(_ job: DictationJob, error: String) {
        job.marker.hide()
        removeJob(job)
        play("Basso")
        overlay.notice(job, "⚠︎ " + String(error.prefix(34)), duration: 1.6)
        flushDeliveries() // une dictée ultérieure prête peut maintenant passer
        NSLog("Murmure: \(error)")
    }

    /// Clic sur une pastille → annule CE job (audio jeté, ou whisper/Ollama tué).
    private func cancelJob(_ job: DictationJob) {
        if job === recordingJob {
            recorder.cancel()
            SystemAudio.shared.restore()
            liveTranscriber.stop()
            overlay.hideLive()
            recordingJob = nil
        } else {
            job.token.cancel()
        }
        job.marker.hide()
        removeJob(job)
        play("Funk")
        overlay.notice(job, L.tr("Cancelled", "Annulé"), duration: 0.9)
        flushDeliveries() // si on annule une dictée qui bloquait, la suivante prête peut passer
    }

    /// Échap → annule UNIQUEMENT la dictée la plus récente (numéro le plus élevé) : l'enregistrement
    /// en cours s'il y en a un, sinon le dernier traitement lancé. Jamais plusieurs d'un coup.
    private func cancelCurrent() {
        if let rec = recordingJob { cancelJob(rec); return }
        if let last = jobs.max(by: { $0.number < $1.number }) { cancelJob(last) }
    }

    private func removeJob(_ job: DictationJob) {
        jobs.removeAll { $0 === job }
        stopTrackingIfIdle()
    }

    /// Cmd+L → recolle le dernier message dicté au curseur.
    private func pasteLast() {
        guard Permissions.accessibilityGranted, let text = CorrectionStore.shared.lastText else { return }
        TextInserter.insert(text)
    }

    /// Cmd+R → copie la sélection, la fait reformuler par l'IA (idée gardée, tics/répétitions enlevés), et remplace.
    private func summarizeSelection() {
        guard Permissions.accessibilityGranted else { return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents() // vidé pour détecter ce qui sera copié
        TextInserter.sendCopy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self else { return }
            let sel = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sel, !sel.isEmpty else {
                pb.clearContents(); if let saved { pb.setString(saved, forType: .string) } // rien sélectionné
                return
            }
            let token = NSObject()
            self.overlay.showProcessing(token, L.tr("Rewriting…", "Reformulation…"))
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Reformulator.summarize(sel)
                DispatchQueue.main.async {
                    pb.clearContents(); pb.setString(result, forType: .string)
                    TextInserter.sendPaste()
                    self.overlay.notice(token, L.tr("Rewritten", "Reformulé"), duration: 1.0)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        pb.clearContents(); if let saved { pb.setString(saved, forType: .string) }
                    }
                }
            }
        }
    }

    private func play(_ name: String) {
        guard Config.playSounds else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Actions menu

    @objc private func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = ReformMode(rawValue: raw) {
            Config.reformMode = m
            rebuildMenu()
        }
    }

    @objc private func setEngine(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let parts = s.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        Config.reformBackend = parts[0]
        if parts[0] == "lmstudio" { Config.lmstudioModel = parts[1] } else { Config.ollamaModel = parts[1] }
        rebuildMenu()
    }

    /// Mesure le temps de réponse du modèle ACTUELLEMENT sélectionné et l'affiche dans le menu.
    @objc private func runEngineTest() {
        guard !testingEngines else { return }
        testingEngines = true
        let backend = Config.reformBackend
        let model = backend == "lmstudio" ? Config.lmstudioModel : Config.ollamaModel
        let key = "\(backend)|\(model)"
        testingKey = key
        engineTimes[key] = nil
        rebuildMenu()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let t = Reformulator.benchmark(backend: backend, model: model)
            DispatchQueue.main.async {
                self?.engineTimes[key] = t ?? -1
                self?.testingEngines = false
                self?.testingKey = nil
                self?.rebuildMenu()
            }
        }
    }

    @objc private func refreshModelsAction() { refreshModels() }

    @objc private func setWhisperModel(_ sender: NSMenuItem) {
        if let f = sender.representedObject as? String { Config.whisperModel = f; rebuildMenu() }
    }

    /// Télécharge un modèle de transcription whisper (Hugging Face) puis l'active automatiquement.
    @objc private func downloadWhisper(_ sender: NSMenuItem) {
        guard let file = sender.representedObject as? String,
              let item = Config.whisperCatalog.first(where: { $0.file == file }) else { return }
        let token = NSObject()
        let dl = L.tr("Downloading", "Téléchargement de")
        overlay.progressNote(token, "\(dl) \(item.name)…")
        ModelDownloader.shared.downloadWhisper(
            file: file, url: Config.whisperURL(file), label: item.name,
            progress: { [weak self] frac, name in
                let pct = frac.map { " \(Int(($0 * 100).rounded()))%" } ?? "…"
                self?.overlay.progressNote(token, "\(dl) \(name)\(pct)")
            },
            done: { [weak self] ok in
                guard let self else { return }
                if ok {
                    Config.whisperModel = file
                    self.overlay.notice(token, "\(item.name) " + L.tr("ready", "prêt"), duration: 1.8)
                } else {
                    self.overlay.notice(token, "⚠︎ " + L.tr("Download failed", "Échec du téléchargement"), duration: 2.2)
                }
                self.rebuildMenu()
            })
        rebuildMenu()   // reflète l'état « … » et désactive l'item
    }

    /// Télécharge un modèle de reformulation (Gemma) pour Ollama ou LM Studio, puis le sélectionne.
    @objc private func downloadChat(_ sender: NSMenuItem) {
        guard let backend = sender.representedObject as? String else { return }
        let token = NSObject()
        let name = backend == "ollama" ? "Gemma (Ollama)" : "Gemma (LM Studio)"
        let dl = L.tr("Downloading", "Téléchargement de")
        overlay.progressNote(token, "\(dl) \(name)…")
        let progress: (Double?, String) -> Void = { [weak self] frac, _ in
            let pct = frac.map { " \(Int(($0 * 100).rounded()))%" } ?? "…"
            self?.overlay.progressNote(token, "\(dl) \(name)\(pct)")
        }
        let done: (Bool) -> Void = { [weak self] ok in
            guard let self else { return }
            if ok { self.selectDownloadedChat(backend: backend, token: token, name: name) }
            else {
                self.overlay.notice(token, "⚠︎ " + L.tr("Download failed", "Échec du téléchargement"), duration: 2.2)
                self.rebuildMenu()
            }
        }
        if backend == "ollama" {
            ModelDownloader.shared.downloadOllama(model: "gemma3:4b", progress: progress, done: done)
        } else {
            ModelDownloader.shared.downloadLMStudio(search: "gemma", progress: progress, done: done)
        }
        rebuildMenu()
    }

    /// Après téléchargement d'un modèle de chat : re-scanne et sélectionne le Gemma fraîchement installé.
    private func selectDownloadedChat(backend: String, token: AnyObject, name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let oll = Reformulator.ollamaModels()
            let lms = Reformulator.lmStudioModels()
            DispatchQueue.main.async {
                guard let self else { return }
                self.ollamaModelList = oll
                self.lmStudioModelList = lms
                if backend == "ollama", let g = oll.first(where: { $0.lowercased().contains("gemma") }) {
                    Config.reformBackend = "ollama"; Config.ollamaModel = g
                } else if backend == "lmstudio", let g = lms.first(where: { $0.lowercased().contains("gemma") }) {
                    Config.reformBackend = "lmstudio"; Config.lmstudioModel = g
                }
                self.overlay.notice(token, "\(name) " + L.tr("ready", "prêt"), duration: 1.8)
                self.rebuildMenu()
            }
        }
    }

    @objc private func setLang(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { Config.language = code; rebuildMenu() }
    }

    /// Change la langue de l'INTERFACE et recrée les fenêtres pour qu'elles l'adoptent.
    @objc private func setUILang(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String, let l = AppLanguage(rawValue: code) else { return }
        L.lang = l
        historyWindow?.window?.close(); historyWindow = nil
        commandsWindow?.window?.close(); commandsWindow = nil
        rebuildMenu()
    }

    @objc private func toggleSounds() { Config.playSounds.toggle(); rebuildMenu() }

    @objc private func toggleMute() { Config.muteWhileRecording.toggle(); rebuildMenu() }

    @objc private func toggleLive() {
        Config.liveTranscript.toggle()
        if !Config.liveTranscript { liveTranscriber.stop(); overlay.hideLive() }
        rebuildMenu()
    }

    /// Locale pour la reconnaissance vocale on-device (suit la langue de dictée).
    private func speechLocaleID() -> String {
        switch Config.language {
        case "fr": return "fr-FR"
        case "en": return "en-US"
        default:   return Locale.current.identifier
        }
    }

    @objc private func openAccessibility() { Permissions.openAccessibilitySettings() }
    @objc private func openInputMonitoring() { Permissions.openInputMonitoringSettings() }
    @objc private func openMic() { Permissions.openMicrophoneSettings() }
    @objc private func openSpeech() { Permissions.openSpeechSettings() }

    @objc private func openMainWindow() { openMain(.accueil) }
    @objc private func showSection(_ sender: NSMenuItem) {
        let s = AppSection.allCases
        if sender.tag >= 0, sender.tag < s.count { openMain(s[sender.tag]) }
    }
    @objc private func openHistory()    { openMain(.dictionnaire) }
    @objc private func openSettings()   { openMain(.reglages) }

    /// Ouvre (ou crée) la fenêtre principale sur la section voulue.
    private func openMain(_ section: AppSection) {
        if mainWindow == nil {
            let w = MainWindowController()
            w.onClose = { [weak self] in self?.mainWindow = nil }   // libère le contrôleur à la fermeture
            w.settings.onEditShortcuts = { [weak self] in self?.openCommands() }
            w.settings.onUILanguageChange = { [weak self] in
                guard let self else { return }
                let s = self.mainWindow?.nav.section ?? .reglages
                self.commandsWindow?.window?.close(); self.commandsWindow = nil
                self.rebuildMenu()
                // Recrée la fenêtre dans la nouvelle langue (L n'est pas observable par SwiftUI).
                DispatchQueue.main.async {
                    self.mainWindow?.close()      // déclenche onClose → mainWindow = nil
                    self.openMain(s)
                }
            }
            mainWindow = w
        }
        mainWindow?.show(section)
    }

    /// Menu principal de l'app (App + Édition + Fenêtre) — nécessaire pour une vraie app .regular.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L.tr("About Murmure", "À propos de Murmure"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.tr("Hide Murmure", "Masquer Murmure"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L.tr("Quit Murmure", "Quitter Murmure"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L.tr("Edit", "Édition"))
        edit.addItem(withTitle: L.tr("Undo", "Annuler"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L.tr("Redo", "Rétablir"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L.tr("Cut", "Couper"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L.tr("Copy", "Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L.tr("Paste", "Coller"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L.tr("Select All", "Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: L.tr("View", "Présentation"))
        for (i, s) in AppSection.allCases.enumerated() {
            let it = NSMenuItem(title: s.title, action: #selector(showSection(_:)), keyEquivalent: "\(i + 1)")
            it.tag = i; it.target = self
            viewMenu.addItem(it)
        }
        viewItem.submenu = viewMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: L.tr("Window", "Fenêtre"))
        win.addItem(withTitle: L.tr("Minimize", "Réduire"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: L.tr("Zoom", "Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fs = NSMenuItem(title: L.tr("Enter Full Screen", "Activer le mode plein écran"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        win.addItem(fs)
        winItem.submenu = win

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc private func openCommands() {
        if commandsWindow == nil {
            commandsWindow = CommandsWindowController(
                setHotkeyRecording: { [weak self] on in self?.hotkey.recording = on },
                onChange: { [weak self] in
                    self?.hotkey.refresh()  // relit Config + réarme la bascule
                    self?.rebuildMenu()     // met à jour les libellés du sous-menu Commandes
                }
            )
        }
        commandsWindow?.show()
    }

    @objc private func openSupport() {
        NSWorkspace.shared.open(Config.supportDir)
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Murmure: login item: \(error)")
        }
        rebuildMenu()
    }

    @objc private func quit() {
        SystemAudio.shared.restore()
        hotkey.stop()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemAudio.shared.restore() // filet de sécurité : ne jamais laisser le son coupé
    }

    // MARK: - Premier lancement

    private func showFirstRunIfNeeded() {
        let key = "didShowWelcome"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let a = NSAlert()
        a.messageText = L.tr("Welcome to Murmure 🎙️", "Bienvenue dans Murmure 🎙️")
        a.informativeText = L.tr("""
        Local voice dictation. Press Fn to start recording, press Fn again to \
        transcribe and paste at the cursor.

        For it to work, allow these in System Settings:
        • Microphone
        • Input Monitoring (to read the Fn key)
        • Accessibility (to paste the text)

        Tip: System Settings › Keyboard › “Press 🌐/Fn key to” → “Do Nothing”,
        and turn off “Press Fn twice to start dictation”.
        """, """
        Dictée vocale locale. Appuie sur Fn pour démarrer l'enregistrement, \
        ré-appuie sur Fn pour transcrire et coller au curseur.

        Pour que ça marche, autorise dans Réglages Système :
        • Microphone
        • Surveillance des saisies (lire la touche Fn)
        • Accessibilité (coller le texte)

        Conseil : Réglages › Clavier › « Appuyer sur 🌐/Fn pour » → « Ne rien faire »,
        et désactive « Appuyer deux fois sur Fn pour dicter ».
        """)
        a.addButton(withTitle: L.tr("Open settings", "Ouvrir les réglages"))
        a.addButton(withTitle: L.tr("Later", "Plus tard"))
        if a.runModal() == .alertFirstButtonReturn {
            Permissions.openInputMonitoringSettings()
        }
    }
}

// MARK: - Menu : rafraîchissement des modèles à l'ouverture

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        refreshModels() // re-scanne Ollama/LM Studio ; le résultat s'applique à la fermeture si la liste change
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if pendingRebuild { pendingRebuild = false; rebuildMenu() }
    }
}
