import CoreGraphics

/// Un raccourci clavier configurable.
/// `keyCode == -1` ⇒ modificateur seul (ex. Fn) ; sinon `keyCode` est le code virtuel de la touche.
struct Shortcut: Codable, Equatable {
    var keyCode: Int        // code de touche virtuel ; -1 = pas de touche « normale »
    var modifiers: UInt64   // bits CGEventFlags surveillés (cmd / opt / ctrl / shift / fn)

    static let cmd      = CGEventFlags.maskCommand.rawValue
    static let opt      = CGEventFlags.maskAlternate.rawValue
    static let ctrl     = CGEventFlags.maskControl.rawValue
    static let shift    = CGEventFlags.maskShift.rawValue
    static let fn       = CGEventFlags.maskSecondaryFn.rawValue
    static let comboMask = cmd | opt | ctrl | shift

    /// Vrai si c'est un modificateur seul (pas de touche « normale »), ex. Fn.
    var isModifierOnly: Bool { keyCode < 0 }

    /// Représentation lisible : « ⌘L », « Fn », « Échap », « ⌃⌥A »…
    var display: String {
        var s = ""
        if modifiers & Shortcut.ctrl  != 0 { s += "⌃" }
        if modifiers & Shortcut.opt   != 0 { s += "⌥" }
        if modifiers & Shortcut.shift != 0 { s += "⇧" }
        if modifiers & Shortcut.cmd   != 0 { s += "⌘" }
        if keyCode < 0 {
            if modifiers & Shortcut.fn != 0 { s += "Fn" }
        } else {
            s += Shortcut.keyName(keyCode)
        }
        return s.isEmpty ? "—" : s
    }

    static func keyName(_ code: Int) -> String {
        if let s = specials[code] { return s }
        if let l = letters[code] { return l }
        return "Touche \(code)"
    }

    private static let specials: [Int: String] = [
        53: "Échap", 49: "Espace", 36: "Entrée", 76: "⌤", 48: "Tab",
        51: "⌫", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let letters: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
    ]
}
