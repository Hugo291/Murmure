import AppKit

/// Pile de toasts en bas-centre. La dictée la plus récente est GRANDE en haut (spectre si elle
/// enregistre, « réfléchit » sinon) ; les précédentes sont RÉDUITES en dessous (max 3 visibles),
/// avec animation de réduction/glissement. Chaque toast est rattaché à un job (AnyObject).
final class OverlayController {
    private let panel: NSPanel
    private let container = NSView()
    private var cards: [(key: ObjectIdentifier, card: ToastCard)] = [] // index 0 = plus récent (haut)
    private static let maxVisible = 3
    private static let size = NSSize(width: 380, height: 260)
    /// Marge sous la pile pour que l'ombre des cartes ne soit pas coupée par le bord du panneau.
    private static let shadowPad: CGFloat = 16

    // Bande d'aperçu de transcription EN TEMPS RÉEL, affichée AU-DESSUS des toasts pendant qu'on parle.
    private let liveBand = NSView()   // conteneur TRANSPARENT de l'aperçu (aucun fond, juste le texte)
    private let liveText = NSTextField(labelWithString: "")
    private var cardsTopY: CGFloat = 0 // hauteur de la pile de cartes (repère du bas de la bande live)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: OverlayController.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.level = .statusBar // APRÈS isFloatingPanel (qui remet le niveau à 3, celui de la fenêtre Claude)
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
    /// Carte « réfléchit » : pastille de la phase + « transcription · 1,2 s » sous le spectre.
    func showProcessing(_ owner: AnyObject, _ phase: String, glyph: WaveBadge.Glyph) {
        show(owner, .processing(phase, glyph: glyph))
    }

    /// Change la phase d'une carte « réfléchit » SANS la remonter dans la pile (compteur remis à
    /// zéro). `hint` = rappel de raccourci affiché après le compteur, sur la grande carte seulement.
    func setPhase(_ owner: AnyObject, _ phase: String, glyph: WaveBadge.Glyph, hint: ToastCard.KeyHint? = nil) {
        cardFor(ObjectIdentifier(owner))?.setMode(.processing(phase, glyph: glyph, hint: hint))
    }

    /// Modèle à l'œuvre, affiché après la phase (« retouche · gemma4:e4b-mlx · 1,2 s ») ; le
    /// compteur n'est pas remis à zéro. Ignoré si le réglage « Afficher le modèle » est coupé.
    func setModel(_ owner: AnyObject, _ model: String?) {
        cardFor(ObjectIdentifier(owner))?.model = Config.showModel ? model : nil
    }

    /// Alimente le spectre de la carte qui ENREGISTRE — pas simplement celle du haut :
    /// quand on enchaîne des dictées, la notice « Collé » d'une précédente repasse devant,
    /// et les niveaux partaient alors sur la mauvaise carte (spectre figé).
    func updateLevels(_ levels: [Float]) {
        for item in cards where item.card.mode == .recording {
            item.card.setLevels(levels)
            return
        }
    }

    /// Carte de PROGRESSION persistante (téléchargement de modèle) : texte mis à jour,
    /// SANS auto-retrait. Conclure avec `notice(owner, …)` (qui programme le retrait) ou `remove(owner)`.
    func progressNote(_ owner: AnyObject, _ text: String) {
        let key = ObjectIdentifier(owner)
        if cardFor(key) == nil { show(owner, .notice(text)) }
        else { cardFor(key)?.setMode(.notice(text)); relayout() }
    }

    /// Message bref (Collé / Copié / Annulé / erreur) sur la carte du job, puis on la retire.
    /// `check` = réussite : pastille coche devant le texte (maquette « Collé »).
    func notice(_ owner: AnyObject, _ text: String, duration: TimeInterval = 1.2, check: Bool = false) {
        let key = ObjectIdentifier(owner)
        if cards.first(where: { $0.key == key }) == nil { show(owner, .notice(text, check: check)) }
        else { cardFor(key)?.setMode(.notice(text, check: check)); relayout() }
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

    /// Écran où s'affiche la pile : celui du champ ciblé (pas `NSScreen.main`, qui pour un agent
    /// sans fenêtre renvoie l'écran principal même quand on dicte sur un second écran).
    private var screen: NSScreen?

    /// Suit l'écran qui contient `point` (coordonnées Cocoa) ; sans effet si aucun écran ne le contient.
    func follow(point: CGPoint) {
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return }
        screen = s
        if panel.isVisible { reposition() }
    }

    private func reposition() {
        guard let vf = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let s = OverlayController.size
        // Cartes à 22 pt au-dessus du Dock : le panneau descend de la marge réservée à l'ombre.
        panel.setFrame(NSRect(x: vf.midX - s.width / 2, y: vf.minY + 22 - OverlayController.shadowPad,
                              width: s.width, height: s.height), display: true)
    }

    private func relayout() {
        let w = OverlayController.size.width
        // Pile ANCRÉE EN BAS : hauteur totale des cartes visibles, puis placement depuis son sommet.
        // Quand une carte disparaît, les autres REDESCENDENT vers le bas de l'écran.
        let visible = min(cards.count, OverlayController.maxVisible)
        var y: CGFloat = OverlayController.shadowPad
        for i in 0..<visible { y += OverlayController.cardSize(i).height }
        y += CGFloat(max(0, visible - 1)) * OverlayController.gap
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
            y -= OverlayController.gap
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                card.animator().frame = target
                card.animator().alphaValue = (i == 0) ? 1.0 : (i == 1 ? 0.85 : 0.6)
                card.layoutNow()
            }
        }
    }

    /// Maquette v3 : grande carte 340 × 64, les plus anciennes réduites à 286 × 34, 10 pt entre elles.
    private static let gap: CGFloat = 10
    private static func cardSize(_ i: Int) -> NSSize {
        i == 0 ? NSSize(width: 340, height: 64) : NSSize(width: 286, height: 34)
    }
}

// MARK: - Une carte
//
// Maquette de référence : Claude Design « Composant barre de réflexion Murmure », 2b v3
// (claude.ai/design/p/13f527f0-6307-4261-afd5-2a6db2845b85). Grande carte : pastille + spectre
// sur toute la largeur, puis « phase · temps » CENTRÉ dessous. Cartes réduites : une seule ligne.

/// Pastille d'accent : cercle accent + SF Symbol blanc qui dit la phase.
final class WaveBadge: NSView {
    enum Glyph: Equatable {
        case wave      // enregistrement
        case dots      // transcription (whisper)
        case sparkles  // retouche IA / reformulation ⌘R
        case text      // texte brut (retouche passée)
        case check     // terminé

        var symbol: String {
            switch self {
            case .wave:     return "waveform"
            case .dots:     return "ellipsis"
            case .sparkles: return "sparkles"
            case .text:     return "text.alignleft"
            case .check:    return "checkmark"
            }
        }
    }
    var glyph: Glyph = .wave { didSet { if glyph != oldValue { needsDisplay = true } } }

    override init(frame f: NSRect) { super.init(frame: f); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        let b = bounds
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: b).fill()
        guard let base = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: (b.height * 0.44).rounded(), weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let img = base.withSymbolConfiguration(cfg) ?? base
        let s = img.size
        img.draw(in: NSRect(x: b.midX - s.width / 2, y: b.midY - s.height / 2, width: s.width, height: s.height))
    }
}

/// Couleurs de la maquette (clair / sombre).
enum ToastPalette {
    static let text      = dynamic(0x5F5F66, 0xC2C2C8)
    static let dim       = dynamic(0x616168, 0xA6A6AD) // maquette : #6E6E76 en clair, 3,9:1 mesuré → foncé
    static let notice    = dynamic(0x1C1C1E, 0xECECED)
    static let keyBorder = dynamic(NSColor.black.withAlphaComponent(0.20), NSColor.white.withAlphaComponent(0.24))
    static let rim       = dynamic(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.13))
    /// Voile posé sur le verre : sans lui, le verre sombre devant une page blanche vire au gris moyen
    /// et le texte clair tombe à 2,6:1 (mesuré). Valeurs de la maquette.
    static let veil      = dynamic(NSColor(srgbRed: 252 / 255, green: 252 / 255, blue: 253 / 255, alpha: 0.74),
                                   NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 52 / 255, alpha: 0.68))

    static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    private static func dynamic(_ light: Int, _ dark: Int) -> NSColor { dynamic(rgb(light), rgb(dark)) }
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { isDark($0) ? dark : light }
    }
    private static func rgb(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

final class ToastCard: NSView {
    /// Rappel de raccourci affiché après le compteur (« · ⇧Échap brut »), grande carte seulement.
    struct KeyHint: Equatable { let key: String; let label: String }

    enum Mode: Equatable {
        case recording
        case processing(String, glyph: WaveBadge.Glyph, hint: KeyHint? = nil)
        case notice(String, check: Bool = false)
    }

    private(set) var mode: Mode = .processing("", glyph: .dots)
    var model: String? { didSet { line.model = model } }
    var compact = false { didSet { if compact != oldValue { applyStyle(); applyAppearance(); layoutNow() } } }

    private let effect = NSVisualEffectView()
    private let veil = RimView(fill: true)                 // voile de la maquette sur le verre
    private let rim = RimView()                            // liseré 0,5 pt
    private let pulse = NSView()                           // anneau qui pulse pendant l'enregistrement
    private let ring = CALayer()
    private let badge = WaveBadge()
    private let bars = BarsView()
    private let line = PhaseLine()                        // « retouche · 2,5 s · ⇧Échap brut », centrée
    private let notice = NSTextField(labelWithString: "")  // message (Collé, Annulé…)
    private var clockStart: Date?
    private var clock: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Ombre douce sous la carte (maquette : 0 6 20 noir 10 % en clair, 0 6 22 noir 34 % en sombre).
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOffset = CGSize(width: 0, height: -6)

        // Vrai matériau système (Liquid Glass), adaptatif clair/sombre.
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.maskImage = ToastCard.roundedMask(radius: 16)
        addSubview(effect)
        addSubview(veil)
        addSubview(rim)

        pulse.wantsLayer = true
        pulse.layer?.addSublayer(ring)
        addSubview(pulse)
        badge.wantsLayer = true
        addSubview(badge)
        addSubview(bars)
        addSubview(line)

        notice.font = .systemFont(ofSize: 13, weight: .medium)
        notice.textColor = ToastPalette.notice
        notice.alignment = .center
        notice.maximumNumberOfLines = 1
        notice.lineBreakMode = .byTruncatingTail
        notice.isBordered = false; notice.drawsBackground = false
        addSubview(notice)
        applyAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    /// Ombre : 0 6 20 / 10 % (clair), 0 6 22 / 34 % (sombre) ; plus légère sur les cartes réduites
    /// (0 4 12 / 6 %, 0 4 14 / 26 %).
    private func applyAppearance() {
        let dark = ToastPalette.isDark(effectiveAppearance)
        if compact {
            layer?.shadowOpacity = dark ? 0.26 : 0.06
            layer?.shadowRadius = dark ? 7 : 6
            layer?.shadowOffset = CGSize(width: 0, height: -4)
        } else {
            layer?.shadowOpacity = dark ? 0.34 : 0.10
            layer?.shadowRadius = dark ? 11 : 10
            layer?.shadowOffset = CGSize(width: 0, height: -6)
        }
    }

    func setMode(_ mode: Mode) {
        let previous = self.mode
        self.mode = mode
        switch mode {
        case .recording:
            badge.isHidden = false; badge.glyph = .wave
            bars.isHidden = false; line.isHidden = false
            notice.isHidden = true
            line.hint = nil
            startClock(every: 0.5)
        case .processing(_, let glyph, let hint):
            badge.isHidden = false; badge.glyph = glyph
            bars.isHidden = false; line.isHidden = false
            notice.isHidden = true
            line.hint = hint
            if previous != mode || clock == nil { startClock(every: 0.1) } // nouvelle phase → compteur à zéro
        case .notice(let t, let check):
            badge.isHidden = !check; badge.glyph = .check
            bars.isHidden = true; bars.stop()
            line.isHidden = true
            notice.isHidden = false; notice.stringValue = t
            if previous != mode {  // apparition douce (maquette : 240 ms)
                notice.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.24; notice.animator().alphaValue = 1 }
            }
            stopClock()
        }
        applyStyle()
        layoutNow()
    }

    /// Style du spectre et de la pastille selon la phase ET la taille. Les cartes réduites n'ont
    /// pas de spectre (maquette v3 : une seule ligne, pastille + texte).
    private func applyStyle() {
        line.compact = compact
        if compact { bars.isHidden = true; bars.stop() }
        switch mode {
        case .recording:
            if !compact { bars.isHidden = false; bars.start(.live) }
            compact ? stopPulse() : startPulse()
        case .processing(_, let glyph, _):
            if !compact { bars.isHidden = false; bars.start(glyph == .text ? .still : .calm) } // texte brut = au repos
            stopPulse()
        case .notice:
            stopPulse()
        }
    }

    func setLevels(_ levels: [Float]) { bars.setTargets(levels) }

    private func startClock(every interval: TimeInterval) {
        clockStart = Date(); updateClock()
        clock?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.updateClock() }
        RunLoop.main.add(t, forMode: .common); clock = t
    }
    private func stopClock() { clock?.invalidate(); clock = nil; clockStart = nil }
    private func updateClock() {
        guard let s = clockStart else { return }
        let e = Date().timeIntervalSince(s)
        switch mode {
        case .recording:
            line.phase = L.tr("recording", "enregistrement")
            line.time = "\(Int(e) / 60):" + String(format: "%02d", Int(e) % 60)
        case .processing(let phase, _, _):
            line.phase = phase
            line.time = ToastCard.seconds(e)
        case .notice:
            break
        }
    }

    /// Secondes au dixième, virgule décimale en français.
    static func seconds(_ e: TimeInterval) -> String {
        let s = String(format: "%.1f s", e)
        return L.tr(s, s.replacingOccurrences(of: ".", with: ","))
    }

    func layoutNow() {
        effect.frame = bounds
        veil.frame = bounds
        rim.frame = bounds
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        let h = bounds.height, w = bounds.width
        let pad: CGFloat = compact ? 12 : 14          // marges latérales
        let pill: CGFloat = compact ? 22 : 28
        let gap: CGFloat = compact ? 10 : 12          // pastille → contenu
        if case .notice(_, let check) = mode {
            if check { // pastille coche + texte centré dans la place restante
                badge.frame = NSRect(x: pad, y: ((h - pill) / 2).rounded(), width: pill, height: pill)
                let x = pad + pill + gap
                notice.frame = NSRect(x: x, y: ((h - 17) / 2).rounded(), width: max(0, w - pad - x), height: 17)
            } else {
                notice.frame = NSRect(x: pad, y: ((h - 17) / 2).rounded(), width: w - 2 * pad, height: 17)
            }
            return
        }
        if compact { // une seule ligne : pastille puis « phase · temps » aligné à gauche
            badge.frame = NSRect(x: pad, y: ((h - pill) / 2).rounded(), width: pill, height: pill)
            let x = pad + pill + gap
            line.frame = NSRect(x: x, y: ((h - 14) / 2).rounded(), width: max(0, w - pad - x), height: 14)
            return
        }
        // Deux lignes : 8 pt de marge, pastille 28, 6 pt d'écart, ligne 14, 8 pt de marge.
        let lineH: CGFloat = 14, specH: CGFloat = 20
        let bottom = ((h - (pill + 6 + lineH)) / 2).rounded()
        let rowY = bottom + lineH + 6
        badge.frame = NSRect(x: pad, y: rowY, width: pill, height: pill)
        pulse.frame = badge.frame.insetBy(dx: -10, dy: -10)
        ring.bounds = CGRect(x: 0, y: 0, width: pill, height: pill)
        ring.position = CGPoint(x: pulse.bounds.midX, y: pulse.bounds.midY)
        ring.cornerRadius = pill / 2
        let bx = pad + pill + gap
        // Le spectre s'arrête à 16 pt du bord droit (marge 14 + 2).
        bars.frame = NSRect(x: bx, y: rowY + (pill - specH) / 2, width: max(0, w - pad - 2 - bx), height: specH)
        line.frame = NSRect(x: pad, y: bottom, width: w - 2 * pad, height: lineH)
    }

    override func layout() { super.layout(); layoutNow() }

    /// Anneau d'accent qui s'élargit de 9 pt en s'effaçant (1,7 s), autour de la pastille.
    private func startPulse() {
        pulse.isHidden = false
        guard ring.animation(forKey: "pulse") == nil else { return }
        ring.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        let pill = ring.bounds.width > 0 ? ring.bounds.width : 28
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1; grow.toValue = (pill + 18) / pill
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 1.7
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        g.repeatCount = .infinity
        ring.add(g, forKey: "pulse")
    }
    private func stopPulse() { ring.removeAnimation(forKey: "pulse"); pulse.isHidden = true }

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

/// Liseré 0,5 pt autour de la carte (noir 8 % en clair, blanc 13 % en sombre), ou — `fill` — le
/// voile qui recouvre le verre.
final class RimView: NSView {
    private let fill: Bool
    init(fill: Bool = false) { self.fill = fill; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        if fill {
            ToastPalette.veil.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()
            return
        }
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 16, yRadius: 16)
        p.lineWidth = 0.5
        ToastPalette.rim.setStroke()
        p.stroke()
    }
}

/// Ligne « phase · temps ». Grande carte : CENTRÉE, suivie pendant la retouche du rappel
/// « [⇧ Maj] brut » ; carte réduite : alignée à gauche après la pastille. Le temps occupe une case
/// fixe de 34 pt (chiffres tabulaires) : le groupe ne bouge pas quand les chiffres défilent.
final class PhaseLine: NSView {
    var phase = "" { didSet { if phase != oldValue { needsDisplay = true } } }
    var model: String? { didSet { if model != oldValue { needsDisplay = true } } } // grande carte seulement
    var time = "" { didSet { if time != oldValue { needsDisplay = true } } }
    var hint: ToastCard.KeyHint? { didSet { if hint != oldValue { needsDisplay = true } } }
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }

    override func draw(_ r: NSRect) {
        let slot: CGFloat = 34
        let medium = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
        let small = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        func str(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: -0.05])
        }
        let label = str(phase, medium, ToastPalette.text)
        let dot = str("·", medium, ToastPalette.text.withAlphaComponent(0.5))
        let clock = str(time, digits, ToastPalette.text)

        // Rappel de raccourci (grande carte seulement) : 10 pt, [⇧ Maj], 6 pt, « brut ».
        let showHint = hint != nil && !compact
        let key = str(hint?.key ?? "", small, ToastPalette.dim)
        let suffix = str(hint?.label ?? "", small, ToastPalette.dim)
        let keyW = ceil(key.size().width) + 10, keyH = ceil(small.pointSize * 1.3) + 2

        var total = ceil(label.size().width) + 6 + ceil(dot.size().width) + 6 + slot
        if showHint { total += 10 + keyW + 6 + ceil(suffix.size().width) }
        // Modèle en gris entre la phase et le temps, raccourci (…) s'il déborde de la carte.
        var name: NSAttributedString?
        if let model, !model.isEmpty, !compact {
            let room = bounds.width - 16 - total - 6 - ceil(dot.size().width) - 6
            var m = model
            while m.count > 1, str(m, medium, ToastPalette.dim).size().width > room { m = String(m.dropLast(2)) + "…" }
            if m.count > 1 {
                name = str(m, medium, ToastPalette.dim)
                total += 6 + ceil(dot.size().width) + 6 + ceil(name!.size().width)
            }
        }
        var x = compact ? 0 : ((bounds.width - total) / 2).rounded()
        let h = bounds.height
        func put(_ s: NSAttributedString, width: CGFloat? = nil, center: Bool = false) {
            let sz = s.size()
            let w = width ?? ceil(sz.width)
            let dx = center ? ((w - sz.width) / 2).rounded() : 0
            s.draw(at: NSPoint(x: x + dx, y: ((h - sz.height) / 2).rounded()))
            x += w
        }
        put(label); x += 6
        if let name { put(dot); x += 6; put(name); x += 6 }
        put(dot); x += 6
        put(clock, width: slot, center: !compact) // centré dans sa case (à gauche en réduit)
        guard showHint else { return }
        x += 10
        let box = NSRect(x: x + 0.25, y: ((h - keyH) / 2).rounded() + 0.25, width: keyW - 0.5, height: keyH - 0.5)
        let rim = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        rim.lineWidth = 0.5
        ToastPalette.keyBorder.setStroke()
        rim.stroke()
        put(key, width: keyW, center: true); x += 6
        put(suffix)
    }
}

// MARK: - Spectre

/// Barres réparties sur toute la largeur (3 pt, arrondies, couleur d'accent). Trois régimes :
/// `live` = niveaux du micro, `calm` = vague lente qui « respire » (traitement, pas de spinner),
/// `still` = au repos, pâle (texte brut, cartes réduites de la pile).
final class BarsView: NSView {
    enum Style { case live, calm, still }
    var count = 28 { didSet { if count != oldValue { resetLevels(); needsDisplay = true } } }
    var scale: CGFloat = 1 { didSet { if scale != oldValue { needsDisplay = true } } }
    private var style: Style = .still
    private var targets: [Float] = []
    private var current: [Float] = []
    private var timer: Timer?
    private var origin = CACurrentMediaTime()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        resetLevels()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func resetLevels() {
        targets = [Float](repeating: 0, count: count)
        current = [Float](repeating: 0, count: count)
    }

    /// Niveaux du micro (28 bandes). Répartis sur `count` barres si elles sont moins nombreuses.
    func setTargets(_ levels: [Float]) {
        guard style == .live, !levels.isEmpty else { return }
        for i in 0..<count {
            let j = min(levels.count - 1, i * levels.count / max(count, 1))
            targets[i] = levels[j]
        }
    }

    func start(_ style: Style) {
        if style != self.style { origin = CACurrentMediaTime() }
        self.style = style
        needsDisplay = true
        guard style != .still else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        resetLevels()
        needsDisplay = true
    }

    private func tick() {
        if style == .live {
            for i in 0..<count { current[i] += (targets[i] - current[i]) * 0.35 }
        }
        needsDisplay = true
    }

    /// Hauteur (pt) et opacité de la barre `i` — formules de la maquette.
    private func bar(_ i: Int, now: CFTimeInterval) -> (CGFloat, CGFloat) {
        switch style {
        case .live:
            return (max(3, CGFloat(current[i]) * bounds.height), 0.95)
        case .calm:
            // Ondulation lente : chaque barre oscille entre 28 % et 100 % de sa hauteur de base,
            // période et déphasage propres (1,7 à 2,36 s, 65 ms de décalage entre voisines).
            let base = (4 + 7 * (0.5 + 0.5 * sin(Double(i) * 0.52))) * Double(scale)
            let dur = 1.7 + Double(i % 4) * 0.22
            let t = now - origin - Double(i) * 0.065
            let s = 0.5 - 0.5 * cos(Double.pi * t / dur)
            return (CGFloat(base * (0.28 + 0.72 * s)), 0.72)
        case .still:
            return ((3 + (i % 3 == 0 ? 1.6 : 0)) * scale, 0.38)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 3
        // Cadre trop étroit → moins de barres (jamais de chevauchement) ; sinon réparties.
        let n = min(count, Int((bounds.width + 1) / (barW + 1)))
        guard n > 1 else { return }
        let step = (bounds.width - barW) / CGFloat(n - 1)
        let first = (count - n) / 2
        let now = CACurrentMediaTime()
        let accent = NSColor.controlAccentColor
        for j in 0..<n {
            let (hgt, op) = bar(first + j, now: now)
            let rect = NSRect(x: (CGFloat(j) * step).rounded(), y: bounds.midY - hgt / 2, width: barW, height: hgt)
            accent.withAlphaComponent(op).setFill()
            NSBezierPath(roundedRect: rect, xRadius: barW / 2, yRadius: barW / 2).fill()
        }
    }
}
