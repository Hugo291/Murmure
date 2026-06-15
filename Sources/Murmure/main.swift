import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular) // vraie app : icône Dock, ⌘-Tab, plein écran (+ icône barre de menus)
app.run()
