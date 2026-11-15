import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import ConceptNotifications

private enum BackgroundNotificationsEntry: ItemListNodeEntry {
    case toggle(PresentationTheme, String, Bool)
    case info(PresentationTheme, String)

    var stableId: Int32 { if case .toggle = self { return 0 }; return 1 }
    var section: ItemListSectionId { 0 }
    static func <(lhs: Self, rhs: Self) -> Bool { lhs.stableId < rhs.stableId }
    static func ==(lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.toggle(a, t, v), .toggle(b, u, w)): return a === b && t == u && v == w
        case let (.info(a, t), .info(b, u)): return a === b && t == u
        default: return false
        }
    }
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let enable = arguments as! (Bool) -> Void
        switch self {
        case let .toggle(_, text, enabled):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: text, value: enabled, sectionId: self.section, style: .blocks, updated: enable)
        case let .info(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

public func conceptNotificationsController(context: AccountContext) -> ViewController {
    let enabled = ValuePromise(BackgroundNotificationSettings.isEnabled, ignoreRepeated: true)
    let enable: (Bool) -> Void = { value in
        BackgroundNotificationSettings.isEnabled = value
        enabled.set(value)
        if value {
            context.sharedContext.applicationBindings.registerForNotifications { granted in
                if !granted { context.sharedContext.applicationBindings.openSettings() }
            }
        }
    }
    let signal = combineLatest(context.sharedContext.presentationData, enabled.get()) |> map { presentation, enabled -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let ru = presentation.strings.baseLanguageCode.hasPrefix("ru")
        let description = ru ? "Уведомления с аватарками и переходом в чат, пока Concept работает в фоне. Беззвучный аудиопоток поддерживает работу приложения и увеличивает расход заряда. Звонки, воспроизведение медиа и ограничения iOS могут временно приостановить доставку. После принудительного закрытия приложение нужно открыть снова." : "Notifications with avatars and direct chat navigation while Concept runs in the background. Silent audio keeps the app running and uses additional battery. Calls, media playback and iOS restrictions may temporarily suspend delivery. Reopen Concept after force quitting it. Turning this off stops the local service and silent audio; ordinary push notifications follow Telegram and iOS settings."
        let entries: [BackgroundNotificationsEntry] = [
            .toggle(presentation.theme, ru ? "Локальные уведомления" : "Local Notifications", enabled),
            .info(presentation.theme, description)
        ]
        let controller = ItemListControllerState(presentationData: ItemListPresentationData(presentation), title: .text(ru ? "Уведомления" : "Notifications"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentation.strings.Common_Back))
        return (controller, (ItemListNodeState(presentationData: ItemListPresentationData(presentation), entries: entries, style: .blocks), enable))
    }
    return ItemListController(context: context, state: signal)
}
