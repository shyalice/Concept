import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import Postbox
import TelegramCore
import TelegramUIPreferences
import PresentationDataUtils
import ConceptSettings

private final class ConceptSettingsControllerArguments {
    let switchHideAllSecretsOnManualAppLock: (Bool) -> Void
    let switchHideAllSecretsOnDeviceShake: (Bool) -> Void
    let openSecretPasscodes: () -> Void
    let openGhostMode: () -> Void
    let openMiscSettings: () -> Void
    let openDeviceSpoofing: () -> Void
    let openAntiDelete: () -> Void
    
    init(
        switchHideAllSecretsOnManualAppLock: @escaping (Bool) -> Void,
        switchHideAllSecretsOnDeviceShake: @escaping (Bool) -> Void,
        openSecretPasscodes: @escaping () -> Void,
        openGhostMode: @escaping () -> Void,
        openMiscSettings: @escaping () -> Void,
        openDeviceSpoofing: @escaping () -> Void,
        openAntiDelete: @escaping () -> Void
    ) {
        self.switchHideAllSecretsOnManualAppLock = switchHideAllSecretsOnManualAppLock
        self.switchHideAllSecretsOnDeviceShake = switchHideAllSecretsOnDeviceShake
        self.openSecretPasscodes = openSecretPasscodes
        self.openGhostMode = openGhostMode
        self.openMiscSettings = openMiscSettings
        self.openDeviceSpoofing = openDeviceSpoofing
        self.openAntiDelete = openAntiDelete
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
    
    var section: ItemListSectionId {
        switch self {
        case .hideAllSecretsHeader, .hideAllSecretsOnManualAppLock, .hideAllSecretsOnDeviceShake, .hideAllSecretsOnDeviceShakeInfo:
            return ConceptSettingsSection.hideAllSecrets.rawValue
        case .privacyHeader, .antiDeleteSettings, .ghostMode, .miscSettings, .deviceSpoofing:
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
    
    return entries
}

public func conceptSettingsController(context: AccountContext) -> ViewController {
    let initialState = ConceptSettingsState(settings: context.sharedContext.currentConceptSettings.with { $0 }, version: 0)
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    
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
    
    var version = 0
    let observer = NotificationCenter.default.addObserver(forName: nil, object: nil, queue: .main) { [weak controller] notification in
        guard controller != nil else { return }
        let names: [Notification.Name] = [
            GhostModeManager.settingsChangedNotification,
            MiscSettingsManager.settingsChangedNotification,
            DeviceSpoofManager.settingsChangedNotification
        ]
        if names.contains(notification.name) {
            version += 1
            let current = context.sharedContext.currentConceptSettings.with { $0 }
            statePromise.set(ConceptSettingsState(settings: current, version: version))
        }
    }
    
    controller.didDisappear = { [weak observer] _ in
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    return controller
}
