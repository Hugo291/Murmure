import AppKit
import SwiftUI

/// Fenêtre « Corrections & vocabulaire » — design Mac natif (SwiftUI).
final class HistoryWindowController: NSWindowController {
    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 580),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = L.tr("Corrections & vocabulary", "Corrections & vocabulaire")
        win.contentViewController = NSHostingController(rootView: HistoryView())
        win.setFrameAutosaveName("MurmureHistory")
        win.center()
        self.init(window: win)
    }

    func showAndReload() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Vue principale

struct HistoryView: View {
    @ObservedObject private var store = CorrectionStore.shared
    @State private var showingClearVocab = false
    @State private var showingClearHistory = false
    @State private var newTerm = ""

    private var terms: [String] { store.glossaryAlphabetical }
    private var entries: [TranscriptEntry] { store.recent(limit: 80) }

    var body: some View {
        VStack(spacing: 0) {
            if !store.pending.isEmpty {
                pendingSection
                Divider()
            }
            vocabularyHeader
            Divider()
            transcriptList
        }
        .frame(minWidth: 440, minHeight: 480)
    }

    // MARK: - Mots à valider (l'étape de validation)

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.plus")
                    .foregroundStyle(Color.accentColor)
                Text(L.tr("Words to validate", "Mots à valider"))
                    .font(.headline)
                Text("\(store.pending.count)")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
                Spacer()
                Button(L.tr("Validate all", "Tout valider")) {
                    store.validateAllPending()
                }
                .controlSize(.small)
            }
            Text(L.tr("New words enter the dictionary only after you approve them.",
                      "Les nouveaux mots n'entrent dans le dictionnaire qu'après ton approbation."))
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(store.pending) { p in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.term).fontWeight(.semibold)
                        Text(L.tr("heard “\(p.heard)”", "entendu « \(p.heard) »"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L.tr("Reject", "Rejeter")) { store.rejectPending(p.id) }
                        .controlSize(.small)
                        .tint(.red)
                    Button(L.tr("Validate", "Valider")) { store.validatePending(p.id) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            }
        }
        .padding()
    }

    private var vocabularyHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.book.closed")
                    .foregroundStyle(.secondary)
                Text(L.tr("Learned vocabulary", "Vocabulaire appris"))
                    .font(.headline)
                Spacer()
                if !terms.isEmpty {
                    Text("\(terms.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Button(role: .destructive) {
                    showingClearVocab = true
                } label: {
                    Label(L.tr("Clear all", "Effacer tout"), systemImage: "trash")
                }
                .controlSize(.small)
                .confirmationDialog(L.tr("Clear all vocabulary?", "Effacer tout le vocabulaire ?"), isPresented: $showingClearVocab, titleVisibility: .visible) {
                    Button(L.tr("Clear vocabulary", "Effacer le vocabulaire"), role: .destructive) { store.clearGlossary() }
                    Button(L.tr("Cancel", "Annuler"), role: .cancel) {}
                } message: {
                    Text(L.tr("Removes all learned words. Your dictation history is kept.", "Supprime tous les mots appris. L'historique des dictées est conservé."))
                }
            }

            if terms.isEmpty {
                Text(L.tr("No terms yet. Correct your dictations below: Murmure learns the words it misheard, then reuses them to transcribe better.", "Aucun terme pour l'instant. Corrige tes dictées ci-dessous : Murmure apprend les mots qu'il a mal entendus, puis les réutilise pour mieux transcrire."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical) {
                    FlowLayout(spacing: 6) {
                        ForEach(terms, id: \.self) { term in
                            HStack(spacing: 4) {
                                Text(term)
                                Button {
                                    store.removeTerm(term)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .help(L.tr("Remove this word", "Retirer ce mot"))
                            }
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }

            HStack(spacing: 6) {
                TextField(L.tr("Add a word to the vocabulary…", "Ajouter un mot au vocabulaire…"), text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addNewTerm)
                Button(L.tr("Add", "Ajouter"), action: addNewTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .font(.callout)
        }
        .padding()
    }

    private func addNewTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.addTerm(t)
        newTerm = ""
    }

    private var transcriptList: some View {
        List {
            Section {
                if entries.isEmpty {
                    Text(L.tr("No dictation yet.", "Aucune dictée pour l'instant."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries, id: \.id) { entry in
                        TranscriptRow(entry: entry)
                    }
                }
            } header: {
                HStack {
                    Text(L.tr("Recent dictations", "Dictées récentes"))
                    Spacer()
                    Button(role: .destructive) {
                        showingClearHistory = true
                    } label: {
                        Label(L.tr("Clear all", "Effacer tout"), systemImage: "trash")
                    }
                    .controlSize(.small)
                    .textCase(nil)
                    .confirmationDialog(L.tr("Clear all history?", "Effacer tout l'historique ?"), isPresented: $showingClearHistory, titleVisibility: .visible) {
                        Button(L.tr("Clear history", "Effacer l'historique"), role: .destructive) { store.clearTranscripts() }
                        Button(L.tr("Cancel", "Annuler"), role: .cancel) {}
                    } message: {
                        Text(L.tr("Removes all recent dictations. Your learned vocabulary is kept.", "Supprime toutes les dictées récentes. Le vocabulaire appris est conservé."))
                    }
                }
            } footer: {
                Text(L.tr("Edit a text to correct what Murmure misheard — it queues the words for you to validate.", "Édite un texte pour corriger ce que Murmure a mal compris — il propose les mots à valider."))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Une ligne (transcript éditable + copie)

struct TranscriptRow: View {
    let entry: TranscriptEntry
    @State private var text: String
    @State private var copied = false
    @FocusState private var focused: Bool

    init(entry: TranscriptEntry) {
        self.entry = entry
        _text = State(initialValue: entry.corrected ?? entry.inserted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.day().month().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if entry.corrected != nil {
                    Label(L.tr("corrected", "corrigé"), systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.borderless)
                .help(L.tr("Copy this text", "Copier ce texte"))
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($focused)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }

            // Diff : ce que Murmure avait écrit → ta correction (rouge barré = retiré, vert = ajouté).
            if let corrected = entry.corrected {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 1)
                    diffText(entry.inserted, corrected)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != entry.inserted, t != entry.corrected else { return }
        CorrectionStore.shared.applyCorrection(id: entry.id, inserted: entry.inserted, corrected: t)
    }
}

// MARK: - Disposition en flux (puces de vocabulaire qui passent à la ligne)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - Diff mot à mot (avant → après)

private enum DiffKind { case equal, removed, added }

/// Diff mot à mot par plus longue sous-séquence commune (LCS).
private func wordDiff(_ old: [String], _ new: [String]) -> [(String, DiffKind)] {
    let n = old.count, m = new.count
    if n == 0 { return new.map { ($0, .added) } }
    if m == 0 { return old.map { ($0, .removed) } }
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
        for j in stride(from: m - 1, through: 0, by: -1) {
            dp[i][j] = old[i] == new[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
        }
    }
    var res: [(String, DiffKind)] = []
    var i = 0, j = 0
    while i < n && j < m {
        if old[i] == new[j] { res.append((old[i], .equal)); i += 1; j += 1 }
        else if dp[i + 1][j] >= dp[i][j + 1] { res.append((old[i], .removed)); i += 1 }
        else { res.append((new[j], .added)); j += 1 }
    }
    while i < n { res.append((old[i], .removed)); i += 1 }
    while j < m { res.append((new[j], .added)); j += 1 }
    return res
}

/// Construit un `Text` coloré : retiré = rouge barré, ajouté = vert, inchangé = gris.
private func diffText(_ old: String, _ new: String) -> Text {
    let segs = wordDiff(old.split(separator: " ").map(String.init),
                        new.split(separator: " ").map(String.init))
    var out = Text("")
    for (w, kind) in segs {
        let piece: Text
        switch kind {
        case .equal:   piece = Text(w + " ").foregroundStyle(.secondary)
        case .removed: piece = Text(w + " ").foregroundStyle(Color.red).strikethrough()
        case .added:   piece = Text(w + " ").foregroundStyle(Color.green)
        }
        out = out + piece
    }
    return out
}
