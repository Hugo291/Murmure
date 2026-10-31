import Foundation

/// Convertit les nombres français écrits en lettres en chiffres (« vingt-trois » → 23).
/// Déterministe : ne dépend pas du LLM (les petits modèles ne suivent pas la consigne).
enum NumberWords {
    private enum Kind { case zero, unit, teen, ten, hundred, thousand, million }
    private static let words: [String: (Int, Kind)] = {
        var w: [String: (Int, Kind)] = ["zéro": (0, .zero), "zero": (0, .zero)]
        let units = ["un", "deux", "trois", "quatre", "cinq", "six", "sept", "huit", "neuf"]
        for (i, u) in units.enumerated() { w[u] = (i + 1, .unit) }
        w["une"] = (1, .unit)
        let teens = ["dix", "onze", "douze", "treize", "quatorze", "quinze", "seize"]
        for (i, t) in teens.enumerated() { w[t] = (10 + i, .teen) }
        for (n, k) in [("vingt", 20), ("vingts", 20), ("trente", 30), ("quarante", 40),
                       ("cinquante", 50), ("soixante", 60)] { w[n] = (k, .ten) }
        w["cent"] = (100, .hundred); w["cents"] = (100, .hundred)
        w["mille"] = (1000, .thousand)
        w["million"] = (1_000_000, .million); w["millions"] = (1_000_000, .million)
        return w
    }()

    private struct Tok { let text: String; let range: Range<String.Index>; let isWord: Bool }

    private static func tokenize(_ s: String) -> [Tok] {
        var out: [Tok] = []
        var i = s.startIndex
        while i < s.endIndex {
            let isL = s[i].isLetter
            var j = i
            while j < s.endIndex, s[j].isLetter == isL { j = s.index(after: j) }
            out.append(Tok(text: String(s[i..<j]), range: i..<j, isWord: isL))
            i = j
        }
        return out
    }

    /// Un mot-nombre peut-il suivre le précédent dans le MÊME nombre ?
    private static func canFollow(_ prev: (Int, Kind), _ cur: (Int, Kind), prevWord: String, curWord: String) -> Bool {
        switch (prev.1, cur.1) {
        case (.zero, _): return false
        case (.ten, .unit): return cur.0 != 0
        case (.ten, .teen): return prev.0 == 60 || prev.0 == 80 // soixante-dix, quatre-vingt-dix
        case (.unit, .ten): return false
        case (.unit, .hundred), (.unit, .thousand), (.unit, .million): return true
        case (.teen, .thousand), (.teen, .million), (.ten, .thousand), (.ten, .million): return true
        case (.hundred, .ten), (.hundred, .unit), (.hundred, .teen), (.hundred, .thousand), (.hundred, .million): return true
        case (.thousand, .hundred), (.thousand, .ten), (.thousand, .unit), (.thousand, .teen): return true
        case (.million, _): return cur.1 != .zero
        default: return false
        }
    }

    static func convert(_ text: String) -> String {
        let toks = tokenize(text)
        var result = ""
        var i = 0
        func isSep(_ t: Tok) -> Bool { !t.isWord && t.text.allSatisfy { $0 == " " || $0 == "-" || $0 == "\u{00A0}" } }

        while i < toks.count {
            let t = toks[i]
            let low = t.text.lowercased()
            guard t.isWord, let first = words[low] else { result += t.text; i += 1; continue }

            // Étend la suite de mots-nombres liés par des espaces / traits d'union.
            var seq: [(String, (Int, Kind))] = [(low, first)]
            var end = i
            var k = i + 1
            while k + 1 < toks.count, isSep(toks[k]), toks[k + 1].isWord {
                var nextLow = toks[k + 1].text.lowercased()
                var step = 2
                // « vingt et un », « vingt-et-un »
                if nextLow == "et", k + 3 < toks.count, isSep(toks[k + 2]),
                   let after = words[toks[k + 3].text.lowercased()], seq.last!.1.1 == .ten,
                   after.0 == 1 || after.0 == 11 {
                    nextLow = toks[k + 3].text.lowercased(); step = 4
                }
                if seq.count == 1 || true, seq.last!.1.0 == 4, seq.last!.1.1 == .unit, nextLow.hasPrefix("vingt"), seq.count == 1 || seq.last!.1.1 == .unit {
                    seq[seq.count - 1] = ("quatre-vingt", (80, .ten)); end = k + 1; k += 2; continue
                }
                guard let nw = words[nextLow],
                      canFollow(seq.last!.1, nw, prevWord: seq.last!.0, curWord: nextLow) else { break }
                if seq.last!.1.1 == .ten, nw.1 == .teen { // soixante/quatre-vingt + dix…seize : un seul jeton
                    let v = seq.last!.1.0 + nw.0 // 60 ou 80 + 10…16
                    seq[seq.count - 1] = (seq.last!.0 + "-" + nextLow, (v, nw.0 == 10 ? .ten : .teen))
                } else {
                    seq.append((nextLow, nw))
                }
                end = k + step - 1; k += step
            }

            // Valeur.
            var total = 0, cur = 0
            for (w, (v, kind)) in seq {
                switch kind {
                case .hundred: cur = (cur == 0 ? 1 : cur) * 100
                case .thousand: total += (cur == 0 ? 1 : cur) * 1000; cur = 0
                case .million: total += (cur == 0 ? 1 : cur) * 1_000_000; cur = 0
                default: cur += v
                }
            }
            total += cur

            // « un / une » isolé = article le plus souvent : on ne convertit que s'il est en fin de
            // segment (« Un, vingt-trois. ») ou dans un nombre composé.
            var value = String(total)
            if seq.count == 1, first.1 == .unit, first.0 == 1 {
                var nextIdx = end + 1
                let atBoundary = nextIdx >= toks.count || (!toks[nextIdx].isWord && !isSep(toks[nextIdx]))
                if nextIdx < toks.count, isSep(toks[nextIdx]) { nextIdx += 1 }
                if !atBoundary { result += t.text; i = end + 1; continue }
            }

            // « zéro sept quarante-neuf » → « 07 49 » : zéro collé au nombre suivant.
            if seq.count == 1, first.1 == .zero, end + 2 < toks.count, isSep(toks[end + 1]),
               toks[end + 2].isWord, let nx = words[toks[end + 2].text.lowercased()],
               nx.1 == .unit || nx.1 == .teen {
                value = "0"; // le chiffre suivant sera collé par la boucle suivante
                result += value
                i = end + 2
                // convertit le mot suivant seul, collé
                let nextWord = toks[i]
                result += String(nx.0); i += 1
                _ = nextWord
                continue
            }

            result += value
            i = end + 1
        }
        return result
    }
}
