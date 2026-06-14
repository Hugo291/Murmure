import AppKit

/// Une dictée = un job indépendant : sa pastille, sa destination mémorisée, son jeton
/// d'annulation et son fichier audio. Plusieurs jobs peuvent « réfléchir » en parallèle
/// (un seul enregistre à la fois — il n'y a qu'un micro).
final class DictationJob {
    let number: Int                  // 1, 2, 3… (annotation affichée si > 1)
    let token = CancelToken()
    let target = InsertionTarget()
    let marker = MicMarker()
    var wav: URL?
    var anchor: CGPoint = .zero    // dernière position écran de la pastille
    var offsetX: CGFloat = 0       // décalage horizontal si elle chevauchait une autre pastille
    var readyText: String?         // texte final prêt, en attente de livraison dans l'ordre de démarrage

    init(number: Int) { self.number = number }
}
