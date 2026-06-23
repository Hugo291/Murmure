import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Service de fond : agent barre de menus PUR (pas d'icône Dock, pas de ⌘-Tab).
// L'app passe temporairement en .regular tant qu'une fenêtre est ouverte (cf. AppDelegate),
// puis revient en .accessory dès qu'on la ferme — pour rester un service invisible.
app.setActivationPolicy(.accessory)
app.run()
