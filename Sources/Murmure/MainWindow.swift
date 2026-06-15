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

// MARK: - Palette (alignée sur la maquette)

enum Pal {
    static let blue   = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let indigo = Color(red: 0.37, green: 0.36, blue: 0.90)
    static let teal   = Color(red: 0.19, green: 0.69, blue: 0.78)
    static let gray   = Color(red: 0.56, green: 0.56, blue: 0.58)
    static let grad   = LinearGradient(colors: [blue, indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// Petit faisceau de barres (logo / spectre).
struct BarsGlyph: View {
    var heights: [CGFloat]
    var width: CGFloat = 2.4
    var color: Color = .white
    var body: some View {
        HStack(spacing: width) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule().fill(color).frame(width: width, height: heights[i])
            }
        }
    }
}

struct LogoMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Pal.grad)
            .overlay(BarsGlyph(heights: [8, 12, 16, 12, 8], width: 2.4))
            .shadow(color: Pal.blue.opacity(0.35), radius: 5, y: 2)
    }
}

// MARK: - Vue principale

struct MainView: View {
    @ObservedObject var nav: NavModel
    @ObservedObject var settings: SettingsModel

    var body: some View {
        NavigationSplitView {
            SidebarView(nav: nav)
                .navigationSplitViewColumnWidth(min: 214, ideal: 226, max: 280)
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

// MARK: - Barre latérale (sur mesure : logo, sections, pastilles, pied)

struct SidebarView: View {
    @ObservedObject var nav: NavModel
    @ObservedObject private var store = CorrectionStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                LogoMark().frame(width: 30, height: 30)
                Text("Murmure").font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 12)

            sectionLabel(L.tr("General", "Général"))
            navRow(.accueil, "house", Pal.blue)
            navRow(.dictionnaire, "character.book.closed", Pal.indigo)
            navRow(.historique, "clock.arrow.circlepath", Pal.teal)

            sectionLabel(L.tr("Configuration", "Configuration"))
            navRow(.reglages, "gearshape", Pal.gray)

            Spacer()

            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("\(L.tr("Ready", "Prêt")) · \(Config.whisperLabel(Config.whisperModel))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.top, 8)
            .overlay(Divider(), alignment: .top)
        }
        .padding(10)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 3)
    }

    private func navRow(_ s: AppSection, _ symbol: String, _ color: Color) -> some View {
        let sel = nav.section == s
        return Button { nav.section = s } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(sel ? Color.white.opacity(0.22) : color)
                    .frame(width: 24, height: 24)
                    .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                Text(s.title).font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(sel ? Pal.blue : .clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(sel ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Accueil (sur mesure : stats compactes + aperçus overlay + indicateur curseur)

struct DashboardView: View {
    @ObservedObject private var store = CorrectionStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    statCard("\(store.transcripts.count)", L.tr("Dictations", "Dictées"), "waveform", Pal.blue)
                    statCard("\(store.glossary.count)", L.tr("Dictionary words", "Mots au dictionnaire"), "character.book.closed", Pal.indigo)
                    statCard("\(store.pending.count)", L.tr("To validate", "À valider"), "checklist", store.pending.isEmpty ? Pal.gray : .orange)
                }

                section(L.tr("Overlay, live", "L'overlay, en direct")) {
                    HStack(spacing: 16) {
                        hud(brain: false, trailing: "0:04", calm: false)
                        hud(brain: true, trailing: L.tr("thinking…", "réfléchit…"), calm: true)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(stageBG)
                }

                section(L.tr("Indicator at the caret", "Indicateur au point de saisie")) {
                    HStack(spacing: 18) {
                        ZStack(alignment: .topTrailing) {
                            HStack(spacing: 0) {
                                Text(L.tr("Hello, this is a dictation", "Bonjour, ceci est une dictée"))
                                Rectangle().fill(Pal.blue).frame(width: 2, height: 17)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .background(.background, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, lineWidth: 0.5))
                            caretPastille.offset(x: 11, y: -11)
                        }
                        Text(L.tr("A pastille marks the field receiving the transcription. Click it to cancel the destination.",
                                  "Une pastille marque le champ qui reçoit la transcription. Clique-la pour annuler la destination."))
                            .font(.caption).foregroundStyle(.secondary).frame(width: 230, alignment: .leading)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(stageBG)
                }
            }
            .padding(26)
        }
        .navigationTitle(L.tr("Home", "Accueil"))
    }

    private var stageBG: some ShapeStyle { LinearGradient(colors: [Color(white: 0.93), Color(white: 0.89)], startPoint: .top, endPoint: .bottom) }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content().clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func statCard(_ n: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15, weight: .semibold))
            Text(n).font(.system(size: 26, weight: .semibold))
            Text(label).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func hud(brain: Bool, trailing: String, calm: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Pal.grad).frame(width: 30, height: 30).shadow(color: Pal.blue.opacity(0.4), radius: 5, y: 2)
                if brain {
                    Image(systemName: "brain.head.profile").foregroundStyle(.white).font(.system(size: 14, weight: .semibold))
                } else {
                    BarsGlyph(heights: [8, 13, 8], width: 2.4)
                }
            }
            spectrum(calm: calm)
            Text(trailing).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 16).frame(height: 54)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.55), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }

    private func spectrum(calm: Bool) -> some View {
        let n = 16
        return HStack(spacing: 2.4) {
            ForEach(0..<n, id: \.self) { i in
                let env = sin(Double(i) / Double(n - 1) * .pi)
                let h = calm ? 4 + env * 8 : 4 + env * (0.45 + 0.55 * abs(sin(Double(i) * 1.9))) * 24
                Capsule().fill(Pal.blue.opacity(0.55 + env * 0.45)).frame(width: 3, height: max(3, CGFloat(h)))
            }
        }
    }

    private var caretPastille: some View {
        Circle().fill(Pal.grad).frame(width: 26, height: 26).shadow(color: Pal.blue.opacity(0.5), radius: 5, y: 2)
            .overlay(BarsGlyph(heights: [7, 11, 7], width: 2.0).offset(y: 1))
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
