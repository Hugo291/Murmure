import AppKit

/// Insère le texte là où se trouve le curseur, via presse-papiers + ⌘V,
/// puis restaure l'ancien contenu du presse-papiers.
enum TextInserter {
    /// `keepOnClipboard` : si vrai, on NE restaure PAS l'ancien presse-papiers — le texte y reste
    /// (filet de sécurité quand on n'est pas sûr que le ⌘V ait atterri, ex. champ web non vu par l'AX).
    static func insert(_ text: String, keepOnClipboard: Bool = false) {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        // Laisse le temps au presse-papiers de se mettre à jour avant ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendPaste()
            guard !keepOnClipboard else { return }
            // Restaure l'ancien presse-papiers après le collage.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                pb.clearContents()
                if let saved { pb.setString(saved, forType: .string) }
            }
        }
    }

    static func sendCopy() { pressCmd(0x08) }  // ⌘C (touche C)
    static func sendPaste() { pressCmd(0x09) } // ⌘V (touche V)

    private static func pressCmd(_ key: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
