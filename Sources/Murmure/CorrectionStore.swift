import Foundation
import Combine

/// Un transcript inséré + sa version corrigée (si l'utilisateur l'a éditée).
struct TranscriptEntry: Codable {
    let id: UUID
    let date: Date
    let inserted: String       // ce que Murmure a collé (après correction légère)
    var corrected: String?     // ce que l'utilisateur a finalement gardé
}

/// Un mot candidat au vocabulaire, EN ATTENTE de validation par l'utilisateur.
/// Les mots n'entrent dans le dictionnaire qu'après un « Valider » explicite.
struct PendingTerm: Codable, Identifiable {
    let id: UUID
    let term: String      // le mot corrigé à ajouter
    let heard: String     // ce que whisper avait transcrit
    let context: String?  // la phrase corrigée où le mot apparaît (pour décider en connaissance de cause)
    let date: Date
}

/// Persiste l'historique des transcripts et le « vocabulaire appris » à partir des
/// corrections de l'utilisateur. Sert ensuite à biaiser whisper et le LLM.
final class CorrectionStore: ObservableObject {
    static let shared = CorrectionStore()

    private let url: URL
    @Published private(set) var transcripts: [TranscriptEntry] = []
    /// Terme corrigé (casse d'affichage) → nombre d'occurrences. Vocabulaire VALIDÉ.
    @Published private(set) var glossary: [String: Int] = [:]
    /// Mots détectés mais EN ATTENTE de validation (l'étape de validation du dictionnaire).
    @Published private(set) var pending: [PendingTerm] = []
    /// Mots explicitement rejetés (en minuscules) → on ne les re-propose plus.
    private var rejected: Set<String> = []
    private let maxHistory = 200

    private struct Payload: Codable {
        var transcripts: [TranscriptEntry]
        var glossary: [String: Int]
        var pending: [PendingTerm]?   // optionnel : compat avec les anciens fichiers
        var rejected: [String]?
    }

    init() {
        url = Config.supportDir.appendingPathComponent("corrections.json")
        load()
    }

    // MARK: - Écriture

    @discardableResult
    func addTranscript(_ inserted: String) -> UUID {
        let entry = TranscriptEntry(id: UUID(), date: Date(), inserted: inserted, corrected: nil)
        transcripts.append(entry)
        if transcripts.count > maxHistory { transcripts.removeFirst(transcripts.count - maxHistory) }
        save()
        return entry.id
    }

    /// Enregistre une correction (détectée auto ou via le panneau) et apprend le vocabulaire.
    /// Renvoie les mots effectivement ajoutés au vocabulaire (pour le toast / l'annulation).
    @discardableResult
    func applyCorrection(id: UUID?, inserted: String, corrected: String) -> [String] {
        let clean = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != inserted else { return [] }

        if let id, let idx = transcripts.firstIndex(where: { $0.id == id }) {
            transcripts[idx].corrected = clean
        } else if let idx = transcripts.lastIndex(where: { $0.inserted == inserted && $0.corrected == nil }) {
            transcripts[idx].corrected = clean
        }
        let learned = learn(from: inserted, to: clean)
        save()
        return learned
    }

    /// Ajoute un mot au vocabulaire directement (saisi à la main). Conserve la casse et le slash.
    func addTerm(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        glossary[t, default: 0] += 1
        save()
    }

    /// Retire complètement un mot du vocabulaire.
    func removeTerm(_ term: String) {
        glossary[term] = nil
        save()
    }

    /// Le dernier transcript livré (version corrigée si elle existe).
    var lastText: String? {
        guard let t = transcripts.last else { return nil }
        return t.corrected ?? t.inserted
    }

    /// Retire `terms` de la file d'attente (annulation douce depuis le toast — ni validé, ni rejeté).
    func unlearn(_ terms: [String]) {
        let keys = Set(terms.map { $0.lowercased() })
        pending.removeAll { keys.contains($0.term.lowercased()) }
        save()
    }

    // MARK: - Validation du dictionnaire

    /// Valide un mot en attente → il entre dans le vocabulaire.
    func validatePending(_ id: UUID) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        glossary[pending[idx].term, default: 0] += 1
        pending.remove(at: idx)
        save()
    }

    /// Rejette un mot en attente → retiré, et plus jamais re-proposé.
    func rejectPending(_ id: UUID) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        rejected.insert(pending[idx].term.lowercased())
        pending.remove(at: idx)
        save()
    }

    /// Valide tous les mots en attente d'un coup.
    func validateAllPending() {
        for p in pending { glossary[p.term, default: 0] += 1 }
        pending.removeAll()
        save()
    }

    /// Efface tout : historique des dictées ET vocabulaire appris.
    func clearAll() {
        transcripts = []
        glossary = [:]
        pending = []
        rejected = []
        save()
    }

    /// Efface uniquement le vocabulaire appris (garde l'historique).
    func clearGlossary() {
        glossary = [:]
        save()
    }

    /// Efface uniquement l'historique des dictées (garde le vocabulaire).
    func clearTranscripts() {
        transcripts = []
        save()
    }

    /// Mots issus d'une SUBSTITUTION (un mot mal transcrit remplacé par le bon) → mis EN ATTENTE
    /// de validation (jamais directement dans le dictionnaire). Renvoie les mots mis en file.
    @discardableResult
    private func learn(from original: String, to corrected: String) -> [String] {
        var added: [String] = []
        for (heard, word) in substitutionPairs(tokens(original), tokens(corrected)) {
            guard word.count >= 3, isWordlike(word) else { continue }
            let key = word.lowercased()
            // Ignore : déjà validé, déjà en attente, ou explicitement rejeté.
            if glossary[word] != nil { continue }
            if pending.contains(where: { $0.term.lowercased() == key }) { continue }
            if rejected.contains(key) { continue }
            let ctx = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            pending.append(PendingTerm(id: UUID(), term: word, heard: heard,
                                       context: String(ctx.prefix(240)), date: Date()))
            added.append(word)
        }
        return added
    }

    private enum DiffKind { case equal, removed, added }

    /// Pour chaque « trou » du diff contenant À LA FOIS du retiré et de l'ajouté (≈ remplacement),
    /// renvoie (entendu, mot ajouté). Ignore les ajouts/suppressions purs.
    private func substitutionPairs(_ old: [String], _ new: [String]) -> [(String, String)] {
        let ops = diffOps(old, new)
        var result: [(String, String)] = []
        var i = 0
        while i < ops.count {
            if ops[i].1 == .equal { i += 1; continue }
            var removedWords: [String] = []
            var addedWords: [String] = []
            while i < ops.count, ops[i].1 != .equal {
                if ops[i].1 == .removed { removedWords.append(ops[i].0) } else { addedWords.append(ops[i].0) }
                i += 1
            }
            if !removedWords.isEmpty, !addedWords.isEmpty {
                let heard = removedWords.joined(separator: " ")
                for w in addedWords { result.append((heard, w)) }
            }
        }
        return result
    }

    private func diffOps(_ old: [String], _ new: [String]) -> [(String, DiffKind)] {
        let n = old.count, m = new.count
        if n == 0 { return new.map { ($0, .added) } }
        if m == 0 { return old.map { ($0, .removed) } }
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var ops: [(String, DiffKind)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i] == new[j] { ops.append((old[i], .equal)); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { ops.append((old[i], .removed)); i += 1 }
            else { ops.append((new[j], .added)); j += 1 }
        }
        while i < n { ops.append((old[i], .removed)); i += 1 }
        while j < m { ops.append((new[j], .added)); j += 1 }
        return ops
    }

    private func tokens(_ s: String) -> [String] {
        // On NE splitte PAS sur "/" ni "-" : « /use-chatgpt » reste un seul token.
        s.components(separatedBy: CharacterSet(charactersIn: " \n\t.,;:!?…\"«»“”()[]{}"))
            .filter { !$0.isEmpty }
    }

    private func isWordlike(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "'" || $0 == "-" || $0 == "/"
        }
    }

    // MARK: - Lecture (pour biaiser whisper / le LLM)

    /// Les `limit` termes les plus fréquents du vocabulaire appris (pour biaiser whisper/LLM).
    func glossaryTerms(limit: Int = 60) -> [String] {
        glossary.sorted { $0.value > $1.value }.prefix(limit).map { $0.key }
    }

    /// Tout le vocabulaire trié par ordre alphabétique (pour l'affichage dans la fenêtre).
    var glossaryAlphabetical: [String] {
        glossary.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Les `limit` transcripts les plus récents (pour le panneau d'historique).
    func recent(limit: Int = 40) -> [TranscriptEntry] {
        Array(transcripts.suffix(limit).reversed())
    }

    // MARK: - Persistance

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let p = try? dec.decode(Payload.self, from: data) {
            transcripts = p.transcripts
            glossary = p.glossary
            pending = p.pending ?? []
            rejected = Set(p.rejected ?? [])
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = Payload(transcripts: transcripts, glossary: glossary,
                              pending: pending, rejected: Array(rejected))
        if let data = try? enc.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
