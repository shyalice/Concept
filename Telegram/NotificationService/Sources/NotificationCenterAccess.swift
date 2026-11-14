import Foundation
import SwiftSignalKit
import UserNotifications

func notificationDeliveredNotifications(request: NotificationRequestWork, queue: Queue, completionHandler: @escaping ([UNNotification]) -> Void) {
    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
        queue.async {
            guard !request.isCancelled else { return }
            completionHandler(notifications)
        }
    }
}
