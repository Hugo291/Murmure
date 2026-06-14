import AppKit
import IOKit.hid
import Speech

/// Helpers pour vérifier/demander les autorisations système et ouvrir les bons réglages.
enum Permissions {
    /// Accessibilité : nécessaire pour envoyer ⌘V (coller au curseur).
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func promptAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Surveillance des saisies : nécessaire pour lire la touche Fn globalement.
    static var inputMonitoringGranted: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    static func promptInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    /// Reconnaissance vocale : pour l'aperçu de transcription en temps réel (on-device).
    static var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func openSpeechSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }

    private static func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }
}
