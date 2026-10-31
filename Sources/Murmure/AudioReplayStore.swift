import AVFoundation
import Combine

/// Copies temporaires indépendantes des WAV de travail de Whisper.
final class AudioReplayStore: ObservableObject {
    static let shared = AudioReplayStore()
    static let lifetime: TimeInterval = 20 * 60
    static let byteLimit = 50 * 1024 * 1024
    let directory = Config.supportDir.appendingPathComponent("AudioReplay", isDirectory: true)
    @Published private(set) var revision = 0
    private var timer: Timer?
    private var player: AVAudioPlayer?

    private init() {
        prune()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.prune() }
    }

    func retain(_ wav: URL) {
        guard Config.retainAudio else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(wav.lastPathComponent)
            try FileManager.default.copyItem(at: wav, to: copy)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: copy.path)
            revision += 1
            prune()
        } catch { NSLog("Murmure: conservation audio: \(error)") }
    }

    func audioURL(_ name: String?) -> URL? {
        guard Config.retainAudio, let name, name == (name as NSString).lastPathComponent else { return nil }
        let url = directory.appendingPathComponent(name)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(date) < Self.lifetime else { return nil }
        return url
    }

    func play(_ url: URL) throws {
        player?.stop()
        player = try AVAudioPlayer(contentsOf: url)
        player?.play()
    }

    func stopPlayback() { player?.stop(); player = nil }

    func clear() {
        player?.stop()
        player = nil
        try? FileManager.default.removeItem(at: directory)
        revision += 1
    }

    func prune() {
        guard Config.retainAudio else {
            if FileManager.default.fileExists(atPath: directory.path) { clear() }
            return
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        let entries = files.compactMap { url -> (URL, Date, Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.1 < $1.1 }
        var bytes = entries.reduce(0) { $0 + $1.2 }
        for (url, date, size) in entries where Date().timeIntervalSince(date) >= Self.lifetime || bytes > Self.byteLimit {
            do {
                try FileManager.default.removeItem(at: url)
                if player?.url == url { player?.stop(); player = nil }
                bytes -= size
                revision += 1
            } catch { NSLog("Murmure: suppression audio: \(error)") }
        }
    }
}
