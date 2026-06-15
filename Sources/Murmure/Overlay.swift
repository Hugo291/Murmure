import AppKit

/// Pile de toasts en bas-centre. La dictée la plus récente est GRANDE en haut (spectre si elle
/// enregistre, « réfléchit » sinon) ; les précédentes sont RÉDUITES en dessous (max 3 visibles),
/// avec animation de réduction/glissement. Chaque toast est rattaché à un job (AnyObject).
final class OverlayController {
    private let panel: NSPanel
    private let container = NSView()
    private var cards: [(key: ObjectIdentifier, card: ToastCard)] = [] // index 0 = plus récent (haut)
    private static let maxVisible = 3
    private static let size = NSSize(width: 380, height: 210)

    // Bande d'aperçu de transcription EN TEMPS RÉEL, affichée AU-DESSUS des toasts pendant qu'on parle.
    private let liveBand = NSView()   // conteneur TRANSPARENT de l'aperçu (aucun fond, juste le texte)
    private let liveText = NSTextField(labelWithString: "")
    private var cardsTopY: CGFloat = 0 // hauteur de la pile de cartes (repère du bas de la bande live)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: OverlayController.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        container.frame = NSRect(origin: .zero, size: OverlayController.size)
        container.wantsLayer = true
        panel.contentView = container

        // Bande d'aperçu : conteneur SANS fond (transparent). Seul le texte est visible.
        liveBand.wantsLayer = true
        liveBand.isHidden = true
        container.addSubview(liveBand)

        liveText.font = .systemFont(ofSize: 13, weight: .medium)
        liveText.textColor = .labelColor
        liveText.alignment = .center
        liveText.maximumNumberOfLines = 3
        liveText.lineBreakMode = .byTruncatingHead
        liveText.cell?.wraps = true
        liveText.cell?.isScrollable = false
        liveText.isBordered = false
        liveText.drawsBackground = false
        // Sans fond, on garde la lisibilité avec une ombre/halo doux (façon sous-titres),
        // dont la couleur suit l'apparence : halo clair en mode clair, sombre en mode sombre.
        liveText.wantsLayer = true
        let halo = NSShadow()
        halo.shadowColor = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return dark ? NSColor.black.withAlphaComponent(0.65) : NSColor.white.withAlphaComponent(0.9)
        }
        halo.shadowBlurRadius = 4
        halo.shadowOffset = NSSize(width: 0, height: -1)
        liveText.shadow = halo
        liveBand.addSubview(liveText)
    }

    // MARK: - Aperçu temps réel

    /// Met à jour la bande d'aperçu (texte partiel de la reconnaissance on-device). Vide → masque.
    func setLive(_ text: String) {
        let t = liveTail(text)
        guard !t.isEmpty else { hideLive(); return }
        liveText.stringValue = t
        if liveBand.isHidden { liveBand.alphaValue = 0; liveBand.isHidden = false }
        layoutLive()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; liveBand.animator().alphaValue = 1 }
    }

    /// Masque l'aperçu (fin de dictée / annulation).
    func hideLive() {
        guard !liveBand.isHidden else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; self.liveBand.animator().alphaValue = 0 },
            completionHandler: { [weak self] in
                guard let self, self.liveBand.alphaValue == 0 else { return } // un setLive a pu re-montrer la bande
                self.liveBand.isHidden = true; self.liveText.stringValue = ""
            })
    }

    /// Garde la fin du texte (les derniers mots), pour ne pas déborder.
    private func liveTail(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 170 else { return trimmed }
        let cut = String(trimmed.suffix(170))
        if let sp = cut.firstIndex(of: " ") { return "…" + cut[cut.index(after: sp)...] }
        return "…" + cut
    }

    private func layoutLive() {
        guard !liveBand.isHidden else { return }
        let w = OverlayController.size.width
        let boxW = min(CGFloat(360), w - 16)
        let inset: CGFloat = 12
        liveText.preferredMaxLayoutWidth = boxW - inset * 2
        let fit = liveText.sizeThatFits(NSSize(width: boxW - inset * 2, height: 120))
        let y = cardsTopY + 10
        // Ne jamais dépasser le haut du panel (cas rare : 3 cartes empilées + aperçu long).
        let maxH = OverlayController.size.height - y - 6
        let boxH = max(28, min(min(78, maxH), fit.height + 14))
        liveBand.frame = NSRect(x: (w - boxW) / 2, y: y, width: boxW, height: boxH)
        liveText.frame = NSRect(x: inset, y: 7, width: boxW - inset * 2, height: boxH - 14)
    }

    // MARK: - API (par job)

    func showRecording(_ owner: AnyObject) { show(owner, .recording) }
    func showProcessing(_ owner: AnyObject, _ text: String = L.tr("Thinking…", "Le modèle réfléchit…")) { show(owner, .processing(text)) }

    func updateLevels(_ levels: [Float]) { cards.first?.card.setLevels(levels) } // seule la carte du haut enregistre

    /// Carte de PROGRESSION persistante (téléchargement de modèle) : texte mis à jour,
    /// SANS auto-retrait. Conclure avec `notice(owner, …)` (qui programme le retrait) ou `remove(owner)`.
    func progressNote(_ owner: AnyObject, _ text: String) {
        let key = ObjectIdentifier(owner)
        if cardFor(key) == nil { show(owner, .notice(text)) }
        else { cardFor(key)?.setMode(.notice(text)); relayout() }
    }

    /// Message bref (Collé / Copié / Annulé / erreur) sur la carte du job, puis on la retire.
    func notice(_ owner: AnyObject, _ text: String, duration: TimeInterval = 1.2) {
        let key = ObjectIdentifier(owner)
        if cards.first(where: { $0.key == key }) == nil { show(owner, .notice(text)) }
        else { cardFor(key)?.setMode(.notice(text)); relayout() }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.remove(owner) }
    }

    func remove(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        guard let idx = cards.firstIndex(where: { $0.key == key }) else { return }
        let card = cards[idx].card
        cards.remove(at: idx)
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.18; card.animator().alphaValue = 0 },
                                             completionHandler: { card.removeFromSuperview() })
        relayout()
        if cards.isEmpty {
            liveBand.isHidden = true; liveText.stringValue = ""
            panel.orderOut(nil)
        }
    }

    // MARK: - Interne

    private func cardFor(_ key: ObjectIdentifier) -> ToastCard? { cards.first { $0.key == key }?.card }

    private func show(_ owner: AnyObject, _ mode: ToastCard.Mode) {
        let key = ObjectIdentifier(owner)
        if let card = cardFor(key) {
            card.setMode(mode)
        } else {
            let card = ToastCard()
            card.alphaValue = 0
            container.addSubview(card)
            card.setMode(mode)
            cards.insert((key, card), at: 0)
        }
        // Remonter ce job au sommet (le plus récent).
        if let idx = cards.firstIndex(where: { $0.key == key }), idx != 0 {
            cards.insert(cards.remove(at: idx), at: 0)
        }
        reposition()
        relayout()
        panel.orderFrontRegardless()
    }

    private func reposition() {
        guard let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let s = OverlayController.size
        panel.setFrame(NSRect(x: vf.midX - s.width / 2, y: vf.minY + 22, width: s.width, height: s.height), display: true)
    }

    private func relayout() {
        let w = OverlayController.size.width
        // Pile ANCRÉE EN BAS : hauteur totale des cartes visibles, puis placement depuis son sommet.
        // Quand une carte disparaît, les autres REDESCENDENT vers le bas de l'écran.
        let visible = min(cards.count, OverlayController.maxVisible)
        var y: CGFloat = 0
        for i in 0..<visible { y += OverlayController.cardSize(i).height }
        y += CGFloat(max(0, visible - 1)) * 6
        cardsTopY = y // sommet de la pile = bas de la bande d'aperçu
        layoutLive()
        for (i, item) in cards.enumerated() {
            let card = item.card
            guard i < OverlayController.maxVisible else {
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; card.animator().alphaValue = 0 }
                continue
            }
            let cs = OverlayController.cardSize(i)
            card.compact = (i != 0)
            y -= cs.height
            let target = NSRect(x: (w - cs.width) / 2, y: y, width: cs.width, height: cs.height)
            y -= 6
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                card.animator().frame = target
                card.animator().alphaValue = (i == 0) ? 1.0 : (i == 1 ? 0.85 : 0.6)
                card.layoutNow()
            }
        }
    }

    private static func cardSize(_ i: Int) -> NSSize {
        switch i {
        case 0:  return NSSize(width: 340, height: 52)
        case 1:  return NSSize(width: 286, height: 38)
        default: return NSSize(width: 238, height: 32)
        }
    }
}

// MARK: - Une carte

/// Pastille d'accent du HUD : cercle accent + glyphe blanc.
/// `wave` = transcription (whisper), `brain` = traitement LLM, `check` = terminé.
final class WaveBadge: NSView {
    enum Glyph { case wave, brain, check }
    var glyph: Glyph = .wave { didSet { needsDisplay = true } }

    override init(frame f: NSRect) { super.init(frame: f); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let b = bounds
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: b).fill()
        switch glyph {
        case .wave:
            NSColor.white.setFill()
            let heights: [CGFloat] = [0.30, 0.50, 0.30]
            let bw: CGFloat = 2.3, gap: CGFloat = 2.3
            var x = b.midX - (bw * 3 + gap * 2) / 2
            for hf in heights {
                let hh = b.height * hf
                NSBezierPath(roundedRect: NSRect(x: x, y: b.midY - hh / 2, width: bw, height: hh),
                             xRadius: bw / 2, yRadius: bw / 2).fill()
                x += bw + gap
            }
        case .brain:
            drawSymbol("brain.head.profile", in: b)
        case .check:
            let p = NSBezierPath()
            p.lineWidth = 2.0; p.lineCapStyle = .round; p.lineJoinStyle = .round
            NSColor.white.setStroke()
            p.move(to: NSPoint(x: b.width * 0.30, y: b.height * 0.50))
            p.line(to: NSPoint(x: b.width * 0.44, y: b.height * 0.36))
            p.line(to: NSPoint(x: b.width * 0.70, y: b.height * 0.66))
            p.stroke()
        }
    }

    /// Dessine un SF Symbol blanc, centré (pour le cerveau du traitement LLM).
    private func drawSymbol(_ name: String, in b: NSRect) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: b.height * 0.56, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let img = base.withSymbolConfiguration(cfg) ?? base
        let s = img.size
        img.draw(in: NSRect(x: b.midX - s.width / 2, y: b.midY - s.height / 2, width: s.width, height: s.height))
    }
}

final class ToastCard: NSView {
    enum Mode: Equatable { case recording, processing(String), notice(String) }

    private(set) var mode: Mode = .processing("")
    var compact = false { didSet { layoutNow() } }

    private let effect = NSVisualEffectView()
    private let badge = WaveBadge()
    private let bars = BarsView()
    private let info = NSTextField(labelWithString: "")    // info à droite : minuteur / « réfléchit… »
    private let notice = NSTextField(labelWithString: "")  // message centré (Collé, Annulé…)
    private var recStart: Date?
    private var clock: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Vrai matériau système (Liquid Glass), adaptatif clair/sombre.
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = ToastCard.roundedMask(radius: 16)
        addSubview(effect)

        badge.wantsLayer = true
        addSubview(badge)
        addSubview(bars)

        info.font = .systemFont(ofSize: 12.5, weight: .medium)
        info.textColor = .secondaryLabelColor
        info.alignment = .right
        info.isBordered = false; info.drawsBackground = false
        addSubview(info)

        notice.font = .systemFont(ofSize: 13, weight: .medium)
        notice.textColor = .labelColor
        notice.alignment = .center
        notice.maximumNumberOfLines = 1
        notice.lineBreakMode = .byTruncatingTail
        notice.isBordered = false; notice.drawsBackground = false
        addSubview(notice)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setMode(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .recording:
            badge.isHidden = false; badge.glyph = .wave; addBadgePulse()
            bars.isHidden = false; bars.start(.spectrum)
            info.isHidden = false
            notice.isHidden = true
            startClock()
        case .processing:
            badge.isHidden = false; badge.glyph = .brain; removeBadgePulse()   // traitement LLM = cerveau
            bars.isHidden = false; bars.start(.calm)      // spectre apaisé = « réfléchit » (pas un spinner)
            info.isHidden = false; info.stringValue = L.tr("thinking…", "réfléchit…")
            notice.isHidden = true
            stopClock()
        case .notice(let t):
            badge.isHidden = true; removeBadgePulse()
            bars.isHidden = true; bars.stop()
            info.isHidden = true
            notice.isHidden = false; notice.stringValue = t
            stopClock()
        }
        layoutNow()
    }

    func setLevels(_ levels: [Float]) { bars.setTargets(levels) }

    private func startClock() {
        recStart = Date(); updateClock()
        clock?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateClock() }
        RunLoop.main.add(t, forMode: .common); clock = t
    }
    private func stopClock() { clock?.invalidate(); clock = nil; recStart = nil }
    private func updateClock() {
        guard let s = recStart else { return }
        let e = Int(Date().timeIntervalSince(s))
        info.stringValue = "\(e / 60):" + String(format: "%02d", e % 60)
    }

    func layoutNow() {
        effect.frame = bounds
        let h = bounds.height, w = bounds.width
        if !notice.isHidden {
            notice.frame = NSRect(x: 10, y: (h - 16) / 2, width: w - 20, height: 16)
            return
        }
        let bz: CGFloat = compact ? 22 : 28
        badge.frame = NSRect(x: 14, y: (h - bz) / 2, width: bz, height: bz)
        let iw = min(info.intrinsicContentSize.width + 2, 92)
        info.frame = NSRect(x: w - 14 - iw, y: (h - 16) / 2, width: iw, height: 16)
        let bx = 14 + bz + 10
        bars.frame = NSRect(x: bx, y: 0, width: max(0, (w - 14 - iw - 8) - bx), height: h)
    }

    override func layout() { super.layout(); layoutNow() }

    private func addBadgePulse() {
        let p = CABasicAnimation(keyPath: "opacity")
        p.fromValue = 1.0; p.toValue = 0.4; p.duration = 0.85
        p.autoreverses = true; p.repeatCount = .infinity
        badge.layer?.add(p, forKey: "pulse")
    }
    private func removeBadgePulse() { badge.layer?.removeAnimation(forKey: "pulse") }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 2
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}

// MARK: - Spectre

final class BarsView: NSView {
    enum Style { case spectrum, calm }
    private let barCount = 28
    private var style: Style = .spectrum
    private var phase: Float = 0
    private var targets: [Float]
    private var current: [Float]
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        targets = [Float](repeating: 0, count: barCount)
        current = [Float](repeating: 0, count: barCount)
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setTargets(_ levels: [Float]) {
        guard style == .spectrum else { return }
        let n = min(levels.count, barCount)
        for i in 0..<n { targets[i] = levels[i] }
    }

    func start(_ style: Style) {
        self.style = style
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        for i in 0..<barCount { current[i] = 0; targets[i] = 0 }
        phase = 0
        needsDisplay = true
    }

    private func tick() {
        if style == .calm {
            // Vague douce qui ondule : pas de spinner, le spectre lui-même « respire ».
            phase += 0.16
            for i in 0..<barCount {
                let s = 0.5 + 0.5 * sin(Double(phase) + Double(i) * 0.45)
                targets[i] = Float(0.12 + 0.20 * s)
            }
        }
        let k: Float = style == .calm ? 0.22 : 0.35
        for i in 0..<barCount { current[i] += (targets[i] - current[i]) * k }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let barW: CGFloat = 3, gap: CGFloat = 2.6
        let total = barW * CGFloat(barCount) + gap * CGFloat(barCount - 1)
        let startX = (b.width - total) / 2          // faisceau centré, barres fines (façon Apple)
        guard startX >= -total else { return }
        let maxH = b.height - 14
        let midY = b.midY
        let accent = NSColor.controlAccentColor
        for i in 0..<barCount {
            let level = CGFloat(max(0.0, current[i]))
            let hgt = max(2.5, level * maxH)
            let x = startX + CGFloat(i) * (barW + gap)
            let rect = NSRect(x: x, y: midY - hgt / 2, width: barW, height: hgt)
            accent.withAlphaComponent(0.5 + 0.5 * level).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
