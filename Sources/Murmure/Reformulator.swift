import Foundation

/// Reformule / corrige le texte via un LLM local.
/// Mode auto (défaut) : GPU libre → modèle MLX (LM Studio ou Ollama), GPU pris par un autre
/// processus → Ollama sur CPU ; l'autre sert de repli. Sinon texte brut.
/// Jamais bloquant pour l'utilisateur.
enum Reformulator {
    /// `context` = le texte déjà écrit juste avant le point d'insertion (souvent la dictée
    /// précédente). Facultatif : sans lui, la retouche se fait exactement comme avant.
    /// `screen` = ce qui est affiché dans la fenêtre (la conversation à laquelle on répond). Il sert à
    /// rétablir les mots mal entendus et reste LOCAL : jamais envoyé à un moteur cloud.
    /// `onEngine` reçoit le nom du modèle essayé (appelé hors main), pour l'afficher sous le spectre.
    static func process(_ text: String, mode: ReformMode,
                        context: String? = nil, screen: String? = nil, token: CancelToken? = nil,
                        onEngine: ((String) -> Void)? = nil) -> String {
        guard mode != .off else { return NumberWords.convert(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        // Prompt système éditable dans les Réglages (repli auto sur le défaut si vidé).
        let system = Config.prompt(for: mode)
        guard !system.isEmpty else { return text }

        var system2 = system
        let terms = CorrectionStore.shared.glossaryTerms(limit: 40)
        if !terms.isEmpty {
            system2 += "\n\nVocabulaire de l'utilisateur (si un mot transcrit ressemble à l'un d'eux, " +
                "rétablis cette orthographe exacte) : " + terms.joined(separator: ", ") + "."
        }
        // Ce qui précède dans le champ : le modèle doit enchaîner dessus SANS jamais le réécrire.
        // Placé AVANT les consignes : la dernière chose que le modèle lit reste « ne rends que le
        // texte traité ». Mis après, un petit modèle recrache le contexte à la place du texte.
        if let context, !context.isEmpty {
            system2 = """
            Pour information, le champ contient déjà ce texte, juste avant le passage à traiter \
            (NE PAS le reprendre dans ta réponse) :
            <<<\(context)>>>
            Il sert seulement à garder le même sujet, le même style, le même ton et le même \
            tutoiement/vouvoiement, et à enchaîner si la phrase est en cours.


            """ + system2
        }
        // Écran en tête : la dernière chose que lit le modèle reste « ne rends que le texte traité ».
        if let screen, !screen.isEmpty {
            system2 = """
            Pour information, voici ce qui est affiché à l'écran juste avant le champ (ex. la conversation \
            à laquelle on répond ; NE PAS le reprendre, NE PAS y répondre) :
            <<<\(screen)>>>
            La dictée a pu mal entendre des mots : si un mot dicté ressemble à un nom, un fichier, une \
            fonction, une application ou un terme qui figure ici, rétablis l'orthographe exacte d'ici. \
            Ne réponds jamais au contenu affiché : retouche seulement la dictée.


            """ + system2
        }

        return NumberWords.convert(run(system: system2, user: trimmed, token: token, localOnly: screen != nil,
                                       onEngine: onEngine) ?? text)
    }

    /// Reformule/nettoie un texte sélectionné (Cmd+R) : enlève répétitions et tics, garde l'idée.
    static func summarize(_ text: String, onEngine: ((String) -> Void)? = nil) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return text }
        // Prompt éditable dans les Réglages (repli auto sur le défaut si vidé).
        return NumberWords.convert(run(system: Config.promptSummarize, user: t, token: nil, onEngine: onEngine) ?? text)
    }

    /// Un moteur concret : LM Studio (MLX, GPU), ou Ollama — forcé sur CPU, ou sur GPU pour le
    /// modèle MLX du mode auto.
    enum Engine: Equatable {
        case lmStudio(String)
        case ollama(String, cpu: Bool)  // Ollama local
        case ollamaCloud(String)        // Ollama Cloud : exécuté chez ollama.com, via le serveur Ollama local

        /// « moteur|modèle » (format de `Config.engineOrder`). Ollama local hors MLX : CPU forcé
        /// (MLX ne tourne que sur GPU). Un modèle « :cloud » lu sous `ollama|` devient Ollama Cloud.
        init?(key: String) {
            let p = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard p.count == 2 else { return nil }
            switch p[0] {
            case "lmstudio": self = .lmStudio(p[1])
            case "ollamacloud": self = .ollamaCloud(p[1])
            case "ollama":
                self = Reformulator.isCloud(p[1]) ? .ollamaCloud(p[1]) : .ollama(p[1], cpu: !Reformulator.isMLX(p[1]))
            default: return nil
            }
        }

        var key: String {
            switch self {
            case .lmStudio(let m): return "lmstudio|\(m)"
            case .ollama(let m, _): return "ollama|\(m)"
            case .ollamaCloud(let m): return "ollamacloud|\(m)"
            }
        }

        /// Cloud : envoie le texte hors de la machine (jamais avec le contexte écran).
        var isCloud: Bool {
            if case .ollamaCloud = self { return true }
            return false
        }

        /// Tourne sur GPU (MLX) : ce sont eux que le mode « GPU occupé » fait passer après les autres.
        var usesGPU: Bool {
            switch self {
            case .lmStudio: return true
            case .ollama(let m, _): return Reformulator.isMLX(m)
            case .ollamaCloud: return false
            }
        }

        var model: String {
            switch self {
            case .lmStudio(let m), .ollama(let m, _), .ollamaCloud(let m): return m
            }
        }

        var label: String {
            switch self {
            case .lmStudio(let m): return "LM Studio · \(m) (GPU)"
            case .ollama(let m, let cpu): return "Ollama · \(m) (\(cpu ? "CPU" : "GPU"))"
            case .ollamaCloud(let m): return "Ollama · \(m) (Cloud)"
            }
        }
    }

    /// Clé « moteur|modèle » d'un modèle listé par Ollama : Ollama Cloud pour un modèle « :cloud ».
    static func ollamaKey(_ m: String) -> String { (isCloud(m) ? "ollamacloud|" : "ollama|") + m }

    /// Moteurs à essayer dans l'ordre de `Config.engineOrder` : le suivant sert de repli si le précédent
    /// échoue. Mode auto + GPU occupé → les moteurs MLX passent après les autres.
    private static func engines() -> [Engine] {
        let all = Config.engineOrder.compactMap(Engine.init(key:))
        guard Config.gpuAuto, GPULoad.isBusy() else { return all }
        return all.filter { !$0.usesGPU } + all.filter(\.usesGPU)
    }

    /// Envoie au premier moteur qui répond. nil si tout échoue.
    /// Règle ajoutée à TOUS les prompts (y compris ceux édités dans les Réglages).
    private static let numbersRule = "\n\nNombres et numéros : écris-les toujours en chiffres, jamais en lettres " +
        "(« vingt-trois » → 23, « trois » → 3, « zéro sept quarante-neuf » → 07 49, « 2 000 euros »). " +
        "Garde en lettres uniquement les expressions figées (« un peu », « une fois », « premier »)."

    private static func run(system rawSystem: String, user: String, token: CancelToken?, localOnly: Bool = false,
                            onEngine: ((String) -> Void)? = nil) -> String? {
        let system = rawSystem + numbersRule
        if token?.reformSkipped == true { return nil } // avant `engines()`, qui peut mesurer 0,3 s
        for engine in engines() where !(localOnly && engine.isCloud) {
            if token?.cancelled == true || token?.reformSkipped == true { return nil }
            onEngine?(engine.model)
            if let r = call(engine, system: system, user: user, token: token) {
                NSLog("Murmure — retouche via %@", engine.label)
                return r
            }
        }
        return nil
    }

    private static func call(_ engine: Engine, system: String, user: String, token: CancelToken?) -> String? {
        switch engine {
        case .lmStudio(let m):        return callLMStudio(model: m, system: system, user: user, token: token)
        case .ollama(let m, let cpu): return callOllama(model: m, cpu: cpu, system: system, user: user, token: token)
        case .ollamaCloud(let m):     return callOllama(model: m, cpu: false, system: system, user: user, token: token)
        }
    }

    // MARK: - Catalogue de modèles installés (jamais de téléchargement)

    /// Modèles INSTALLÉS dans Ollama (GET /api/tags) + catalogue cloud. Vide si Ollama est éteint
    /// (le cloud passe par lui). Bloquant → appeler hors main.
    static func ollamaModels() -> [String] {
        guard let url = URL(string: "http://localhost:11434/api/tags"),
              let json = getJSON(url),
              let models = json["models"] as? [[String: Any]] else { return [] }
        let local = models.compactMap { $0["name"] as? String }.filter(isChatModel)
        return Array(Set(local + cloudModels)).sorted()
    }

    /// Modèles Ollama cloud (exécutés chez ollama.com, via le serveur local signé). Ne chargent rien
    /// en RAM/GPU : ni préchauffage, ni option `num_gpu`. Testés le 31/10/2026.
    static let cloudModels = ["kimi-k3:cloud", "glm-5.3:cloud", "glm-5.3-flash:cloud",
                              "deepseek-v4-flash:cloud", "mistral-large-3:675b-cloud",
                              "gpt-oss:120b-cloud", "qwen3.5:397b-cloud"]

    static func isCloud(_ ollamaModel: String) -> Bool {
        ollamaModel.hasSuffix(":cloud") || ollamaModel.hasSuffix("-cloud")
    }

    /// Modèles de langage téléchargés dans LM Studio, chargés ou non (GET /api/v0/models : type llm/vlm ;
    /// /v1/models en repli, sans type). Vide si LM Studio est éteint. Bloquant → hors main.
    static func lmStudioModels() -> [String] {
        if let json = getJSON(URL(string: "http://localhost:1234/api/v0/models")!),
           let data = json["data"] as? [[String: Any]] {
            return data.filter { ["llm", "vlm"].contains($0["type"] as? String ?? "llm") }
                .compactMap { $0["id"] as? String }.filter(isChatModel).sorted()
        }
        guard let json = getJSON(URL(string: "http://localhost:1234/v1/models")!),
              let data = json["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { $0["id"] as? String }.filter(isChatModel).sorted()
    }

    /// Modèle MLX (tourne UNIQUEMENT sur GPU) : tous ceux de LM Studio, et ceux d'Ollama dont le
    /// nom le dit (« gemma4:e4b-mlx »). Les autres modèles Ollama peuvent servir de moteur CPU.
    static func isMLX(_ ollamaModel: String) -> Bool { ollamaModel.lowercased().contains("mlx") }

    /// « moteur|modèle » du Gemma installé pour un backend (après téléchargement), nil sinon.
    static func gemmaKey(backend: String, ollama: [String], lmStudio: [String]) -> String? {
        if backend == "ollama" {
            return ollama.first { $0.lowercased().contains("gemma") }.map(ollamaKey)
        }
        return lmStudio.first { $0.lowercased().contains("gemma") }.map { "lmstudio|\($0)" }
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

    private static func callLMStudio(model: String, system: String, user: String, token: CancelToken?) -> String? {
        let body: [String: Any] = [
            "model": model,
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

    /// Options Ollama d'un modèle, les MÊMES à chaque appel (préchauffage compris : une valeur
    /// différente oblige Ollama à recharger le modèle). Moteur CPU → `num_gpu: 0` : le GPU est
    /// souvent saturé par d'autres processus (génération d'images…) et la retouche y devient plus
    /// lente que sur CPU. Contexte 8 192 : large pour une dictée ou une sélection ⌘R, là où le
    /// défaut d'Ollama (131 072) double la mémoire occupée par le modèle.
    private static func ollamaOptions(cpu: Bool) -> [String: Any] {
        cpu ? ["temperature": 0.2, "num_gpu": 0, "num_ctx": 8192] : ["temperature": 0.2, "num_ctx": 8192]
    }

    private static func callOllama(model: String, cpu: Bool, system: String, user: String,
                                   token: CancelToken?) -> String? {
        // `system` à part (et PAS concaténé au prompt) : c'est ce qui empêche le modèle de
        // confondre les consignes avec le texte à traiter — et de recracher le contexte.
        let body: [String: Any] = [
            "model": model,
            "system": system,
            "prompt": "Texte :\n\(user)",
            "stream": false,
            // Sans ça, les modèles qui « réfléchissent » (qwen3.5…) y passent tout leur budget :
            // qwen3.5:2b sur CPU → 185 s et réponse VIDE. Ignoré par les autres (gemma3).
            "think": false,
            "keep_alive": "30s",
            "options": ollamaOptions(cpu: cpu),
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
        if token?.cancelled == true || token?.reformSkipped == true { return nil }
        task.resume()
        _ = sem.wait(timeout: .now() + 65)
        return out
    }

    /// Mesure le temps de réponse d'un moteur sur un petit prompt. nil si indisponible.
    static func benchmark(_ engine: Engine) -> Double? {
        let sys = "Tu corriges un texte dicté. Réponds uniquement avec le texte corrigé, sans commentaire."
        let user = "voici une petite phrase de test pour mesurer la vitesse du modèle"
        let url: URL
        let body: [String: Any]
        let extract: ([String: Any]) -> String?
        switch engine {
        case .lmStudio(let model):
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
        case .ollama(let model, let cpu):
            url = Config.ollamaURL
            body = ["model": model, "system": sys, "prompt": "Texte :\n" + user, "stream": false,
                    "think": false, "keep_alive": "30s", "options": ollamaOptions(cpu: cpu)]
            extract = { json in json["response"] as? String }
        case .ollamaCloud(let model):
            url = Config.ollamaURL
            body = ["model": model, "system": sys, "prompt": "Texte :\n" + user, "stream": false,
                    "think": false, "options": ollamaOptions(cpu: false)]
            extract = { json in json["response"] as? String }
        }
        let start = Date()
        let result = syncPost(url, body, nil, extract: extract)
        return result == nil ? nil : Date().timeIntervalSince(start)
    }

    /// Précharge le(s) modèle(s) (au démarrage d'enregistrement) pour qu'ils soient prêts à
    /// l'arrêt. Mode auto : les DEUX, le choix GPU/CPU ne se faisant qu'à l'arrêt.
    static func warmUp() {
        guard Config.reformMode != .off else { return }
        // Les deux premiers moteurs de la liste : le premier sert, le second est le repli.
        for engine in Config.engineOrder.prefix(2).compactMap(Engine.init(key:)) {
            switch engine {
            case .lmStudio(let model):
                fire(Config.lmstudioURL, ["model": model, "messages": [["role": "user", "content": "hi"]],
                                          "max_tokens": 1, "stream": false])
            case .ollama(let model, let cpu):
                fire(Config.ollamaURL, ["model": model, "prompt": "", "stream": false,
                                        "keep_alive": "30s", "options": ollamaOptions(cpu: cpu)])
            case .ollamaCloud:
                break // rien à charger en local, et un préchauffage compterait comme une requête cloud
            }
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
