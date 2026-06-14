import AppKit
import CoreGraphics

/// Détecte les raccourcis configurables de Murmure (lus dans `Config` à la volée).
/// - Dictée : si le raccourci est un modificateur seul (Fn par défaut), il est suivi via
///   `flagsChanged` ; s'il a été reconfiguré en combinaison, il est détecté dans le tap.
/// - Annuler / coller / reformuler : captés par un CGEventTap ACTIF, donc CONSOMMÉS
///   (l'app au premier plan ne les reçoit pas). « Annuler » n'est consommé que si
///   `isActive()` (enregistrement ou traitement en cours).
final class FnHotkey {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var modifierDown = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var swallowUpKey: Int? // keyCode dont on doit aussi avaler le keyUp

    /// Quand vrai, on laisse TOUT passer : un enregistreur de raccourci capture les touches.
    var recording = false

    var onToggle: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPasteLast: (() -> Void)?  // raccourci « coller la dernière dictée »
    var onSummarize: (() -> Void)?  // raccourci « reformuler la sélection »
    /// Renvoie `true` si « Annuler » doit être consommé (enregistrement/traitement en cours).
    var isActive: (() -> Bool)?

    func start() {
        let handle: (NSEvent) -> Void = { [weak self] event in self?.handleFlags(event) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { handle($0) }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event); return event
        }
        startTap()
    }

    /// À appeler après modification d'un raccourci : on réinitialise l'état de bascule
    /// pour éviter un faux déclenchement (les valeurs sont relues dans `Config`).
    func refresh() { modifierDown = false; swallowUpKey = nil }

    // MARK: - Modificateur seul (Fn) pour la dictée

    private func handleFlags(_ event: NSEvent) {
        guard !recording else { return }
        let sc = Config.scDictation
        guard sc.isModifierOnly else { modifierDown = false; return }
        let down = modifierPresent(sc, event.modifierFlags)
        if down && !modifierDown {
            modifierDown = true
            DispatchQueue.main.async { self.onToggle?() }
        } else if !down && modifierDown {
            modifierDown = false
        }
    }

    private func modifierPresent(_ sc: Shortcut, _ flags: NSEvent.ModifierFlags) -> Bool {
        if sc.modifiers & Shortcut.fn    != 0 { return flags.contains(.function) }
        if sc.modifiers & Shortcut.cmd   != 0 { return flags.contains(.command) }
        if sc.modifiers & Shortcut.opt   != 0 { return flags.contains(.option) }
        if sc.modifiers & Shortcut.ctrl  != 0 { return flags.contains(.control) }
        if sc.modifiers & Shortcut.shift != 0 { return flags.contains(.shift) }
        return false
    }

    // MARK: - Combinaisons de touches (tap actif)

    private func startTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<FnHotkey>.fromOpaque(refcon).takeUnretainedValue()
            return me.handleTap(type: type, event: event)
        }
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // tap actif → peut consommer l'événement
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("Murmure: CGEventTap non créé (Accessibilité requise)")
            return
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        source = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Le système peut désactiver le tap (timeout) → on le réactive.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard !recording else { return Unmanaged.passUnretained(event) }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp {
            if let k = swallowUpKey, k == code { swallowUpKey = nil; return nil }
            return Unmanaged.passUnretained(event)
        }

        // keyDown : on teste les raccourcis-combinaisons. Les RÉPÉTITIONS clavier (touche maintenue)
        // sont consommées mais NE redéclenchent PAS l'action — sinon Échap maintenu annulerait
        // plusieurs dictées d'affilée au lieu de la plus récente seulement.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if let action = matchedAction(code: code, flags: event.flags) {
            swallowUpKey = code
            if !isRepeat { DispatchQueue.main.async(execute: action) }
            return nil // consomme → l'app au premier plan ne reçoit pas la touche
        }
        return Unmanaged.passUnretained(event)
    }

    /// Action associée à la combinaison, ou nil. « Annuler » n'agit que si `isActive()`.
    /// Ordre = priorité : dictée → coller → reformuler → annuler.
    private func matchedAction(code: Int, flags: CGEventFlags) -> (() -> Void)? {
        let dictation = Config.scDictation
        if !dictation.isModifierOnly, matches(dictation, code, flags) { return { [weak self] in self?.onToggle?() } }
        if matches(Config.scPasteLast, code, flags) { return { [weak self] in self?.onPasteLast?() } }
        if matches(Config.scSummarize, code, flags) { return { [weak self] in self?.onSummarize?() } }
        if matches(Config.scCancel, code, flags), isActive?() == true { return { [weak self] in self?.onCancel?() } }
        return nil
    }

    /// Vrai si l'événement correspond exactement au raccourci (touche + combinaison de modificateurs).
    private func matches(_ sc: Shortcut, _ code: Int, _ flags: CGEventFlags) -> Bool {
        guard !sc.isModifierOnly, sc.keyCode == code else { return false }
        let want = sc.modifiers & Shortcut.comboMask
        let have = flags.rawValue & Shortcut.comboMask
        return want == have
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach { NSEvent.removeMonitor($0) }
        globalMonitor = nil
        localMonitor = nil
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .commonModes) }
        tap = nil
        source = nil
    }
}
