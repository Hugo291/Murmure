import Foundation

/// Nettoie le texte lu à l'écran (surtout une conversation Claude) : ne garde que les échanges.
/// Retire l'interface (modèle, jetons, coût, contexte, mode), les heures et durées, les résumés
/// d'outils (« Ran 2 commands », « Edited a file », « 12 added, 3 removed »), les doublons ; recolle
/// les morceaux de phrase coupés par les mots en `code`. Idempotent : sert aussi à l'affichage.
enum ScreenText {
    static func clean(_ text: String) -> String {
        var out: [String] = []
        var seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isNoise(line), seen.insert(norm(line)).inserted else { continue }
            // Le message d'un « Claude responded: X » revient seul plus bas : X compte comme vu.
            if let label = speakers.first(where: line.hasPrefix) { seen.insert(norm(String(line.dropFirst(label.count)))) }
            // Doublon de la ligne précédente : « You said: X » puis « X » (ou X en entier), titre répété.
            if let prev = out.last {
                let p = norm(prev), l = norm(line)
                if p.hasSuffix(": " + l) || (l.count >= 12 && p.contains(l)) { continue }
                if let label = speakers.first(where: prev.hasPrefix),
                   l.hasPrefix(norm(String(prev.dropFirst(label.count)))) {
                    out[out.count - 1] = label + line
                    continue
                }
            }
            if let prev = out.last, isFragment(line, after: prev) {
                out[out.count - 1] = join(prev, line)
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    private static let speakers = ["You said: ", "Claude responded: "]

    /// Apostrophes et guillemets typographiques ramenés aux droits, pour comparer deux lignes.
    private static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// Morceau d'une phrase coupée par un mot en `code` : commence par une ponctuation ou une
    /// minuscule, ou suit une ligne qui ne finit pas une phrase et reste court.
    private static func isFragment(_ line: String, after prev: String) -> Bool {
        guard let first = line.first, let last = prev.last else { return false }
        if ",.;:)»«(".contains(first) || first.isLowercase { return !".!?".contains(last) || first == "," }
        return line.count <= 60 && !line.contains(" ") && !".!?:»".contains(last)
    }

    private static func join(_ a: String, _ b: String) -> String {
        guard let f = b.first else { return a }
        return ",.;:)".contains(f) ? a + b : a + " " + b
    }

    private static func isNoise(_ line: String) -> Bool {
        if exact.contains(line) || noisePrefixes.contains(where: line.hasPrefix) { return true }
        let range = NSRange(line.startIndex..., in: line)
        return noisePatterns.contains { $0.firstMatch(in: line, range: range) != nil }
    }

    private static let exact: Set<String> = [
        "Context", "Chat mode", "token-live", "Extra", "Fast mode off", "Fast mode on", "High", "Medium",
        "Low", "Max", "This computer", "running", "Blocked", "Clicked", "Typed", "Created", "Updated",
        "Published", "Read", "Captured page", "Opened a page", "Claude finished the response",
        "Claude Design", "Just now", "Stop", "Copy", "Retry", "Edit", "in progress", "not done", "done",
    ]

    private static let noisePrefixes = [
        "Arrow keys move the tile", "Use the up and down arrow keys", "Shell cwd was reset",
        "Started by Claude from", "Updated ", "Created ", "Ran ", "Read ", "Edited ", "Opened a page",
        "Waited", "Clicking", "Clicked", "Typed", "Captured page", "Messaged another session",
        "Received a message", "Searched", "Started watching", ", started watching", ", clicking",
        ", waited", ", and ", "and ", "Creating ", "Editing ", "Reading ", "Running ",
    ]

    private static let noisePatterns: [NSRegularExpression] = [
        #"^\d+ added, \d+ removed$"#,                     // bilan d'un diff
        #"^\d+ (seconds?|minutes?|hours?|days?) ago$"#,  // « 21 minutes ago »
        #"^\d+\s?(s|m|h|min)$"#,                          // durées « 15m »
        #"^\d+ ?%$"#,                                     // jauge de contexte
        #"^\d+ artboards?$"#,
        #"·\s*↑.*(in|out)"#,                              // « sonnet-5-5 · ↑ 1.56M in … $23.46 »
        #"^(Opus|Sonnet|Haiku|Fable) \d+(\.\d+)?$"#,      // nom du modèle
        #"\$\d+(\.\d+)?$"#,                               // coût seul
        #"\(\d+ (failed|blocked)\)$"#,                    // « … and 2 more actions (1 blocked) »
        #"in \d+ steps?$"#,                               // « Waited, read page… in 3 steps »
        #" (not done|in progress)$"#,                     // case de la liste de tâches
    ].map { try! NSRegularExpression(pattern: $0) }
}
