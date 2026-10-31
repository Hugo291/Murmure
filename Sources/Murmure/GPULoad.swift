import Foundation
import IOKit

/// Le GPU est-il pris par un AUTRE processus ? Sert au mode auto de la retouche :
/// GPU libre → modèle MLX (GPU), GPU occupé → modèle Ollama sur CPU.
///
/// Le taux global (« Device Utilization % ») ne suffit pas : l'interface seule (WindowServer,
/// apps Electron…) le fait déjà monter vers 40–50 %. On relève donc le temps GPU de CHAQUE
/// processus client (compteurs `accumulatedGPUTime` sous l'IOAccelerator) entre deux instants,
/// en ignorant WindowServer et Murmure : occupé si l'un des autres en prend ≥ `busyShare`.
///
/// Fenêtre de mesure = l'enregistrement (début → arrêt), donc AVANT Whisper, qui occupe
/// lui-même le GPU pendant la transcription.
enum GPULoad {
    /// Part du temps GPU au-delà de laquelle un processus « occupe » le GPU. Les gros travaux
    /// (génération d'image, LLM MLX) dépassent 45 % ; l'interface de Claude plafonne vers 25 %.
    static let busyShare = 0.35

    private typealias Snapshot = (time: UInt64, usage: [Int32: (name: String, gpuNs: UInt64)])

    private static let lock = NSLock()
    private static var windowStart: Snapshot?
    private static var verdict: Bool?

    /// Début d'enregistrement : ouvre la fenêtre de mesure.
    static func beginWindow() {
        let s = snapshot()
        lock.lock(); windowStart = s; verdict = nil; lock.unlock()
    }

    /// Arrêt d'enregistrement (AVANT Whisper) : fige le verdict. Fenêtre < 0,3 s → pas de
    /// verdict, la retouche mesurera à la demande.
    static func endWindow() {
        lock.lock(); let s0 = windowStart; windowStart = nil; lock.unlock()
        guard let s0 else { return }
        let s1 = snapshot()
        let v: Bool? = s1.time - s0.time >= 300_000_000 ? busy(from: s0, to: s1) : nil
        lock.lock(); verdict = v; lock.unlock()
    }

    /// Verdict pour la retouche en cours : celui de l'enregistrement s'il existe (consommé),
    /// sinon une mesure immédiate sur 0,3 s (ex. reformulation d'une sélection ⌘R).
    static func isBusy() -> Bool {
        lock.lock(); let v = verdict; verdict = nil; lock.unlock()
        if let v { return v }
        let s0 = snapshot()
        usleep(300_000)
        return busy(from: s0, to: snapshot())
    }

    private static func busy(from s0: Snapshot, to s1: Snapshot) -> Bool {
        let dt = Double(s1.time - s0.time)
        guard dt > 0 else { return false }
        let me = getpid()
        for (pid, u) in s1.usage where pid != me && u.name != "WindowServer" {
            let before = s0.usage[pid]?.gpuNs ?? 0   // absent au début = lancé pendant la fenêtre
            if Double(u.gpuNs &- before) / dt >= busyShare { return true }
        }
        return false
    }

    /// Temps GPU cumulé (ns) par processus. Vide hors Apple Silicon → GPU considéré libre.
    private static func snapshot() -> Snapshot {
        var usage: [Int32: (name: String, gpuNs: UInt64)] = [:]
        var accels: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &accels) == KERN_SUCCESS {
            var accel = IOIteratorNext(accels)
            while accel != 0 {
                var clients: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(accel, kIOServicePlane, &clients) == KERN_SUCCESS {
                    var c = IOIteratorNext(clients)
                    while c != 0 {
                        if let (pid, name, ns) = clientUsage(c) {
                            usage[pid] = (name, (usage[pid]?.gpuNs ?? 0) &+ ns)
                        }
                        IOObjectRelease(c)
                        c = IOIteratorNext(clients)
                    }
                    IOObjectRelease(clients)
                }
                IOObjectRelease(accel)
                accel = IOIteratorNext(accels)
            }
            IOObjectRelease(accels)
        }
        return (DispatchTime.now().uptimeNanoseconds, usage)
    }

    /// (pid, nom, temps GPU) d'un client du GPU. Créateur au format « pid 608, WindowServer ».
    private static func clientUsage(_ c: io_object_t) -> (Int32, String, UInt64)? {
        guard let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString,
                                                            kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              let appUsage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString,
                                                             kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]],
              creator.hasPrefix("pid "), let comma = creator.firstIndex(of: ","),
              let pid = Int32(creator[creator.index(creator.startIndex, offsetBy: 4)..<comma])
        else { return nil }
        let name = creator[creator.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        let ns = appUsage.reduce(UInt64(0)) { $0 &+ (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
        return (pid, name, ns)
    }
}
