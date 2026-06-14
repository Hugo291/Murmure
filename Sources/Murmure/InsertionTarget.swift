import AppKit
import ApplicationServices

/// Mémorise OÙ coller la transcription : l'élément texte focalisé + la position du caret
/// au moment où l'on démarre la dictée. Permet de re-cibler cet endroit à la livraison,
/// même si l'utilisateur a changé d'app ou cliqué ailleurs entre-temps.
final class InsertionTarget {
    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var range: AXValue? // kAXSelectedTextRange capturé au démarrage (caret)

    var hasTarget: Bool { element != nil }

    /// À appeler au démarrage de l'enregistrement.
    func capture() {
        element = nil; range = nil; pid = 0
        Self.enableWebAX() // réveille l'accessibilité de Chrome/Chromium (désactivée par défaut)
        guard AXIsProcessTrusted(), let el = focusedElement(), isTextElement(el) else { return }
        element = el
        AXUIElementGetPid(el, &pid)
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
           let rv = r, CFGetTypeID(rv) == AXValueGetTypeID() {
            range = (rv as! AXValue)
        }
    }

    /// Rectangle écran du caret mémorisé (coordonnées AX : origine en haut à gauche).
    func caretScreenRect() -> CGRect? {
        guard let element, let range else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsRef) == .success,
              let b = boundsRef, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        AXValueGetValue((b as! AXValue), .cgRect, &rect)
        // Rejette un rectangle aberrant (hauteur nulle/énorme).
        guard rect.height > 2, rect.height < 400 else { return nil }
        // Le caret DOIT tomber dans le cadre du champ. Sinon les coordonnées renvoyées
        // sont peu fiables (cas fréquent des apps Electron/web) → on retombera sur le cadre du champ.
        if let frame = elementFrame(element) {
            let caretCenter = CGPoint(x: rect.midX, y: rect.midY)
            guard frame.insetBy(dx: -8, dy: -8).contains(caretCenter) else { return nil }
        }
        return rect
    }

    private func elementFrame(_ el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, CFGetTypeID(p) == AXValueGetTypeID(),
              let s = sizeRef, CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue((p as! AXValue), .cgPoint, &pt)
        AXValueGetValue((s as! AXValue), .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Point Cocoa où ancrer la pastille : caret précis si fiable, sinon début du champ.
    /// (nil si aucune cible texte → l'appelant retombera sur la position de la souris.)
    func anchorPointCocoa() -> CGPoint? {
        guard let element else { return nil }
        if let axRect = caretScreenRect() { return MicMarker.cocoaPoint(fromAXCaret: axRect) }
        if let f = elementFrame(element) {
            let start = CGRect(x: f.minX + 6, y: f.minY, width: 1, height: max(14, min(f.height, 26)))
            return MicMarker.cocoaPoint(fromAXCaret: start)
        }
        return nil
    }

    /// Ramène l'app cible au premier plan, refocalise l'élément et restaure le caret.
    /// Renvoie `true` si une cible existait et a été refocalisée.
    @discardableResult
    func refocus() -> Bool {
        guard let element else { return false }
        if pid != 0 { NSRunningApplication(processIdentifier: pid)?.activate() }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // NB : on ne restaure PAS le caret mémorisé — il devient périmé dès qu'un autre
        // transcript a écrit dans le même champ. On colle au curseur actuel (donc à la suite).
        return true
    }

    func clear() { element = nil; range = nil; pid = 0 }

    // MARK: - Helpers AX

    /// Active l'accessibilité de l'app au premier plan (Chrome/Chromium l'a désactivée par défaut ;
    /// il faut poser AXManualAccessibility=true pour qu'elle expose ses inputs web à l'AX).
    static func enableWebAX() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(app.processIdentifier),
            "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    private func isTextElement(_ el: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        // Présence d'un caret/sélection texte → champ de saisie (couvre les inputs web/Electron).
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sel) == .success {
            return true
        }
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        }
        return false
    }
}
