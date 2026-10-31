import Foundation

/// Objets connectés (appareils Google Cast : télé, enceintes) vus par `catt`, avec leur état.
/// Tout est bloquant → à appeler hors du thread principal.
struct ConnectedDevice: Equatable {
    enum State: Equatable { case playing(String), paused(String), idle, offline }
    let name: String
    let ip: String
    var state: State

    var usable: Bool { state != .offline }
}

enum ConnectedDevices {
    private static let uvx = NSHomeDirectory() + "/.local/bin/uvx"
    /// Appareils connus (nom + IP) : le scan réseau dure ~5 s, on ne le refait que de temps en temps.
    private static var known: [(name: String, ip: String)] = []
    private static var lastScan = Date.distantPast

    /// Lance `uvx catt …` avec un délai max ; renvoie la sortie, ou nil en cas d'échec/délai dépassé.
    static func catt(_ args: [String], timeout: TimeInterval) -> String? {
        guard FileManager.default.isExecutableFile(atPath: uvx) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uvx)
        p.arguments = ["catt"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return nil }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func scan() {
        guard let txt = catt(["scan"], timeout: 15) else { return }
        // Lignes « 192.168.1.17 - Tv Chambre - Changhong AI PONT »
        let found: [(String, String)] = txt.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2, parts[0].split(separator: ".").count == 4 else { return nil }
            return (parts[1].trimmingCharacters(in: .whitespaces), parts[0].trimmingCharacters(in: .whitespaces))
        }
        if !found.isEmpty { known = found; lastScan = Date() }
    }

    private static func field(_ info: String, _ key: String) -> String? {
        for l in info.split(separator: "\n") where l.hasPrefix(key + ":") {
            return l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    static func state(ip: String) -> ConnectedDevice.State {
        guard let info = catt(["-d", ip, "info"], timeout: 8) else { return .offline }
        if info.contains("Error") && !info.contains("player_state") {
            // « Chromecast is inactive » : l'appareil répond, rien ne joue.
            return info.lowercased().contains("inactive") ? .idle : .offline
        }
        let app = field(info, "display_name").flatMap { $0 == "None" ? nil : $0 } ?? ""
        switch field(info, "player_state") ?? "" {
        case "PLAYING", "BUFFERING": return .playing(app)
        case "PAUSED": return .paused(app)
        default: return .idle
        }
    }

    /// Liste à jour des appareils avec leur état (interrogés en parallèle).
    static func refresh() -> [ConnectedDevice] {
        if known.isEmpty || Date().timeIntervalSince(lastScan) > 600 { scan() }
        var result = [ConnectedDevice?](repeating: nil, count: known.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: known.count) { i in
            let d = ConnectedDevice(name: known[i].name, ip: known[i].ip, state: state(ip: known[i].ip))
            lock.lock(); result[i] = d; lock.unlock()
        }
        return result.compactMap { $0 }
    }
}
