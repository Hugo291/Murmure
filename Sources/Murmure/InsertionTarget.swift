import AppKit
import ApplicationServices

/// Mémorise OÙ coller la transcription : l'élément texte focalisé + la position du caret
/// au moment où l'on démarre la dictée. Permet de re-cibler cet endroit à la livraison,
/// même si l'utilisateur a changé d'app ou cliqué ailleurs entre-temps.
final class InsertionTarget {
    private var element: AXUIElement?
    private var pid: pid_t = 0
    private var range: AXValue? // kAXSelectedTextRange capturé au démarrage (caret)

    /// Identité du champ visé, STABLE d'une dictée à l'autre : deux dictées qui atterrissent dans
    /// le MÊME input physique partagent le même `fieldID`. Sert à regrouper l'historique.
    /// nil quand aucune cible n'a pu être capturée (on ne peut alors rien affirmer).
    private(set) var fieldID: UUID?
    /// App qui possède le champ, pour l'entête du groupe dans l'historique.
    private(set) var appName: String?
    /// Bundle id de l'app propriétaire (ex. `com.anthropic.claudefordesktop`), pour son icône.
    private(set) var bundleID: String?

    /// Cible = Claude (desktop) : on garde alors la conversation affichée dans l'historique.
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    var isClaude: Bool { bundleID == Self.claudeBundleID }

    /// Dernier champ capturé, TOUS jobs confondus : chaque dictée a son propre InsertionTarget,
    /// la mémoire du « champ précédent » doit donc être partagée.
    private static var lastElement: AXUIElement?
    private static var lastFieldID: UUID?

    var hasTarget: Bool { element != nil }

    /// À appeler au démarrage de l'enregistrement.
    func capture() {
        element = nil; range = nil; pid = 0; fieldID = nil; appName = nil; bundleID = nil
        Self.enableWebAX() // réveille l'accessibilité de Chrome/Chromium (désactivée par défaut)
        guard AXIsProcessTrusted(), let el = focusedElement(), isTextElement(el) else {
            // Aucune cible lisible : on OUBLIE le champ précédent. Sinon une dictée ultérieure
            // dans ce même champ ressusciterait son fieldID, et l'historique se retrouverait avec
            // deux suites séparées portant la même identité.
            Self.lastElement = nil; Self.lastFieldID = nil
            return
        }
        element = el
        AXUIElementGetPid(el, &pid)
        appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        // Même élément AX que la dictée précédente → même input physique → même groupe.
        // (AXUIElement se compare avec CFEqual ; si l'app recrée son champ entre deux dictées,
        // on retombe simplement sur un nouveau groupe — dégradation sans casse.)
        if let last = Self.lastElement, let lastID = Self.lastFieldID, CFEqual(last, el) {
            fieldID = lastID
        } else {
            fieldID = UUID()
        }
        Self.lastElement = el
        Self.lastFieldID = fieldID
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
           let rv = r, CFGetTypeID(rv) == AXValueGetTypeID() {
            range = (rv as! AXValue)
        }
    }

    /// Ce qui est DÉJÀ écrit dans le champ, juste avant le point d'insertion — le contexte de la
    /// dictée en cours (typiquement la dictée précédente). Sert à la retouche IA, pour qu'elle
    /// enchaîne dans le même sujet, le même style et la même phrase. nil si le champ est illisible
    /// ou vide : le contexte reste facultatif, la retouche se fait alors comme avant.
    ///
    /// À appeler sur le main (API d'accessibilité), au plus tard possible : le champ contient
    /// alors la dictée précédente, qui a eu le temps d'être collée.
    func textBeforeCaret(limit: Int = 800) -> String? {
        guard let element else { return nil }
        // Une app qui rame ne doit pas figer la dictée : on plafonne l'attente AX.
        AXUIElementSetMessagingTimeout(element, 1.0)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &v) == .success,
              let full = v as? String, !full.isEmpty else { return nil }

        // On ne garde que ce qui PRÉCÈDE le caret actuel : le reste viendra après notre texte.
        var head = full
        var r: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &r) == .success,
           let rv = r, CFGetTypeID(rv) == AXValueGetTypeID() {
            var caret = CFRange(location: 0, length: 0)
            let utf16 = Array(full.utf16)   // l'accessibilité indexe en UTF-16
            if AXValueGetValue((rv as! AXValue), .cfRange, &caret),
               caret.location >= 0, caret.location <= utf16.count {
                head = String(decoding: utf16[0..<caret.location], as: UTF16.self)
            }
        }

        let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Un long document ne sert à rien au LLM (et le ralentit) : on garde la fin, la plus proche.
        return t.count <= limit ? t : "…" + String(t.suffix(limit))
    }

    /// Ce qui est AFFICHÉ dans la fenêtre du champ (la conversation, le document…), hors le champ
    /// lui-même : sa fin sert à la retouche IA pour rétablir les mots mal entendus (noms de fichiers,
    /// d'apps, de fonctions) et pour répondre au bon sujet. Parcours AX borné (nombre de nœuds, profondeur,
    /// délai par appel) : c'est le main qui le fait, comme `textBeforeCaret`. nil si rien de lisible.
    func screenText(limit: Int = 1500) -> String? {
        guard let element else { return nil }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &winRef) == .success,
              let rw = winRef, CFGetTypeID(rw) == AXUIElementGetTypeID() else { return nil }
        let window = rw as! AXUIElement
        AXUIElementSetMessagingTimeout(window, 0.5)
        var pieces: [String] = []
        var budget = 1200 // nombre maximal de nœuds visités
        func walk(_ el: AXUIElement, depth: Int) {
            guard budget > 0, depth < 40 else { return }
            budget -= 1
            if CFEqual(el, element) { return } // le champ : déjà couvert par `textBeforeCaret`
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            if (roleRef as? String) == "AXStaticText" {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success,
                   let s = v as? String, !s.isEmpty { pieces.append(s) }
                return
            }
            var kids: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
                  let list = kids as? [AXUIElement] else { return }
            for k in list { walk(k, depth: depth + 1) }
        }
        walk(window, depth: 0)
        let t = ScreenText.clean(pieces.joined(separator: "\n"))
        guard !t.isEmpty else { return nil }
        // Seule la fin compte : c'est là que se trouve le dernier message auquel on répond.
        return t.count <= limit ? t : "…" + String(t.suffix(limit))
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
