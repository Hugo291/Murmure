import Foundation

/// Coupe le son des appareils Cast ACTIVÉS dans le menu quand on dicte, puis le rétablit — uniquement
/// ceux dont c'est nous qui avons coupé le son. Marche quelle que soit l'appli (Netflix ne publie pas
/// son état de lecture, une pause serait impossible). Par défaut AUCUN appareil n'est activé.
/// Tout passe par une file série en arrière-plan : jamais de blocage, coupure/rétablissement ne se croisent pas.
enum TVControl {
    static let refreshInterval: TimeInterval = 300
    private static let queue = DispatchQueue(label: "murmure.tv", qos: .utility)
    private static var mutedByUs = Set<String>()   // IP ; accès uniquement depuis `queue`
    // Cache consulté et mis à jour sur le thread principal.
    private static var cachedStates: [String: (state: ConnectedDevice.State, checkedAt: Date)] = [:]

    private static func catt(_ ip: String, _ args: [String]) -> String? {
        ConnectedDevices.catt(["-d", ip] + args, timeout: 4)
    }

    /// Vérifie uniquement les appareils sélectionnés, au lancement puis toutes les 5 minutes.
    static func refreshAvailability(completion: @escaping ([String: ConnectedDevice.State]) -> Void) {
        let ips = Config.pausedDevices
        queue.async {
            var states: [String: ConnectedDevice.State] = [:]
            for ip in ips {
                // Le tout premier appel après le lancement de l'app échoue souvent : une seconde chance.
                let state = ConnectedDevices.state(ip: ip)
                states[ip] = state == .offline ? ConnectedDevices.state(ip: ip) : state
            }
            DispatchQueue.main.async {
                cachedStates = cachedStates.filter { ips.contains($0.key) }
                for (ip, state) in states { cachedStates[ip] = (state, Date()) }
                completion(states)
            }
        }
    }

    /// Un appareil vu injoignable récemment ne fait pas attendre l'enregistrement (son délai serait subi).
    /// Il est quand même tenté en arrière-plan : le relevé au lancement de l'app échoue souvent.
    private static func shouldCheck(_ ip: String) -> Bool {
        guard let cached = cachedStates[ip], Date().timeIntervalSince(cached.checkedAt) < refreshInterval else { return true }
        return cached.state != .offline
    }

    static var needsMute: Bool { Config.pausedDevices.contains(where: shouldCheck) }

    /// Début de dictée : coupe le son des appareils activés (sauf s'il l'était déjà). `completion` est appelé
    /// sur le thread principal UNE FOIS le son coupé (ou après `timeout` si un appareil ne répond pas),
    /// pour que l'enregistrement ne démarre qu'après.
    static func mute(timeout: TimeInterval = 4, completion: @escaping () -> Void = {}) {
        let all = Config.pausedDevices
        let awaited = all.filter(shouldCheck)
        var finished = false // accès main uniquement
        let finish = { if !finished { finished = true; completion() } }
        if awaited.isEmpty { finish() } else { DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: finish) }
        queue.async {
            awaited.forEach(muteOne)
            DispatchQueue.main.async(execute: finish)
            all.filter { !awaited.contains($0) }.forEach(muteOne)
        }
    }

    private static func muteOne(_ ip: String) {
        guard !mutedByUs.contains(ip),
              catt(ip, ["info"])?.contains("volume_muted: False") == true,
              catt(ip, ["volumemute", "true"]) != nil else { return }
        mutedByUs.insert(ip)
    }

    /// Fin de dictée : rétablit le son de ceux que NOUS avons coupés.
    static func unmute() {
        queue.async {
            for ip in mutedByUs { _ = catt(ip, ["volumemute", "false"]) }
            mutedByUs.removeAll()
        }
    }
}
