import AppKit

/// Fenêtre « Commandes » : réassigne chaque raccourci.
/// Clique sur un raccourci → appuie sur la nouvelle combinaison (Échap annule la saisie).
/// Avertit (alerte + indicateur rouge) si deux commandes partagent le même raccourci.
final class CommandsWindowController: NSWindowController, NSWindowDelegate {

    private struct Spec {
        let title: String
        let allowsModifierOnly: Bool      // seule la dictée accepte un modificateur seul (Fn)
        let get: () -> Shortcut
        let set: (Shortcut) -> Void
    }

    private let specs: [Spec] = [
        Spec(title: L.tr("Start / stop dictation", "Démarrer / arrêter la dictée"), allowsModifierOnly: true,
             get: { Config.scDictation }, set: { Config.scDictation = $0 }),
        Spec(title: L.tr("Cancel (dictation or processing)", "Annuler (dictée ou traitement)"), allowsModifierOnly: false,
             get: { Config.scCancel }, set: { Config.scCancel = $0 }),
        Spec(title: L.tr("Paste last dictation", "Coller la dernière dictée"), allowsModifierOnly: false,
             get: { Config.scPasteLast }, set: { Config.scPasteLast = $0 }),
        Spec(title: L.tr("Rewrite selected text", "Reformuler le texte sélectionné"), allowsModifierOnly: false,
             get: { Config.scSummarize }, set: { Config.scSummarize = $0 }),
    ]

    /// Ordre de priorité de déclenchement dans FnHotkey : dictée > coller > reformuler > annuler.
    /// Index `specs` → rang (0 = plus prioritaire). En cas de doublon, seul le plus prioritaire agit.
    private let priorityRank: [Int] = [0, 3, 1, 2]

    private var setHotkeyRecording: ((Bool) -> Void)?
    private var onChange: (() -> Void)?

    private let stack = NSStackView()
    private var buttons: [Int: NSButton] = [:]
    private let warningLabel = NSTextField(labelWithString: "")
    private var currentConflicts: Set<Int> = []
    private var monitor: Any?
    private var recordingIndex: Int?

    convenience init(setHotkeyRecording: @escaping (Bool) -> Void, onChange: @escaping () -> Void) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = L.tr("Commands", "Commandes")
        self.init(window: win)
        self.setHotkeyRecording = setHotkeyRecording
        self.onChange = onChange
        win.delegate = self
        buildUI()
        win.center()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])

        let intro = NSTextField(labelWithString: L.tr("Click a shortcut, then press the new key combination.", "Clique sur un raccourci, puis appuie sur la nouvelle combinaison."))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        stack.addArrangedSubview(intro)

        for (i, spec) in specs.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: spec.title)
            label.font = .systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingTail
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let btn = NSButton(title: spec.get().display, target: self, action: #selector(recordTapped(_:)))
            btn.bezelStyle = .rounded
            btn.tag = i
            btn.setContentHuggingPriority(.required, for: .horizontal)
            btn.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
            buttons[i] = btn

            row.addArrangedSubview(label)
            row.addArrangedSubview(btn)
            row.widthAnchor.constraint(equalToConstant: 416).isActive = true
            stack.addArrangedSubview(row)
        }

        warningLabel.font = .systemFont(ofSize: 12, weight: .medium)
        warningLabel.textColor = .systemRed
        warningLabel.maximumNumberOfLines = 0
        warningLabel.lineBreakMode = .byWordWrapping
        warningLabel.preferredMaxLayoutWidth = 416
        warningLabel.isHidden = true
        warningLabel.widthAnchor.constraint(equalToConstant: 416).isActive = true
        stack.addArrangedSubview(warningLabel)

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        let reset = NSButton(title: L.tr("Reset", "Réinitialiser"), target: self, action: #selector(resetTapped))
        reset.bezelStyle = .rounded
        let note = NSTextField(labelWithString: L.tr("Esc cancels the capture.", "Échap annule la saisie."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        footer.addArrangedSubview(reset)
        footer.addArrangedSubview(note)
        stack.addArrangedSubview(footer)

        refreshConflictUI()
    }

    /// Texte centré du bouton, dans une couleur donnée (sert aussi à l'état « en saisie »).
    private func setButtonText(_ i: Int, _ text: String, color: NSColor) {
        guard let btn = buttons[i] else { return }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        btn.attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: para,
        ])
    }

    private func updateButton(_ i: Int) {
        setButtonText(i, specs[i].get().display, color: currentConflicts.contains(i) ? .systemRed : .labelColor)
    }

    // MARK: - Enregistrement d'un raccourci

    @objc private func recordTapped(_ sender: NSButton) {
        let wasRecording = (recordingIndex == sender.tag)
        stopRecording(restore: true)          // arrête toute saisie en cours
        guard !wasRecording else { return }   // re-clic = on annule simplement
        recordingIndex = sender.tag
        setButtonText(sender.tag, L.tr("Press the shortcut…", "Appuie sur le raccourci…"), color: .secondaryLabelColor)
        setHotkeyRecording?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleRecord(event)
            return nil // on consomme tout pendant la saisie (pas de bip, pas d'action)
        }
    }

    private func handleRecord(_ event: NSEvent) {
        guard let index = recordingIndex else { return }
        let spec = specs[index]

        if event.type == .keyDown {
            if event.keyCode == 53 { stopRecording(restore: true); return } // Échap = annuler
            finishWith(Shortcut(keyCode: Int(event.keyCode), modifiers: comboFlags(event.modifierFlags)), index: index)
            return
        }

        // flagsChanged : Fn seul (uniquement pour la dictée).
        if event.type == .flagsChanged, spec.allowsModifierOnly {
            let f = event.modifierFlags
            if f.contains(.function), !f.contains(.command), !f.contains(.option),
               !f.contains(.control), !f.contains(.shift) {
                finishWith(Shortcut(keyCode: -1, modifiers: Shortcut.fn), index: index)
            }
        }
    }

    private func comboFlags(_ f: NSEvent.ModifierFlags) -> UInt64 {
        var m: UInt64 = 0
        if f.contains(.command) { m |= Shortcut.cmd }
        if f.contains(.option)  { m |= Shortcut.opt }
        if f.contains(.control) { m |= Shortcut.ctrl }
        if f.contains(.shift)   { m |= Shortcut.shift }
        return m
    }

    /// Arrête la capture, affiche le candidat, puis valide (avec contrôle de conflit) au tour suivant
    /// du runloop — pour ne pas lancer une alerte modale depuis le callback du moniteur d'événements.
    private func finishWith(_ sc: Shortcut, index: Int) {
        stopRecording(restore: false)
        setButtonText(index, sc.display, color: .labelColor)
        DispatchQueue.main.async { [weak self] in
            // Si une nouvelle saisie a démarré entre-temps, on n'ouvre pas l'alerte par-dessus.
            guard let self, self.recordingIndex == nil else { return }
            self.applyCandidate(sc, index: index)
        }
    }

    private func applyCandidate(_ sc: Shortcut, index: Int) {
        if let other = conflictingIndex(for: sc, excluding: index) {
            if !warnConflict(new: sc, command: specs[index].title, other: specs[other].title) {
                updateButton(index) // annulé → on remet l'ancien
                return
            }
        }
        specs[index].set(sc)
        onChange?()
        refreshConflictUI()
    }

    private func stopRecording(restore: Bool) {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if restore, let i = recordingIndex { updateButton(i) }
        recordingIndex = nil
        setHotkeyRecording?(false)
    }

    @objc private func resetTapped() {
        stopRecording(restore: true)
        Config.resetShortcuts()
        onChange?()
        refreshConflictUI()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording(restore: true)
    }

    // MARK: - Conflits (même raccourci sur deux commandes)

    private func conflictingIndex(for sc: Shortcut, excluding idx: Int) -> Int? {
        specs.indices.first { $0 != idx && specs[$0].get() == sc }
    }

    /// Groupes d'indices partageant exactement le même raccourci (au moins deux par groupe).
    private func conflictGroups() -> [[Int]] {
        var byKey: [String: [Int]] = [:]
        for (i, spec) in specs.enumerated() {
            let sc = spec.get()
            byKey["\(sc.keyCode)|\(sc.modifiers)", default: []].append(i)
        }
        return byKey.values.filter { $0.count > 1 }.map { $0.sorted() }
    }

    private func refreshConflictUI() {
        let groups = conflictGroups()
        currentConflicts = Set(groups.flatMap { $0 })
        for i in specs.indices where recordingIndex != i { updateButton(i) }

        if groups.isEmpty {
            warningLabel.isHidden = true
            warningLabel.stringValue = ""
        } else {
            // Avertit, et précise quelle action l'emporte (priorité dictée→coller→reformuler→annuler).
            let descs = groups.map { grp -> String in
                let winner = grp.min { priorityRank[$0] < priorityRank[$1] }!
                let names = grp.map { L.tr("“\(specs[$0].title)”", "« \(specs[$0].title) »") }
                    .joined(separator: L.tr(" and ", " et "))
                return L.tr("\(names) → only “\(specs[winner].title)” will fire",
                            "\(names) → seul « \(specs[winner].title) » fonctionnera")
            }
            warningLabel.stringValue = L.tr("⚠︎ Same shortcut: ", "⚠︎ Même raccourci : ") + descs.joined(separator: " ; ")
            warningLabel.isHidden = false
        }
        resizeToFit()
    }

    /// Ajuste la hauteur de la fenêtre (non redimensionnable) au contenu, en gardant le bord haut fixe —
    /// pour que l'avertissement multi-lignes ne soit jamais tronqué.
    private func resizeToFit() {
        guard let win = window else { return }
        win.contentView?.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height)
        let topY = win.frame.maxY
        win.setContentSize(NSSize(width: 460, height: height))
        var f = win.frame
        f.origin.y = topY - f.height
        win.setFrameOrigin(f.origin)
    }

    private func warnConflict(new sc: Shortcut, command: String, other: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L.tr("Shortcut already used", "Raccourci déjà utilisé")
        alert.informativeText = L.tr(
            "\(sc.display) is already assigned to “\(other)”. If you keep it for “\(command)” too, one of the two actions won't fire.",
            "\(sc.display) est déjà attribué à « \(other) ». Si tu le gardes aussi pour « \(command) », l'une des deux actions ne se déclenchera pas.")
        alert.addButton(withTitle: L.tr("Replace anyway", "Remplacer quand même"))
        let cancel = alert.addButton(withTitle: L.tr("Cancel", "Annuler"))
        cancel.keyEquivalent = "\u{1b}" // Échap
        return alert.runModal() == .alertFirstButtonReturn
    }
}
