import AppKit
import SwiftUI

/// Sections de la fenêtre principale (barre latérale).
enum AppSection: String, CaseIterable, Hashable {
    case accueil, dictionnaire, historique, reglages
    var title: String {
        switch self {
        case .accueil:      return L.tr("Home", "Accueil")
        case .dictionnaire: return L.tr("Dictionary", "Dictionnaire")
        case .historique:   return L.tr("History", "Historique")
        case .reglages:     return L.tr("Settings", "Réglages")
        }
    }
    var symbol: String {
        switch self {
        case .accueil:      return "house"
        case .dictionnaire: return "character.book.closed"
        case .historique:   return "clock.arrow.circlepath"
        case .reglages:     return "gearshape"
        }
    }
}

/// Section sélectionnée (pilotable depuis l'extérieur de SwiftUI).
final class NavModel: ObservableObject { @Published var section: AppSection = .accueil }

/// Fenêtre PRINCIPALE — vraie app : redimensionnable, plein écran, barre latérale.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let nav = NavModel()
    let settings = SettingsModel()
    var onClose: (() -> Void)?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "Murmure"
        win.collectionBehavior = [.fullScreenPrimary]   // bouton vert → plein écran
        win.minSize = NSSize(width: 760, height: 520)
        win.tabbingMode = .disallowed
        self.init(window: win)
        win.delegate = self
        win.contentViewController = NSHostingController(rootView: MainView(nav: nav, settings: settings))
        win.setFrameAutosaveName("MurmureMain")
        win.center()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func show(_ section: AppSection? = nil) {
        if let section { nav.section = section }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Vue principale

struct MainView: View {
    @ObservedObject var nav: NavModel
    @ObservedObject var settings: SettingsModel

    private var selection: Binding<AppSection?> {
        Binding(get: { nav.section }, set: { nav.section = $0 ?? nav.section })
    }

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, id: \.self, selection: selection) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 222, max: 300)
        } detail: {
            switch nav.section {
            case .accueil:      DashboardView()
            case .dictionnaire: DictionnaireView()
            case .historique:   HistoriqueView()
            case .reglages:     SettingsView(model: settings)
            }
        }
    }
}

// MARK: - Accueil

struct DashboardView: View {
    @ObservedObject private var store = CorrectionStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    statCard("\(store.recent(limit: 1000).count)", L.tr("Dictations", "Dictées"), "waveform")
                    statCard("\(store.glossary.count)", L.tr("Dictionary words", "Mots au dictionnaire"), "character.book.closed")
                    statCard("\(store.pending.count)", L.tr("To validate", "À valider"), "checklist", store.pending.isEmpty ? .secondary : .orange)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(L.tr("How it works", "Comment ça marche")).font(.headline)
                    HStack(spacing: 14) {
                        step("waveform", L.tr("Press Fn, speak", "Appuie sur Fn, parle"), .blue)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        step("brain.head.profile", L.tr("Local AI cleans it", "L'IA locale nettoie"), .indigo)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        step("text.cursor", L.tr("Pasted at the cursor", "Collé au curseur"), .teal)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(26)
        }
        .navigationTitle(L.tr("Home", "Accueil"))
    }

    private func statCard(_ n: String, _ label: String, _ symbol: String, _ tint: Color = .accentColor) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(n).font(.system(size: 30, weight: .semibold))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func step(_ symbol: String, _ text: String, _ color: Color) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(color).frame(width: 38, height: 38)
                Image(systemName: symbol).foregroundStyle(.white).font(.system(size: 16, weight: .semibold))
            }
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(width: 110)
        }
    }
}

// MARK: - Dictionnaire (validés + à valider, avec contexte)

struct DictionnaireView: View {
    @ObservedObject private var store = CorrectionStore.shared
    @State private var newTerm = ""

    private var terms: [String] { store.glossaryAlphabetical }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !store.pending.isEmpty { pendingCard }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L.tr("Validated vocabulary", "Vocabulaire validé")).font(.headline)
                        Text("\(terms.count)").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    }
                    if terms.isEmpty {
                        Text(L.tr("No validated word yet.", "Aucun mot validé pour l'instant."))
                            .foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 7) {
                            ForEach(terms, id: \.self) { term in
                                HStack(spacing: 5) {
                                    Text(term)
                                    Button { store.removeTerm(term) } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain)
                                }
                                .font(.callout)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    HStack(spacing: 6) {
                        TextField(L.tr("Add a word…", "Ajouter un mot…"), text: $newTerm)
                            .textFieldStyle(.roundedBorder).onSubmit(addTerm)
                        Button(L.tr("Add", "Ajouter"), action: addTerm)
                            .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding(26)
        }
        .navigationTitle(L.tr("Dictionary", "Dictionnaire"))
    }

    private var pendingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checklist").foregroundStyle(.orange)
                Text(L.tr("Words to validate", "Mots à valider")).font(.headline)
                Text("\(store.pending.count)").font(.caption).fontWeight(.semibold).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2).background(.orange, in: Capsule())
                Spacer()
                Button(L.tr("Validate all", "Tout valider")) { store.validateAllPending() }.controlSize(.small)
            }
            ForEach(store.pending) { p in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.term).fontWeight(.semibold)
                        Spacer()
                        Button(L.tr("Reject", "Rejeter")) { store.rejectPending(p.id) }.controlSize(.small).tint(.red)
                        Button(L.tr("Validate", "Valider")) { store.validatePending(p.id) }
                            .controlSize(.small).buttonStyle(.borderedProminent)
                    }
                    if let ctx = p.context, !ctx.isEmpty {
                        Text("« \(ctx) »").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L.tr("heard “\(p.heard)”", "entendu « \(p.heard) »"))
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                Divider()
            }
        }
        .padding(18)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5))
    }

    private func addTerm() {
        let t = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        store.addTerm(t); newTerm = ""
    }
}

// MARK: - Historique (avec bouton copier à droite — voir TranscriptRow)

struct HistoriqueView: View {
    @ObservedObject private var store = CorrectionStore.shared
    @State private var showingClear = false

    var body: some View {
        List {
            if store.transcripts.isEmpty {
                Text(L.tr("No dictation yet.", "Aucune dictée pour l'instant.")).foregroundStyle(.secondary)
            } else {
                ForEach(store.recent(limit: 120), id: \.id) { entry in
                    TranscriptRow(entry: entry)
                }
            }
        }
        .navigationTitle(L.tr("History", "Historique"))
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) { showingClear = true } label: { Image(systemName: "trash") }
                    .help(L.tr("Clear history", "Effacer l'historique"))
                    .confirmationDialog(L.tr("Clear all history?", "Effacer tout l'historique ?"),
                                        isPresented: $showingClear, titleVisibility: .visible) {
                        Button(L.tr("Clear history", "Effacer l'historique"), role: .destructive) { store.clearTranscripts() }
                        Button(L.tr("Cancel", "Annuler"), role: .cancel) {}
                    }
            }
        }
    }
}
