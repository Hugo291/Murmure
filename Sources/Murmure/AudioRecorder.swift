import AVFoundation

/// Capture le micro via AVAudioEngine :
///  - écrit l'audio brut (format matériel) dans un fichier,
///  - calcule en direct le spectre (FFT) pour l'overlay,
///  - à l'arrêt, convertit en WAV 16 kHz mono (afconvert) pour whisper.cpp.
final class AudioRecorder: NSObject {
    private let engine = AVAudioEngine()
    private let analyzer = SpectrumAnalyzer()
    private var rawFile: AVAudioFile?
    private var rawURL: URL?
    private var startedAt: Date?
    private var lastLevelSent = Date(timeIntervalSince1970: 0)

    /// Spectre normalisé (0…1), publié sur la file principale.
    var onLevels: (([Float]) -> Void)?
    /// Buffer micro brut (sur le thread audio temps réel) — pour l'aperçu temps réel.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    let bandCount = 28

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default: done(false)
        }
    }

    @discardableResult
    func start() -> Bool {
        analyzer.reset() // repart d'un plancher de bruit propre
        let input = engine.inputNode
        // S'assurer que le voice processing est DÉSACTIVÉ (il cassait la capture sur cette config).
        try? input.setVoiceProcessingEnabled(false)
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return false }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmure-\(UUID().uuidString).caf")
        try? FileManager.default.removeItem(at: url)

        do {
            rawFile = try AVAudioFile(forWriting: url, settings: format.settings)
        } catch {
            NSLog("Murmure: création fichier brut: \(error)")
            return false
        }
        rawURL = url

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.rawFile?.write(from: buffer)
            self.onBuffer?(buffer)
            self.analyze(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("Murmure: démarrage engine: \(error)")
            input.removeTap(onBus: 0)
            return false
        }
        startedAt = Date()
        return true
    }

    private func analyze(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: ch, count: frames))

        // ~50 fps suffit pour l'overlay.
        let now = Date()
        guard now.timeIntervalSince(lastLevelSent) > 0.02 else { return }
        lastLevelSent = now

        let bands = analyzer.bands(from: samples, bandCount: bandCount)
        DispatchQueue.main.async { self.onLevels?(bands) }
    }

    /// Arrête, convertit en 16 kHz mono. Renvoie le WAV prêt pour whisper (nil si trop court).
    func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        rawFile = nil // ferme le fichier

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        guard let raw = rawURL, duration > 0.3 else { return nil }

        let out = raw.deletingPathExtension().appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: out)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", raw.path, out.path]
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            NSLog("Murmure: afconvert: \(error)")
            return nil
        }
        try? FileManager.default.removeItem(at: raw) // le brut ne sert plus
        guard p.terminationStatus == 0,
              let size = try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int,
              size > 2000 else { return nil }
        return out
    }

    /// Arrête immédiatement et jette l'audio (annulation, sans conversion ni transcription).
    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        rawFile = nil
        if let raw = rawURL { try? FileManager.default.removeItem(at: raw) }
        rawURL = nil
        startedAt = nil
    }
}
