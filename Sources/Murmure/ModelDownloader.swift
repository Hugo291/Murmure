import Foundation

/// Télécharge un modèle à la DEMANDE (clic explicite dans le menu) avec retour de progression :
/// - whisper.cpp : fichier ggml depuis Hugging Face (URLSession, progression précise) ;
/// - Ollama      : `ollama pull <model>` ;
/// - LM Studio   : `lms get <terme> -y --mlx` puis démarrage du serveur local.
/// Jamais de téléchargement automatique : tout part d'une action utilisateur.
final class ModelDownloader: NSObject {
    static let shared = ModelDownloader()

    /// État mutable partagé (`active`, `whisperJobs`, `procs`) : TOUJOURS manipulé sur le main.
    /// Les points d'entrée publics viennent d'actions de menu (main) ; les callbacks réseau/CLI
    /// arrivent en fond et repassent par `DispatchQueue.main.async`.
    private var active: Set<String> = []
    /// Processus CLI en cours : retenus ICI pour ne pas être désalloués avant leur terminationHandler.
    private var procs: [String: Process] = [:]
    func isDownloading(_ id: String) -> Bool { active.contains(id) }
    private func begin(_ id: String) -> Bool {
        if active.contains(id) { return false }
        active.insert(id); return true
    }
    private func end(_ id: String) { active.remove(id) }

    private lazy var session: URLSession =
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    // MARK: - whisper.cpp (URLSession, progression précise)

    private struct WhisperJob {
        let id: String
        let dest: URL
        let label: String
        let progress: (Double?, String) -> Void
        let done: (Bool) -> Void
    }
    private var whisperJobs: [Int: WhisperJob] = [:]   // taskIdentifier → job (accès sur main)

    /// Télécharge un fichier ggml whisper dans le dossier support. `progress`/`done` sur le main.
    func downloadWhisper(file: String, url: String, label: String,
                         progress: @escaping (Double?, String) -> Void,
                         done: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let id = "whisper:" + file
        guard begin(id) else { return }
        guard let u = URL(string: url) else { end(id); done(false); return }
        let dest = Config.supportDir.appendingPathComponent(file)
        let task = session.downloadTask(with: u)
        whisperJobs[task.taskIdentifier] = WhisperJob(id: id, dest: dest, label: label,
                                                      progress: progress, done: done)
        progress(0, label)
        task.resume()
    }

    // MARK: - Ollama / LM Studio (CLI)

    /// `ollama pull <model>`. `id` = "ollama:<model>".
    func downloadOllama(model: String,
                        progress: @escaping (Double?, String) -> Void,
                        done: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let bin = Config.ollamaBinary() else { done(false); return }
        runCLI(id: "ollama:" + model, launch: bin, args: ["pull", model], label: model,
               progress: progress, done: done)
    }

    /// `lms get <search> -y --mlx`, puis `lms server start` pour rendre le modèle joignable.
    /// `id` = "lmstudio:<search>".
    func downloadLMStudio(search: String,
                          progress: @escaping (Double?, String) -> Void,
                          done: @escaping (Bool) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let bin = Config.lmsBinary() else { done(false); return }
        runCLI(id: "lmstudio:" + search, launch: bin, args: ["get", search, "-y", "--mlx"], label: search,
               progress: progress,
               done: { ok in
                   // Best-effort : démarre le serveur local (hors main) pour que /v1/models voie le modèle.
                   if ok { DispatchQueue.global(qos: .utility).async { ModelDownloader.fireAndForget(bin, ["server", "start"]) } }
                   done(ok)
               })
    }

    /// Lance une CLI, suit la progression (« NN% » dans la sortie) et conclut sur le main.
    private func runCLI(id: String, launch: String, args: [String], label: String,
                        progress: @escaping (Double?, String) -> Void,
                        done: @escaping (Bool) -> Void) {
        guard begin(id) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launch)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "") + "/usr/local/bin:/opt/homebrew/bin"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        procs[id] = proc   // retient le process jusqu'à sa fin (sinon réaping silencieux → état « busy » figé)
        progress(nil, label)
        pipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            if let pct = ModelDownloader.lastPercent(in: s) {
                DispatchQueue.main.async { progress(Double(pct) / 100.0, label) }
            }
        }
        proc.terminationHandler = { [weak self] p in
            pipe.fileHandleForReading.readabilityHandler = nil
            p.terminationHandler = nil   // casse le cycle proc → handler → proc
            let ok = p.terminationStatus == 0
            DispatchQueue.main.async { self?.procs[id] = nil; self?.end(id); done(ok) }
        }
        do { try proc.run() }
        catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self.procs[id] = nil; self.end(id); done(false) }
        }
    }

    /// Lance une commande sans attendre ni lire sa sortie (ex. démarrer le serveur LM Studio).
    private static func fireAndForget(_ launch: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        try? p.run()
    }

    /// Dernier pourcentage « NN% » trouvé dans un fragment de sortie CLI (0…100), sinon nil.
    static func lastPercent(in s: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: #"(\d{1,3})\s*%"#) else { return nil }
        let ns = s as NSString
        var result: Int?
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m, let r = Range(m.range(at: 1), in: s), let v = Int(s[r]), v <= 100 { result = v }
        }
        return result
    }
}

// MARK: - Progression / fin des téléchargements whisper (URLSession)

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didWriteData _: Int64, totalBytesWritten written: Int64,
                    totalBytesExpectedToWrite expected: Int64) {
        DispatchQueue.main.async {
            guard let job = self.whisperJobs[task.taskIdentifier] else { return }
            let frac = expected > 0 ? Double(written) / Double(expected) : nil
            job.progress(frac, job.label)
        }
    }

    func urlSession(_ session: URLSession, downloadTask task: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // `location` est supprimé dès le retour de cette méthode : on déplace le fichier MAINTENANT,
        // vers un temp DÉTERMINISTE (sans toucher au dictionnaire hors du main). Le placement final
        // (temp → destination) se fait sur le main, où l'on connaît la destination du job.
        let tmp = Config.supportDir.appendingPathComponent(".dl-\(task.taskIdentifier).part")
        var staged = false
        if let http = task.response as? HTTPURLResponse, http.statusCode == 200 {
            try? FileManager.default.removeItem(at: tmp)
            if (try? FileManager.default.moveItem(at: location, to: tmp)) != nil {
                let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path))?[.size] as? Int ?? 0
                let expected = http.expectedContentLength   // -1 si inconnu
                // Rejette : page d'erreur (< 1 Mo) OU téléchargement tronqué (plus court que Content-Length).
                staged = size > 1_000_000 && (expected <= 0 || Int64(size) >= expected)
                if !staged { try? FileManager.default.removeItem(at: tmp) }
            }
        }
        DispatchQueue.main.async {
            guard let job = self.whisperJobs.removeValue(forKey: task.taskIdentifier) else {
                try? FileManager.default.removeItem(at: tmp); return
            }
            self.end(job.id)
            var ok = false
            if staged {
                try? FileManager.default.removeItem(at: job.dest)
                ok = (try? FileManager.default.moveItem(at: tmp, to: job.dest)) != nil
                if !ok { try? FileManager.default.removeItem(at: tmp) }
            }
            job.done(ok)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Succès déjà géré dans didFinishDownloadingTo ; ici on ne traite que l'échec réseau.
        guard error != nil else { return }
        DispatchQueue.main.async {
            guard let job = self.whisperJobs.removeValue(forKey: task.taskIdentifier) else { return }
            self.end(job.id)
            job.done(false)
        }
    }
}
