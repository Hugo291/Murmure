import Foundation

/// Transcrit un WAV via whisper.cpp (whisper-cli), 100% local.
enum Transcriber {
    enum TranscribeError: Error, CustomStringConvertible {
        case noBinary
        case noModel
        case failed(String)
        var description: String {
            switch self {
            case .noBinary: return "whisper-cli introuvable (brew install whisper-cpp)"
            case .noModel:  return "Modèle whisper absent (\(Config.modelPath.path))"
            case .failed(let s): return "whisper a échoué: \(s)"
            }
        }
    }

    /// Bloquant — à appeler sur une file de fond.
    static func transcribe(_ wav: URL, token: CancelToken? = nil) throws -> String {
        guard let bin = Config.whisperBinary() else { throw TranscribeError.noBinary }
        guard FileManager.default.fileExists(atPath: Config.modelPath.path) else {
            throw TranscribeError.noModel
        }

        let outBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(wav.deletingPathExtension().lastPathComponent + "-out")
        let outTxt = outBase.appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: outTxt)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        var args = [
            "-m", Config.modelPath.path,
            "-f", wav.path,
            "-otxt",
            "-of", outBase.path,
            "-nt",              // pas d'horodatage
            "--no-prints",      // pas de logs de progression
            "-t", "8",          // threads
        ]
        if Config.language != "auto" {
            args += ["-l", Config.language]
        }
        // Biaise la reconnaissance vers le vocabulaire appris des corrections de l'utilisateur.
        let terms = CorrectionStore.shared.glossaryTerms(limit: 60)
        if !terms.isEmpty {
            args += ["--prompt", terms.joined(separator: ", ")]
        }
        p.arguments = args

        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()

        token?.process = p
        if token?.cancelled == true { throw TranscribeError.failed("annulé") }
        try p.run()
        p.waitUntilExit()

        if token?.cancelled == true { throw TranscribeError.failed("annulé") }
        guard p.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TranscribeError.failed(err)
        }

        let text = (try? String(contentsOf: outTxt, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: outTxt)
        try? FileManager.default.removeItem(at: wav)
        return clean(text)
    }

    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
