import AppKit

/// Petit toast discret (bas-droit de l'écran) affiché quand un mot est ajouté au vocabulaire,
/// avec une poubelle pour annuler l'ajout. Disparaît tout seul après 15 s.
final class VocabToast {
    private let panel: NSPanel
    private let effect = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private let trash = NSButton()
    private var timer: Timer?

    /// Appelé si l'utilisateur clique la poubelle.
    var onUndo: (() -> Void)?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.ignoresMouseEvents = false // poubelle cliquable
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 13
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        panel.contentView = effect

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)

        trash.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Annuler l'ajout")
        trash.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        trash.isBordered = false
        trash.bezelStyle = .regularSquare
        trash.imagePosition = .imageOnly
        trash.contentTintColor = .secondaryLabelColor
        trash.translatesAutoresizingMaskIntoConstraints = false
        trash.target = self
        trash.action = #selector(undoTapped)
        effect.addSubview(trash)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            trash.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            trash.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -10),
            trash.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            trash.widthAnchor.constraint(equalToConstant: 16),
            trash.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    func show(terms: [String]) {
        guard !terms.isEmpty else { return }
        label.stringValue = message(for: terms)
        sizeAndPlace()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in self?.hide() }
    }

    @objc private func undoTapped() {
        onUndo?()
        hide()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        panel.orderOut(nil)
    }

    private func message(for terms: [String]) -> String {
        terms.count == 1 ? L.tr("“\(terms[0])” added to vocabulary", "« \(terms[0]) » ajouté au vocabulaire")
                         : L.tr("\(terms.count) words added to vocabulary", "\(terms.count) mots ajoutés au vocabulaire")
    }

    private func sizeAndPlace() {
        label.sizeToFit()
        let w = min(360, 12 + label.frame.width + 10 + 16 + 10)
        let h: CGFloat = 30
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: vf.maxX - w - 16, y: vf.minY + 22, width: w, height: h), display: true)
    }
}
