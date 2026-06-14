import Speech
import AVFoundation

/// Aperçu de transcription EN TEMPS RÉEL via la reconnaissance vocale on-device d'Apple.
/// Sert UNIQUEMENT à afficher ce qu'on dit pendant qu'on parle — le texte réellement collé
/// vient de whisper. `requiresOnDeviceRecognition = true` : rien n'est envoyé sur Internet.
final class LiveTranscriber {
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()       // protège `request` (lu depuis le thread audio, écrit sur main)
    private var generation = 0        // invalide les résultats d'une session déjà arrêtée

    /// Texte partiel courant (sur la file principale).
    var onText: ((String) -> Void)?

    /// Demande l'autorisation Reconnaissance vocale (au démarrage de l'app).
    static func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    /// Démarre l'aperçu pour la langue donnée. Renvoie false si indisponible (autorisation refusée
    /// ou pas de modèle on-device pour la langue) — dans ce cas, simplement pas d'aperçu.
    @discardableResult
    func start(localeID: String) -> Bool {
        stop()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let rec = SFSpeechRecognizer(locale: Locale(identifier: localeID)),
              rec.isAvailable, rec.supportsOnDeviceRecognition else { return false }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true   // jamais de cloud
        req.shouldReportPartialResults = true

        lock.lock()
        generation += 1
        let gen = generation
        recognizer = rec
        request = req
        lock.unlock()

        task = rec.recognitionTask(with: req) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                guard self.generation == gen else { return } // ignore un résultat d'une session arrêtée
                self.onText?(text)
            }
        }
        return true
    }

    /// Alimente le moteur avec un buffer micro (appelé depuis le tap audio — thread temps réel).
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }

    func stop() {
        lock.lock()
        generation += 1        // invalide les callbacks en vol
        let r = request
        request = nil          // plus aucun `append` n'aboutira après ça
        lock.unlock()

        task?.cancel()         // annule AVANT endAudio pour éviter un dernier résultat tardif
        r?.endAudio()
        task = nil
        recognizer = nil
    }
}
