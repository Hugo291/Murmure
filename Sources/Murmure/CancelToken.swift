import Foundation

/// Jeton d'annulation d'un traitement en cours (transcription whisper + reformulation Ollama).
/// `cancel()` marque le jeton ET interrompt le sous-process / la requête réseau associés.
final class CancelToken {
    private(set) var cancelled = false
    var process: Process?              // whisper-cli en cours
    var ollamaTask: URLSessionDataTask? // requête Ollama en cours

    func cancel() {
        cancelled = true
        process?.terminate()
        ollamaTask?.cancel()
    }
}
