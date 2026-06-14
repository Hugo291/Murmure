import AppKit
import ApplicationServices

/// Détecte « auto in-place » la correction que l'utilisateur fait sur un texte inséré,
/// en relisant le champ focalisé via l'API d'accessibilité.
///
/// Principe : on mémorise le texte du champ avant et après le collage. La différence
/// donne deux ancres (texte avant / après la zone insérée). Plus tard, on relit le champ
/// et on extrait ce qui se trouve entre les ancres = la version corrigée par l'utilisateur.
final class EditWatcher {
    private var element: AXUIElement?
    private var anchorBefore = ""
    private var anchorAfter = ""
    private var fieldWasEmpty = false
    private var insertedText = ""
    private var transcriptID: UUID?
    private var timer: Timer?
    private var pollTimer: Timer?
    private var lastPlausible: String?   // dernière version éditée plausible vue pendant l'édition

    /// (textInséré, texteCorrigé, idTranscript)
    var onCorrection: ((String, String, UUID?) -> Void)?

    /// Valeur du champ actuellement focalisé (à appeler AVANT le collage).
    func focusedValue() -> String? {
        guard let el = focusedElement() else { return nil }
        return value(of: el)
    }

    /// `true` si l'élément focalisé accepte du texte (champ éditable) → on peut coller dedans.
    func isFocusedElementEditable() -> Bool {
        InsertionTarget.enableWebAX() // réveille l'accessibilité de Chrome avant de tester
        guard AXIsProcessTrusted(), let el = focusedElement() else { return false }
        // Champ dont la valeur est modifiable.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        // Présence d'un caret/sélection texte → champ de saisie (couvre les inputs web/Electron).
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &sel) == .success {
            return true
        }
        // Sinon, rôle de saisie texte connu.
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String {
            return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        }
        return false
    }

    /// Démarre la surveillance après un collage. `valueBefore` = valeur capturée avant collage.
    func startWatching(inserted: String, valueBefore: String?, transcriptID: UUID?) {
        finalize() // clôt une surveillance précédente

        guard AXIsProcessTrusted(), let el = focusedElement(), let v0 = value(of: el) else { return }
        let vPre = valueBefore ?? ""

        let before = commonPrefix(vPre, v0)
        let after = commonSuffix(vPre, v0, excludingPrefixLen: before.count)
        anchorBefore = String(before.suffix(24))
        anchorAfter = String(after.prefix(24))
        fieldWasEmpty = vPre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        element = el
        insertedText = inserted
        self.transcriptID = transcriptID
        lastPlausible = nil

        // Observation en direct : on scrute le champ pendant l'édition pour capter ta
        // correction AVANT que tu n'envoies (et donc que le champ se vide).
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // Filet de sécurité : si rien ne se passe, on clôt au bout de 2 min.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            self?.finalize()
        }
    }

    /// Scrute le champ : mémorise la dernière édition plausible ; si le champ se vide
    /// (tu as envoyé / effacé), on valide cette dernière version.
    private func poll() {
        guard let el = element else { pollTimer?.invalidate(); return }
        guard let v1 = value(of: el) else { finalize(); return }
        let cleared = v1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || v1.count < max(3, insertedText.count / 3)
        if cleared { finalize(); return }
        if let cand = extractRegion(from: v1)?.trimmingCharacters(in: .whitespacesAndNewlines),
           cand != insertedText, isPlausibleCorrection(of: insertedText, to: cand) {
            lastPlausible = cand
        }
    }

    /// Valide la correction (la dernière version éditée plausible), déclenche le callback, puis arrête.
    func finalize() {
        timer?.invalidate(); timer = nil
        pollTimer?.invalidate(); pollTimer = nil
        defer { teardown() }

        // Priorité : la dernière version éditée captée pendant l'édition (avant l'envoi).
        if let best = lastPlausible {
            onCorrection?(insertedText, best, transcriptID)
            return
        }
        // Sinon, dernière tentative sur la valeur actuelle (édité juste avant la clôture).
        guard let el = element, let v1 = value(of: el),
              let corrected = extractRegion(from: v1)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !corrected.isEmpty, corrected != insertedText,
              isPlausibleCorrection(of: insertedText, to: corrected) else { return }
        onCorrection?(insertedText, corrected, transcriptID)
    }

    /// Vrai si `corrected` partage assez de mots avec `inserted` pour être une correction
    /// (et pas un contenu sans rapport comme un placeholder ou un champ vidé).
    private func isPlausibleCorrection(of inserted: String, to corrected: String) -> Bool {
        let oldW = words(inserted), newW = words(corrected)
        guard oldW.count >= 2 else { return false }
        // 1) partage assez de mots (sinon : placeholder / contenu sans rapport).
        let overlap = Double(Set(oldW).intersection(Set(newW)).count) / Double(Set(oldW).count)
        guard overlap >= 0.4 else { return false }
        // 2) pas beaucoup plus long (sinon c'est un AJOUT : d'autres dictées dans le même champ).
        guard newW.count <= oldW.count + max(2, oldW.count / 2) else { return false }
        // 3) une vraie correction est une SUBSTITUTION : au moins un mot retiré ET un mot ajouté.
        //    (Supprimer une phrase qu'on a mal dite, ou ajouter du texte, n'est PAS une correction.)
        let dc = diffCounts(oldW, newW)
        guard dc.removed >= 1, dc.added >= 1 else { return false }
        return true
    }

    /// Nombre de mots retirés / ajoutés entre deux textes (via plus longue sous-séquence commune).
    private func diffCounts(_ old: [String], _ new: [String]) -> (removed: Int, added: Int) {
        let n = old.count, m = new.count
        if n == 0 { return (0, m) }
        if m == 0 { return (n, 0) }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        let lcs = dp[0][0]
        return (n - lcs, m - lcs)
    }

    private func words(_ s: String) -> [String] {
        // Slash-aware : « /use-chatgpt » reste un seul mot (pas découpé sur / ni -).
        s.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" || $0 == "/") }
            .map(String.init).filter { $0.count > 1 }
    }

    private func teardown() {
        element = nil; anchorBefore = ""; anchorAfter = ""; insertedText = ""; transcriptID = nil
        lastPlausible = nil
    }

    // MARK: - Extraction

    private func extractRegion(from v1: String) -> String? {
        // Cas champ initialement vide : tout le contenu est notre texte (édité).
        if fieldWasEmpty && anchorBefore.isEmpty && anchorAfter.isEmpty {
            return v1
        }
        var start = v1.startIndex
        if !anchorBefore.isEmpty {
            guard let r = v1.range(of: anchorBefore) else { return nil }
            start = r.upperBound
        }
        var end = v1.endIndex
        if !anchorAfter.isEmpty {
            guard let r = v1.range(of: anchorAfter, range: start..<v1.endIndex) else { return nil }
            end = r.lowerBound
        }
        guard start <= end else { return nil }
        return String(v1[start..<end])
    }

    private func commonPrefix(_ a: String, _ b: String) -> String {
        let ac = Array(a), bc = Array(b)
        var i = 0
        while i < ac.count && i < bc.count && ac[i] == bc[i] { i += 1 }
        return String(ac[0..<i])
    }

    private func commonSuffix(_ a: String, _ b: String, excludingPrefixLen: Int) -> String {
        let ac = Array(a), bc = Array(b)
        var i = 0
        while i < ac.count - excludingPrefixLen && i < bc.count - excludingPrefixLen
            && ac[ac.count - 1 - i] == bc[bc.count - 1 - i] { i += 1 }
        return String(bc.suffix(i))
    }

    // MARK: - Accessibilité

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        return (el as! AXUIElement)
    }

    private func value(of el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
