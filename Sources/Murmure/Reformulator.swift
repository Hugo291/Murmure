import Foundation

/// Reformule / corrige le texte via un LLM local.
/// Moteur principal : LM Studio (MLX, rapide). Repli automatique : Ollama. Sinon texte brut.
/// Jamais bloquant pour l'utilisateur.
enum Reformulator {
    static func process(_ text: String, mode: ReformMode, token: CancelToken? = nil) -> String {
        guard mode != .off else { return text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let system: String
        switch mode {
        case .light:
            system = """
            Tu nettoies un texte dicté à la voix. Corrige la ponctuation, les majuscules et les fautes d'orthographe/grammaire.
            SUPPRIME les répétitions involontaires, les bégaiements, les faux départs et les mots de remplissage parasites (euh, bah, « pour pour pour »).
            Garde les mots et le style de l'utilisateur (registre familier compris), ne reformule pas, ne change pas le sens, n'ajoute rien, ne commente pas.
            Réponds UNIQUEMENT avec le texte nettoyé, sans guillemets ni préambule.
            """
        case .full:
            system = """
            Tu es un rédacteur. On te donne un texte dicté à la voix.
            Reformule-le pour qu'il soit clair, fluide et bien écrit, en conservant fidèlement le sens et la langue d'origine.
            Réponds UNIQUEMENT avec le texte final, sans guillemets ni préambule ni commentaire.
            """
        case .off:
            return text
        }

        var system2 = system
        let terms = CorrectionStore.shared.glossaryTerms(limit: 40)
        if !terms.isEmpty {
            system2 += "\n\nVocabulaire de l'utilisateur (si un mot transcrit ressemble à l'un d'eux, " +
                "rétablis cette orthographe exacte) : " + terms.joined(separator: ", ") + "."
        }

        return run(system: system2, user: trimmed, token: token) ?? text
    }

    /// Reformule/nettoie un texte sélectionné (Cmd+R) : enlève répétitions et tics, garde l'idée.
    static func summarize(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return text }
        let sys = """
        Reformule le texte suivant pour qu'il soit clair, fluide et concis.
        Supprime les répétitions, les hésitations et les tics de langage (« du coup », « en fait », « genre », « tu vois », « voilà »…).
        Garde fidèlement l'idée principale et le sens, dans la même langue. Ne commente pas.
        Réponds UNIQUEMENT avec le texte reformulé, sans guillemets ni préambule.
        """
        return run(system: sys, user: t, token: nil) ?? text
    }

    /// Envoie au moteur (LM Studio en principal, repli Ollama). nil si tout échoue.
    private static func run(system: String, user: String, token: CancelToken?) -> String? {
        if Config.reformBackend == "lmstudio" {
            if let r = callLMStudio(system: system, user: user, token: token) { return r }
            if token?.cancelled == true { return nil }
            return callOllama(system: system, user: user, token: token) // repli si LM Studio éteint
        }
        return callOllama(system: system, user: user, token: token)
    }

    // MARK: - Catalogue de modèles installés (jamais de téléchargement)

    /// Modèles INSTALLÉS dans Ollama (GET /api/tags). Vide si Ollama est éteint. Bloquant → appeler hors main.
    static func ollamaModels() -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let json = getJSON(url),
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.filter(isChatModel).sorted()
    }

    /// Modèles disponibles dans LM Studio (GET /v1/models). Vide si LM Studio est éteint. Bloquant → hors main.
    static func lmStudioModels() -> [String] {
        guard let json = getJSON(URL(string: "http://localhost:1234/v1/models")!),
              let data = json["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { $0["id"] as? String }.filter(isChatModel).sorted()
    }

    /// Écarte les modèles non conversationnels (embeddings, reranking, image, audio) qui ne reformulent pas.
    private static func isChatModel(_ name: String) -> Bool {
        let n = name.lowercased()
        let exclude = ["embed", "rerank", "bge-", "image", "flux", "clip", "diffusion",
                       "sdxl", "whisper", "tts", "minilm", "nomic"]
        return !exclude.contains { n.contains($0) }
    }

    private static func getJSON(_ url: URL) -> [String: Any]? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        let sem = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { out = j }
        }.resume()
        _ = sem.wait(timeout: .now() + 2.0)
        return out
    }

    // MARK: - Backends

    private static func callLMStudio(system: String, user: String, token: CancelToken?) -> String? {
        let body: [String: Any] = [
            "model": Config.lmstudioModel,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "temperature": 0.2,
            "stream": false,
            "max_tokens": 400,
        ]
        return syncPost(Config.lmstudioURL, body, token) { json in
            guard let choices = json["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else { return nil }
            return content
        }
    }

    private static func callOllama(system: String, user: String, token: CancelToken?) -> String? {
        let body: [String: Any] = [
            "model": Config.ollamaModel,
            "prompt": "\(system)\n\nTexte :\n\(user)",
            "stream": false,
            "keep_alive": "30m",
            "options": ["temperature": 0.2],
        ]
        return syncPost(Config.ollamaURL, body, token) { json in json["response"] as? String }
    }

    /// POST synchrone (sur file de fond) avec extraction du texte. nil si échec/annulation.
    private static func syncPost(_ url: URL, _ body: [String: Any], _ token: CancelToken?,
                                 extract: @escaping ([String: Any]) -> String?) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 60

        let sem = DispatchSemaphore(value: 0)
        var out: String?
        let task = URLSession.shared.dataTask(with: req) { respData, _, err in
            defer { sem.signal() }
            guard err == nil, let respData,
                  let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                  let s = extract(json) else { return }
            let cleaned = stripWrapping(s)
            if !cleaned.isEmpty { out = cleaned }
        }
        token?.ollamaTask = task
        if token?.cancelled == true { return nil }
        task.resume()
        _ = sem.wait(timeout: .now() + 65)
        return out
    }

    /// Mesure le temps de réponse d'un moteur/modèle sur un petit prompt. nil si indisponible.
    static func benchmark(backend: String, model: String) -> Double? {
        let sys = "Tu corriges un texte dicté. Réponds uniquement avec le texte corrigé, sans commentaire."
        let user = "voici une petite phrase de test pour mesurer la vitesse du modèle"
        let url: URL
        let body: [String: Any]
        let extract: ([String: Any]) -> String?
        if backend == "lmstudio" {
            url = Config.lmstudioURL
            body = ["model": model,
                    "messages": [["role": "system", "content": sys], ["role": "user", "content": user]],
                    "temperature": 0.2, "stream": false, "max_tokens": 60]
            extract = { json in
                guard let choices = json["choices"] as? [[String: Any]],
                      let msg = choices.first?["message"] as? [String: Any],
                      let content = msg["content"] as? String else { return nil }
                return content
            }
        } else {
            url = Config.ollamaURL
            body = ["model": model, "prompt": sys + "\n\n" + user, "stream": false,
                    "keep_alive": "30m", "options": ["temperature": 0.2]]
            extract = { json in json["response"] as? String }
        }
        let start = Date()
        let result = syncPost(url, body, nil, extract: extract)
        return result == nil ? nil : Date().timeIntervalSince(start)
    }

    /// Précharge le modèle (au démarrage d'enregistrement) pour qu'il soit prêt à l'arrêt.
    static func warmUp() {
        guard Config.reformMode != .off else { return }
        if Config.reformBackend == "lmstudio" {
            fire(Config.lmstudioURL, [
                "model": Config.lmstudioModel,
                "messages": [["role": "user", "content": "hi"]],
                "max_tokens": 1, "stream": false,
            ])
        } else {
            fire(Config.ollamaURL, ["model": Config.ollamaModel, "prompt": "", "stream": false, "keep_alive": "30m"])
        }
    }

    private static func fire(_ url: URL, _ body: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        URLSession.shared.dataTask(with: req).resume()
    }

    /// Enlève guillemets / préambules parasites parfois ajoutés par le modèle.
    private static func stripWrapping(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("«", "»"), ("“", "”")]
        for (open, close) in pairs where t.first == open && t.last == close && t.count > 1 {
            t = String(t.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }
}
