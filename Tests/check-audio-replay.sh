#!/bin/zsh
set -eu
cd "${0:A:h:h}"
check_dir=$(mktemp -d)
trap 'rm -rf "$check_dir"' EXIT
cat > "$check_dir/main.swift" <<'SWIFT'
import Foundation

enum Config {
    static let supportDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    static var retainAudio = false
}
let fm = FileManager.default
try fm.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: Config.supportDir) }
let source = Config.supportDir.appendingPathComponent("sample.wav")
try Data(repeating: 0, count: 1024).write(to: source)
let store = AudioReplayStore.shared
store.retain(source)
assert(store.audioURL("sample.wav") == nil)
Config.retainAudio = true
store.retain(source)
assert(store.audioURL("sample.wav") != nil)
assert(store.audioURL("../sample.wav") == nil)
let saved = store.directory.appendingPathComponent("sample.wav")
try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-1201)], ofItemAtPath: saved.path)
assert(store.audioURL("sample.wav") == nil)
store.prune()
assert(!fm.fileExists(atPath: saved.path))
store.retain(source)
let huge = store.directory.appendingPathComponent("large.wav")
fm.createFile(atPath: huge.path, contents: nil)
let handle = try FileHandle(forWritingTo: huge)
try handle.truncate(atOffset: UInt64(AudioReplayStore.byteLimit + 1))
try handle.close()
store.prune()
let remaining = try fm.contentsOfDirectory(atPath: store.directory.path)
assert(remaining.isEmpty)
store.retain(source)
Config.retainAudio = false
store.prune()
assert(!fm.fileExists(atPath: store.directory.path))
assert(fm.fileExists(atPath: source.path))
print("Audio replay checks passed")
SWIFT
swiftc Sources/Murmure/AudioReplayStore.swift "$check_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
