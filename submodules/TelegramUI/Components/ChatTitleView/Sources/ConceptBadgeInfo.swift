import UIKit
import AccountContext
import ConceptBadges
import Display
import UndoUI

private enum ConceptBadgeOverlay {
    static weak var current: UndoOverlayController?
    static var peerId: String?
}

/// Uses the same bottom overlay as Telegram's save/copy confirmations.
public func presentConceptBadgeInfo(context: AccountContext, peerId: String, userName: String) {
    guard Thread.isMainThread else {
        DispatchQueue.main.async { presentConceptBadgeInfo(context: context, peerId: peerId, userName: userName) }
        return
    }
    guard let badge = ConceptBadgeService.shared.badge(peerId: peerId) else { return }
    guard let window = context.sharedContext.mainWindow else { return }
    if let current = ConceptBadgeOverlay.current {
        if ConceptBadgeOverlay.peerId == peerId { return }
        current.dismissWithCommitActionAndReplacementAnimation()
    }
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let text: String
    switch badge.role {
    case .moderator:
        text = "\(userName) is part of the Concept team. Moderator."
    case .developer:
        text = "\(userName) is part of the Concept team. Developer."
    case .supporter:
        text = "\(userName) supports Concept. Thank you for helping the project grow."
    case .member:
        text = "\(userName) is a member of the Concept community."
    }
    let icon = ConceptBadgeArt.image(badge: badge, height: 32).withTintColor(presentationData.theme.list.itemAccentColor, renderingMode: .alwaysOriginal)
    let controller = UndoOverlayController(presentationData: presentationData, content: .universalImage(image: icon, size: CGSize(width: 32.0, height: 32.0), title: "Concept badge", text: text, customUndoText: nil, timeout: 5.0), elevatedLayout: false, animateInAsReplacement: true, action: { _ in false })
    ConceptBadgeOverlay.current = controller
    ConceptBadgeOverlay.peerId = peerId
    window.presentInGlobalOverlay(controller)
}
