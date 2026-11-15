import ConceptBadges
import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import TelegramCore
import TelegramUIPreferences
import PresentationDataUtils
import ConceptSettings

private final class ConceptSettingsObservation {
    var token: NSObjectProtocol?
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

private final class ConceptSettingsControllerArguments {
    let switchHideAllSecretsOnManualAppLock: (Bool) -> Void
    let switchHideAllSecretsOnDeviceShake: (Bool) -> Void
    let openSecretPasscodes: () -> Void
    let openGhostMode: () -> Void
    let openMiscSettings: () -> Void
    let openDeviceSpoofing: () -> Void
    let openAntiDelete: () -> Void
    let openTextReplacement: () -> Void
    let toggleBadges: (Bool) -> Void
    let toggleWallpapers: (Bool) -> Void
    let toggleBlockedUsers: (Bool) -> Void
    let openNotifications: () -> Void

    init(
        switchHideAllSecretsOnManualAppLock: @escaping (Bool) -> Void,
        switchHideAllSecretsOnDeviceShake: @escaping (Bool) -> Void,
        openSecretPasscodes: @escaping () -> Void,
        openGhostMode: @escaping () -> Void,
        openMiscSettings: @escaping () -> Void,
        openDeviceSpoofing: @escaping () -> Void,
        openAntiDelete: @escaping () -> Void,
        openTextReplacement: @escaping () -> Void,
        toggleBadges: @escaping (Bool) -> Void,
        toggleWallpapers: @escaping (Bool) -> Void,
        toggleBlockedUsers: @escaping (Bool) -> Void,
        openNotifications: @escaping () -> Void
    ) {
        self.switchHideAllSecretsOnManualAppLock = switchHideAllSecretsOnManualAppLock
        self.switchHideAllSecretsOnDeviceShake = switchHideAllSecretsOnDeviceShake
        self.openSecretPasscodes = openSecretPasscodes
        self.openGhostMode = openGhostMode
        self.openMiscSettings = openMiscSettings
        self.openDeviceSpoofing = openDeviceSpoofing
        self.openAntiDelete = openAntiDelete
        self.openTextReplacement = openTextReplacement
        self.toggleBadges = toggleBadges
        self.toggleWallpapers = toggleWallpapers
        self.toggleBlockedUsers = toggleBlockedUsers
        self.openNotifications = openNotifications
    }
}

private enum ConceptSettingsSection: Int32 {
    case hideAllSecrets
    case privacy
}

private enum ConceptSettingsEntry: ItemListNodeEntry {
    case hideAllSecretsHeader(String)
    case hideAllSecretsOnManualAppLock(String, Bool)
    case hideAllSecretsOnDeviceShake(String, Bool)
    case hideAllSecretsOnDeviceShakeInfo(String)
    case privacyHeader(String)
    case antiDeleteSettings(PresentationTheme, String, String)
    case ghostMode(PresentationTheme, String, String)
    case miscSettings(PresentationTheme, String, String)
    case deviceSpoofing(PresentationTheme, String, String)
    case textReplacement(PresentationTheme, String)
    case badges(PresentationTheme, String, Bool)
    case disableWallpapers(PresentationTheme, String, Bool)
    case hideBlockedUsers(PresentationTheme, String, Bool)
    case notifications(PresentationTheme, String)

    var section: ItemListSectionId {
        switch self {
        case .hideAllSecretsHeader, .hideAllSecretsOnManualAppLock, .hideAllSecretsOnDeviceShake, .hideAllSecretsOnDeviceShakeInfo:
            return ConceptSettingsSection.hideAllSecrets.rawValue
        case .privacyHeader, .antiDeleteSettings, .ghostMode, .miscSettings, .deviceSpoofing, .notifications, .textReplacement, .disableWallpapers, .badges, .hideBlockedUsers:
            return ConceptSettingsSection.privacy.rawValue
        }
    }

    var stableId: Int32 {
        switch self {
        case .hideAllSecretsHeader:
            return 0
        case .hideAllSecretsOnManualAppLock:
            return 1
        case .hideAllSecretsOnDeviceShake:
            return 2
        case .hideAllSecretsOnDeviceShakeInfo:
            return 3
        case .privacyHeader:
            return 4
        case .antiDeleteSettings:
            return 5
        case .ghostMode:
            return 6
        case .miscSettings:
            return 7
        case .deviceSpoofing:
            return 8
        case .badges: return 12
        case .hideBlockedUsers: return 13
        case .textReplacement: return 10
        case .disableWallpapers: return 11
        case .notifications:
            return 9
        }
    }

    static func ==(lhs: ConceptSettingsEntry, rhs: ConceptSettingsEntry) -> Bool {
        switch lhs {
        case let .hideAllSecretsHeader(text):
            if case .hideAllSecretsHeader(text) = rhs { return true }
            return false
        case let .hideAllSecretsOnManualAppLock(text, value):
            if case .hideAllSecretsOnManualAppLock(text, value) = rhs { return true }
            return false
        case let .hideAllSecretsOnDeviceShake(text, value):
            if case .hideAllSecretsOnDeviceShake(text, value) = rhs { return true }
            return false
        case let .hideAllSecretsOnDeviceShakeInfo(text):
            if case .hideAllSecretsOnDeviceShakeInfo(text) = rhs { return true }
            return false
        case let .privacyHeader(text):
            if case .privacyHeader(text) = rhs { return true }
            return false
        case let .antiDeleteSettings(theme, text, value):
            if case .antiDeleteSettings(theme, text, value) = rhs { return true }
            return false
        case let .ghostMode(theme, text, value):
            if case .ghostMode(theme, text, value) = rhs { return true }
            return false
        case let .miscSettings(theme, text, value):
            if case .miscSettings(theme, text, value) = rhs { return true }
            return false
        case let .textReplacement(theme, text):
            if case .textReplacement(theme, text) = rhs { return true }; return false
        case let .hideBlockedUsers(theme, text, value):
            if case .hideBlockedUsers(theme, text, value) = rhs { return true }; return false
        case let .badges(theme, text, value):
            if case .badges(theme, text, value) = rhs { return true }; return false
        case let .disableWallpapers(theme, text, value):
            if case .disableWallpapers(theme, text, value) = rhs { return true }; return false
        case let .notifications(theme, text):
            if case .notifications(theme, text) = rhs { return true }
            return false
        case let .deviceSpoofing(theme, text, value):
            if case .deviceSpoofing(theme, text, value) = rhs { return true }
            return false
        }
    }

    static func <(lhs: ConceptSettingsEntry, rhs: ConceptSettingsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ConceptSettingsControllerArguments
        switch self {
        case let .hideAllSecretsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .hideAllSecretsOnManualAppLock(title, value):
            return ItemListSwitchItem(presentationData: presentationData,systemStyle: .glass, title: title, value: value, enabled: true, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.switchHideAllSecretsOnManualAppLock(updatedValue)
            })
        case let .hideAllSecretsOnDeviceShake(title, value):
            return ItemListSwitchItem(presentationData: presentationData,systemStyle: .glass, title: title, value: value, enabled: true, sectionId: self.section, style: .blocks, updated: { updatedValue in
                arguments.switchHideAllSecretsOnDeviceShake(updatedValue)
            })
        case let .hideAllSecretsOnDeviceShakeInfo(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .privacyHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .antiDeleteSettings(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openAntiDelete()
            })
        case let .ghostMode(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openGhostMode()
            })
        case let .miscSettings(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openMiscSettings()
            })
        case let .textReplacement(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: self.section, style: .blocks, action: arguments.openTextReplacement)
        case let .hideBlockedUsers(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: arguments.toggleBlockedUsers)
        case let .badges(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: arguments.toggleBadges)
        case let .disableWallpapers(_, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: arguments.toggleWallpapers)
        case let .notifications(_, title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: self.section, style: .blocks, action: {
                arguments.openNotifications()
            })
        case let .deviceSpoofing(_, title, value):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.openDeviceSpoofing()
            })
        }
    }
}

private struct ConceptSettingsState: Equatable {
    let settings: ConceptSettings
    let version: Int

    func withUpdatedSettings(_ settings: ConceptSettings) -> ConceptSettingsState {
        return ConceptSettingsState(settings: settings, version: self.version + 1)
    }
}

private func conceptSettingsControllerEntries(presentationData: PresentationData, settings: ConceptSettings) -> [ConceptSettingsEntry] {
    var entries: [ConceptSettingsEntry] = []

    entries.append(.hideAllSecretsHeader("DOUBLE BOTTOM"))
    entries.append(.hideAllSecretsOnManualAppLock("Hide on Manual App Lock", settings.hideAllSecretsOnManualAppLock))
    entries.append(.hideAllSecretsOnDeviceShake("Hide on Device Shake", settings.hideAllSecretsOnDeviceShake))
    entries.append(.hideAllSecretsOnDeviceShakeInfo("Instantly hide all secret accounts by shaking the device or manually locking the app."))

    entries.append(.privacyHeader("PRIVACY"))
    let antiDeleteStatus = AntiDeleteManager.shared.isEnabled ? "On" : "Off"
    entries.append(.antiDeleteSettings(presentationData.theme, "Anti-Delete", antiDeleteStatus))
    let ghostModeStatus = GhostModeManager.shared.isEnabled ? "On" : "Off"
    entries.append(.ghostMode(presentationData.theme, "Ghost Mode", ghostModeStatus))
    let miscStatus = MiscSettingsManager.shared.isEnabled ? "On" : "Off"
    entries.append(.miscSettings(presentationData.theme, "Advanced Privacy", miscStatus))
    let deviceSpoofStatus = DeviceSpoofManager.shared.isEnabled ? "On" : "Off"
    entries.append(.deviceSpoofing(presentationData.theme, "Device Spoofing", deviceSpoofStatus))
    entries.append(.notifications(presentationData.theme, presentationData.strings.baseLanguageCode.hasPrefix("ru") ? "Уведомления" : "Notifications"))

    let ru = presentationData.strings.baseLanguageCode.hasPrefix("ru")
    entries.append(.hideBlockedUsers(presentationData.theme, ru ? "Скрывать сообщения заблокированных" : "Hide Blocked Users’ Messages", ConceptMessageFilterSettings.hideBlockedUsers))
    entries.append(.textReplacement(presentationData.theme, ru ? "Замены при отправке" : "Text Replacement"))
    entries.append(.disableWallpapers(presentationData.theme, ru ? "Отключить обои отдельных чатов" : "Disable Per-Chat Wallpapers", ConceptAppearanceSettings.disablePerChatWallpaper))
    entries.append(.badges(presentationData.theme, ru ? "Значки Concept рядом с именами" : "Concept Name Badges", ConceptBadgeService.isEnabled))
    return entries
}

public func conceptSettingsController(context: AccountContext) -> ViewController {
    let initialState = ConceptSettingsState(settings: context.sharedContext.currentConceptSettings.with { $0 }, version: 0)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)

    var version = 0
    var pushControllerImpl: ((ViewController) -> Void)?

    let arguments = ConceptSettingsControllerArguments(
        switchHideAllSecretsOnManualAppLock: { value in
            let _ = updateConceptSettings(context.sharedContext.accountManager, { settings in
                return settings.withUpdated(hideAllSecretsOnManualAppLock: value)
            }).start()
        },
        switchHideAllSecretsOnDeviceShake: { value in
            let _ = updateConceptSettings(context.sharedContext.accountManager, { settings in
                return settings.withUpdated(hideAllSecretsOnDeviceShake: value)
            }).start()
        },
        openSecretPasscodes: {
            pushControllerImpl?(conceptSecretPasscodeSetupController(context: context, passcode: nil))
        },
        openGhostMode: {
            pushControllerImpl?(ghostModeController(context: context))
        },
        openMiscSettings: {
            pushControllerImpl?(miscController(context: context))
        },
        openDeviceSpoofing: {
            pushControllerImpl?(deviceSpoofController(context: context))
        },
        openAntiDelete: {
            pushControllerImpl?(deletedMessagesController(context: context))
        },
        openTextReplacement: { pushControllerImpl?(conceptTextReplacementController(context: context)) },
        toggleBadges: { value in
            ConceptBadgeService.isEnabled = value
            version += 1
            statePromise.set(ConceptSettingsState(settings: context.sharedContext.currentConceptSettings.with { $0 }, version: version))
        },
        toggleWallpapers: { value in
            ConceptAppearanceSettings.disablePerChatWallpaper = value
            version += 1
            statePromise.set(ConceptSettingsState(settings: context.sharedContext.currentConceptSettings.with { $0 }, version: version))
        },
        toggleBlockedUsers: { value in
            ConceptMessageFilterSettings.hideBlockedUsers = value
        },
        openNotifications: {
            pushControllerImpl?(conceptNotificationsController(context: context))
        }
    )

    let signal: Signal<(ItemListControllerState, (ItemListNodeState, ConceptSettingsControllerArguments)), NoError> = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    ) |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, ConceptSettingsControllerArguments)) in
        let entries = conceptSettingsControllerEntries(presentationData: presentationData, settings: state.settings)

        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Concept"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)

        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    pushControllerImpl = { [weak controller] c in
        controller?.push(c)
    }

    let observation = ConceptSettingsObservation()
    observation.token = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: .main) { [weak controller] notification in
        guard controller != nil else { return }
        let names: [Notification.Name] = [
            GhostModeManager.settingsChangedNotification,
            MiscSettingsManager.settingsChangedNotification,
            DeviceSpoofManager.settingsChangedNotification,
            ConceptAppearanceSettings.changed,
            ConceptMessageFilterSettings.changed,
            ConceptTextReplacement.settingsChanged,
            ConceptBadgeService.changed
        ]
        if names.contains(notification.name) {
            version += 1
            let current = context.sharedContext.currentConceptSettings.with { $0 }
            statePromise.set(ConceptSettingsState(settings: current, version: version))
        }
    }

    controller.didAppear = { [observation] _ in
        _ = observation
        version += 1
        statePromise.set(ConceptSettingsState(settings: context.sharedContext.currentConceptSettings.with { $0 }, version: version))
    }

    return controller
}
