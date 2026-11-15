import Foundation
import SwiftSignalKit

public enum ConceptMessageFilterSettings {
    public static let changed = Notification.Name("Concept.MessageFilterChanged")
    public static var hideBlockedUsers: Bool {
        get { ConceptSettingsStorage.shared.defaults.bool(forKey: "MiscSettings.hideBlockedUsers") }
        set {
            ConceptSettingsStorage.shared.defaults.set(newValue, forKey: "MiscSettings.hideBlockedUsers")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    public static var hideBlockedUsersSignal: Signal<Bool, NoError> {
        return Signal { subscriber in
            let observer = NotificationCenter.default.addObserver(forName: changed, object: nil, queue: .main) { _ in subscriber.putNext(hideBlockedUsers) }
            subscriber.putNext(hideBlockedUsers)
            return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
        } |> distinctUntilChanged
    }
}
