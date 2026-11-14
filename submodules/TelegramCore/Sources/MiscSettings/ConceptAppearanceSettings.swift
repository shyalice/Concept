import Foundation
import SwiftSignalKit

public enum ConceptAppearanceSettings {
    public static let changed = Notification.Name("Concept.AppearanceChanged")
    public static var disablePerChatWallpaper: Bool {
        get { ConceptSettingsStorage.shared.defaults.bool(forKey: "Concept.Appearance.DisablePerChatWallpaper") }
        set {
            ConceptSettingsStorage.shared.defaults.set(newValue, forKey: "Concept.Appearance.DisablePerChatWallpaper")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
    public static var disablePerChatWallpaperSignal: Signal<Bool, NoError> {
        return Signal { subscriber in
            let observer = NotificationCenter.default.addObserver(forName: changed, object: nil, queue: .main) { _ in subscriber.putNext(disablePerChatWallpaper) }
            subscriber.putNext(disablePerChatWallpaper)
            return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
        } |> distinctUntilChanged
    }
}
