import AppKit

/// Pastille « faux curseur » ancrée là où la transcription sera collée.
/// Rond d'accent (micro pendant l'enregistrement → cerveau pendant le traitement) avec un
/// petit × blanc dans le coin haut-droit. Cliquer la pastille annule la destination (« pas ici »).
/// Reste affichée pendant toute la dictée, sur le bureau (Space) de départ.
final class MicMarker {
    private let panel: NSPanel
    private let dot = MarkerDotView()
    private let img = NSImageView()
    private let badge = NSImageView()
    private let numberLabel = NSTextField(labelWithString: "")
    private var anchor = CGPoint.zero
    private static let size: CGFloat = 22

    /// Appelé quand l'utilisateur clique la pastille (« ne colle pas ici »).
    var onDismiss: (() -> Void)?

    init() {
        let s = MicMarker.size
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: s, height: s),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.ignoresMouseEvents = false // pastille cliquable
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.stationary, .fullScreenAuxiliary] // reste sur le bureau de départ

        dot.frame = NSRect(x: 0, y: 0, width: s, height: s)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dot.layer?.cornerRadius = s / 2
        dot.onClick = { [weak self] in self?.onDismiss?() }

        img.frame = NSRect(x: 5, y: 5, width: s - 10, height: s - 10)
        img.contentTintColor = .white
        img.imageScaling = .scaleProportionallyUpOrDown
        img.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        dot.addSubview(img)

        // Petit × blanc (sans fond), coin haut-droit, à l'intérieur du rond.
        let b: CGFloat = 8
        badge.frame = NSRect(x: s - b - 3, y: s - b - 3, width: b, height: b)
        badge.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Annuler la destination")
        badge.contentTintColor = .white
        badge.imageScaling = .scaleProportionallyDown
        badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 6, weight: .bold)
        dot.addSubview(badge)

        // Numéro (annotation « 2 », « 3 »…) dans le coin bas-droit, affiché si > 1.
        numberLabel.font = .systemFont(ofSize: 9, weight: .bold)
        numberLabel.textColor = .white
        numberLabel.alignment = .center
        numberLabel.frame = NSRect(x: s - 11, y: 1, width: 10, height: 11)
        numberLabel.isHidden = true
        dot.addSubview(numberLabel)

        panel.contentView = dot
    }

    /// Affiche un numéro (« 2 »…) si `n != nil`, sinon rien.
    func setNumber(_ n: Int?) {
        if let n {
            numberLabel.stringValue = "\(n)"
            numberLabel.isHidden = false
        } else {
            numberLabel.isHidden = true
        }
    }

    /// `point` : position écran Cocoa (origine bas-gauche). La pastille se place juste au-dessus.
    func show(at point: CGPoint) {
        anchor = point
        setIcon("waveform")   // pastille = même motif spectre que le HUD
        place()
        addPulse()
        panel.orderFrontRegardless()
    }

    /// Déplace la pastille (suivi en direct) sans toucher à l'icône ni à l'animation.
    func reposition(at point: CGPoint) {
        anchor = point
        place()
    }

    func setIcon(_ symbol: String) {
        img.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    func hide() {
        dot.layer?.removeAnimation(forKey: "pulse")
        panel.orderOut(nil)
    }

    private func place() {
        let s = MicMarker.size
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        var x = anchor.x - s / 2
        var y = anchor.y + 5
        if let f = screen?.frame {
            if y + s > f.maxY { y = anchor.y - s - 5 }
            x = min(max(x, f.minX + 2), f.maxX - s - 2)
            y = min(max(y, f.minY + 2), f.maxY - s - 2)
        }
        panel.setFrame(NSRect(x: x, y: y, width: s, height: s), display: true)
    }

    private func addPulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
    }

    /// Convertit un rectangle AX (origine haut-gauche) en point Cocoa au sommet du rectangle.
    static func cocoaPoint(fromAXCaret axRect: CGRect) -> CGPoint? {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        guard let h = primary?.frame.maxY else { return nil }
        return CGPoint(x: axRect.midX, y: h - axRect.origin.y)
    }
}

/// Rond cliquable (tout le rond capte le clic → `onClick`).
final class MarkerDotView: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
}
