import Foundation
import SwiftSignalKit

public enum BackgroundNotificationSettings {
    public static let changed = Notification.Name("Concept.BackgroundNotificationsChanged")
    public static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "Concept.BackgroundNotifications.Enabled") == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: "Concept.BackgroundNotifications.Enabled")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "Concept.BackgroundNotifications.Enabled")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    public static var enabledSignal: Signal<Bool, NoError> {
        return Signal { subscriber in
            let observer = NotificationCenter.default.addObserver(forName: changed, object: nil, queue: .main) { _ in
                subscriber.putNext(isEnabled)
            }
            subscriber.putNext(isEnabled)
            return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
        } |> distinctUntilChanged
    }

    public static var lastRun: Date? {
        let value = UserDefaults.standard.double(forKey: "Concept.BackgroundNotifications.LastRun")
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }
    public static var lastResult: Bool {
        return UserDefaults.standard.bool(forKey: "Concept.BackgroundNotifications.LastResult")
    }
    public static func record(completed: Bool) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "Concept.BackgroundNotifications.LastRun")
        UserDefaults.standard.set(completed, forKey: "Concept.BackgroundNotifications.LastResult")
    }
}
