import SGAppGroupIdentifier
import Foundation
import UserNotifications
import SwiftSignalKit

private let notificationProcessingQueue = Queue(name: "Concept-NotificationProcessing")

/// Rendering happens on the processing queue. Expiry only hands an immutable
/// content snapshot to iOS; it never decodes images, reads the database or donates
/// an interaction while the system is already terminating the extension.
private struct NotificationDeliveryContent {
    let content: UNNotificationContent
    let didDeliver: () -> Void

    static func original(_ content: UNNotificationContent) -> NotificationDeliveryContent {
        return NotificationDeliveryContent(content: (content.copy() as? UNNotificationContent) ?? content, didDeliver: {})
    }

    static func resolved(_ content: NotificationContent) -> NotificationDeliveryContent {
        let rendered = content.generate()
        let snapshot = (rendered.copy() as? UNNotificationContent) ?? rendered
        return NotificationDeliveryContent(content: snapshot, didDeliver: { content.donateInteraction() })
    }
}

@objc(NotificationService)
final class NotificationService: UNNotificationServiceExtension {
    private let requests = NotificationRequestRegistry<NotificationDeliveryContent>()
    // Accessed only on notificationProcessingQueue.
    private var processors: [UUID: NotificationServiceHandler] = [:]

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let id = UUID()
        let budget = NotificationExecutionBudget()
        let queue = notificationProcessingQueue
        let completion = NotificationRequestCompletion<NotificationDeliveryContent>(initial: .original(request.content), handler: { [weak self] snapshot in
            self?.requests.remove(id: id)
            contentHandler(snapshot.content)
            if snapshot.content.threadIdentifier == "empty-notification" {
                self?.removeEmptyNotifications(requestIdentifier: request.identifier)
            }
            queue.async { [weak self] in
                self?.processors.removeValue(forKey: id)
                snapshot.didDeliver()
            }
        })
        self.requests.insert(completion, id: id)

        // Independent of the processing queue: a contended database or expensive
        // decoder cannot keep the original system handler open indefinitely.
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + budget.remaining())
        watchdog.setEventHandler { [weak completion] in completion?.finish(reason: .deadline) }
        completion.work.addCancellation { watchdog.cancel() }
        watchdog.resume()

        self.removeEmptyNotifications(requestIdentifier: nil, attemptsRemaining: 0)
        queue.async { [weak self] in
            guard let self, completion.isPending else { return }
            groupUserDefaults?.set(Date().timeIntervalSince1970, forKey: "Concept.PushDiagnostics.LastServiceRequest")
            let processor = NotificationServiceHandler(
                queue: queue,
                episode: id.uuidString,
                requestWork: completion.work,
                budget: budget,
                updateCurrentContent: { content in
                    guard completion.isPending else { return }
                    completion.update(.resolved(content))
                },
                completed: { completion.finish() },
                requestIdentifier: request.identifier,
                payload: request.content.userInfo
            )
            if let processor, completion.isPending {
                self.processors[id] = processor
            } else if processor == nil {
                completion.finish()
            }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        let requests = self.requests.takeAll()
        for request in requests { request.finish(reason: .systemExpiry) }
    }

    private func removeEmptyNotifications(requestIdentifier: String?, attemptsRemaining: Int = 5) {
        guard sgLegacyNotificationsFix else { return }
        UNUserNotificationCenter.current().getDeliveredNotifications { [weak self] notifications in
            let identifiers = notifications.compactMap { notification -> String? in
                guard notification.request.content.threadIdentifier == "empty-notification",
                      requestIdentifier == nil || notification.request.identifier == requestIdentifier else { return nil }
                return notification.request.identifier
            }
            if !identifiers.isEmpty {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
            }
            // Seeing a stale placeholder must not stop retries for this request.
            if attemptsRemaining > 0 {
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.removeEmptyNotifications(requestIdentifier: requestIdentifier, attemptsRemaining: attemptsRemaining - 1)
                }
            }
        }
    }

    deinit {
        for request in self.requests.takeAll() { request.finish(reason: .systemExpiry) }
    }
}
