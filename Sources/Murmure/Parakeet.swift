import Foundation
import FluidAudio

/// Transcription par Parakeet TDT 0.6B v3 (NVIDIA, 25 langues européennes) via FluidAudio, 100 % local.
/// Tourne sur le Neural Engine (GPU laissé à la retouche IA) et reste chargé entre deux dictées :
/// pas de rechargement du modèle à chaque fois, contrairement à whisper-cli.
/// Modèles dans ~/Library/Application Support/FluidAudio (≈ 470 Mo), téléchargés à la demande seulement.
enum Parakeet {
    static var isInstalled: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    static func download() async throws { try await AsrModels.download(version: .v3) }

    /// Charge le modèle en fond pour que la prochaine dictée parte tout de suite.
    static func preload() {
        guard isInstalled else { return }
        Task { _ = try? await engine.manager() }
    }

    /// Bloquant — à appeler sur une file de fond (comme `Transcriber.transcribe`).
    static func transcribe(_ wav: URL) throws -> String {
        let done = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(CancellationError())
        Task {
            do { result = .success(try await engine.transcribe(wav)) } catch { result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try result.get()
    }

    private static let engine = Engine()

    /// Sérialise chargement et transcriptions (AsrManager n'est pas fait pour des appels concurrents).
    private actor Engine {
        private var loading: Task<AsrManager, Error>?
        private var busy: Task<String, Error>?

        func manager() async throws -> AsrManager {
            if let loading { return try await loading.value }
            let t = Task {
                let asr = AsrManager(config: .default)
                try await asr.initialize(models: try await AsrModels.loadFromCache(version: .v3))
                return asr
            }
            loading = t
            do { return try await t.value } catch { loading = nil; throw error }
        }

        func transcribe(_ wav: URL) async throws -> String {
            let previous = busy
            let t = Task<String, Error> {
                _ = try? await previous?.value
                // Parakeet exige ≥ 1 s (16 000 échantillons à 16 kHz), sinon ASRError.invalidAudioData :
                // une dictée de 0,3 à 1 s (« oui », arrêt trop rapide) est complétée de silence.
                var samples = try AudioConverter().resampleAudioFile(wav)
                if samples.count < 16_000 { samples += [Float](repeating: 0, count: 16_000 - samples.count) }
                return try await self.manager().transcribe(samples).text
            }
            busy = t
            return try await t.value
        }
    }
}
