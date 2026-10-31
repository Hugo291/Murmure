#!/bin/zsh
set -eu
cd "${0:A:h:h}"
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
cat > "$check_dir/main.swift" <<'SWIFT'
import Foundation

enum Config {
    static let supportDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}
final class AudioReplayStore {
    static let shared = AudioReplayStore()
    func clear() {}
}
try FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: Config.supportDir) }
let store = CorrectionStore()
let field = UUID()
let id = store.addTranscript("Ancien texte", fieldID: field, appName: "Test", audioFile: "sample.wav")
store.applyCorrection(id: id, inserted: "Ancien texte", corrected: "Texte corrigé")
let pending = store.pending.count
assert(store.replaceTranscription(id: id, text: " Nouvelle analyse \n"))
assert(store.lastText == "Nouvelle analyse")
assert(store.transcripts[0].corrected == nil)
assert(store.transcripts[0].fieldID == field)
assert(store.transcripts[0].audioFile == "sample.wav")
assert(store.pending.count == pending)
assert(!store.replaceTranscription(id: id, text: "  "))
assert(!store.replaceTranscription(id: UUID(), text: "Autre"))
let reloaded = CorrectionStore()
assert(reloaded.lastText == "Nouvelle analyse")
assert(reloaded.transcripts[0].id == id)
print("Reanalysis checks passed")
SWIFT
swiftc Sources/Murmure/CorrectionStore.swift "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
