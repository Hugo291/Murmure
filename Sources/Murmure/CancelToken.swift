import Foundation

/// Jeton d'annulation d'un traitement en cours (transcription whisper + reformulation Ollama).
/// `cancel()` marque le jeton ET interrompt le sous-process / la requête réseau associés.
final class CancelToken {
    private(set) var cancelled = false
    /// Retouche IA sautée (raccourci « Passer la retouche ») : le job livre le texte brut de Whisper.
    private(set) var reformSkipped = false
    var process: Process?              // whisper-cli en cours
    var ollamaTask: URLSessionDataTask? // requête LLM en cours (Ollama ou LM Studio)

    func cancel() {
        cancelled = true
        process?.terminate()
        ollamaTask?.cancel()
    }

    /// Coupe la requête LLM en cours (ou empêche la prochaine) SANS annuler la dictée.
    func skipReform() {
        reformSkipped = true
        ollamaTask?.cancel()
    }
}
