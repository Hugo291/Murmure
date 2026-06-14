import AppKit
import CoreAudio

/// Coupe le son de sortie du système pendant l'enregistrement (façon Typeless),
/// puis le rétablit à l'état EXACT d'avant. Robuste au crash : l'état est persisté,
/// donc un mute laissé actif par un plantage est rétabli au prochain lancement.
final class SystemAudio {
    static let shared = SystemAudio()
    private init() {}

    private let activeKey = "muteActive"
    private let prevKey = "mutePrevMuted"

    private(set) var active = false
    private var previousMuted = false

    /// Coupe le son si l'option est activée, qu'on ne l'a pas déjà coupé,
    /// et qu'un son joue effectivement (façon Wispr Flow → évite un mute inutile/bloqué).
    func mute() {
        guard Config.muteWhileRecording, !active else { return }
        guard isOutputActive() else { return }
        previousMuted = readMuted()
        active = true
        // Persiste pour pouvoir restaurer même après un crash.
        UserDefaults.standard.set(true, forKey: activeKey)
        UserDefaults.standard.set(previousMuted, forKey: prevKey)
        setMuted(true)
    }

    /// Rétablit l'état précédent si c'est nous qui avions coupé le son.
    func restore() {
        guard active else { return }
        active = false
        setMuted(previousMuted)
        UserDefaults.standard.set(false, forKey: activeKey)
    }

    /// Au lancement : si un crash nous a laissés en mute, on rétablit l'état d'avant.
    func recoverIfNeeded() {
        guard UserDefaults.standard.bool(forKey: activeKey) else { return }
        let prev = UserDefaults.standard.bool(forKey: prevKey)
        setMuted(prev)
        UserDefaults.standard.set(false, forKey: activeKey)
    }

    // MARK: - AppleScript (StandardAdditions : aucune permission requise)

    private func readMuted() -> Bool {
        run("output muted of (get volume settings)")?.booleanValue ?? false
    }

    private func setMuted(_ on: Bool) {
        _ = run("set volume output muted \(on ? "true" : "false")")
    }

    @discardableResult
    private func run(_ source: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let desc = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err { NSLog("Murmure: AppleScript son: \(err)") }
        return desc
    }

    // MARK: - CoreAudio : du son joue-t-il actuellement ?

    private func defaultOutputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return st == noErr ? id : nil
    }

    /// `true` si un processus diffuse du son sur la sortie par défaut. En cas de doute → `true`.
    private func isOutputActive() -> Bool {
        guard let dev = defaultOutputDevice() else { return true }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running)
        return st == noErr ? (running != 0) : true
    }
}
