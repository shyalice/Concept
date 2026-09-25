import Foundation
import UIKit
import Postbox
import TelegramCore
import TelegramUIPreferences
import SwiftSignalKit
import Display
import ItemListUI
import TelegramPresentationData
import AccountContext
import SettingsUI
import PasscodeUI
import ItemListPeerActionItem
import ItemListPeerItem
import TelegramStringFormatting
import AccountUtils
import UndoUI
import TelegramIntents
import WidgetKit
import PresentationDataUtils
import AvatarNode
import Display

extension PresentationStrings {
    var SecretPasscodeSettings_Title: String { "Secret Passcode" }
    var SecretPasscode_AccountListTitle: String { "ACCOUNTS" }
    var SecretPasscode_AccountSelectionTitle: String { "Add Account" }
    var SecretPasscodeSettings_AutoHide: String { "Auto-Lock" }
    var SecretPasscodeSettings_AutoHideDesc: String { "Require passcode if away for..." }
    var SecretPasscodeSettings_AccountsHeader: String { "Hidden Accounts" }
    var SecretPasscodeSettings_AddAccount: String { "Hide Account" }
    var SecretPasscodeSettings_SecretChatsHeader: String { "Hidden Chats" }
    var SecretPasscodeSettings_AddSecretChats: String { "Hide Chat" }
    var SecretPasscodeSettings_OnRevealNavigateTo: String { "Action on reveal" }
    var SecretPasscodeSettings_OnRevealNavigateTo_None: String { "None" }
    var SecretPasscodeSettings_OnRevealNavigateToDesc: String { "Action when secret passcode is entered." }
    var SecretPasscodeSettings_ChangePasscode: String { "Change Passcode" }
    var SecretPasscodeSettings_DeleteSecretPasscode: String { "Delete Passcode" }
    var SecretPasscodeSettings_DeleteSecretPasscodeNotice: String { "Are you sure?" }
    var SecretPasscodeSettings_Intro: String { "Enter secret passcode." }
    var SecretPasscodeSettings_AtLeastOneAccountMustRemainUnhidden: String { "At least one account must remain unhidden." }
    var SecretPasscodeStatus_Revealed: String { "Revealed" }
    var SecretPasscodeStatus_Hidden: String { "Hidden" }
    var SecretPasscode_SecretChatDeleted: String { "Chat Deleted" }
    var SecretPasscode_SomeWidgetContainsChatsFromJustAddedAccount: String { "Widget contains chats from this account" }
    var SecretPasscode_SecretChatsSelectionTitle: String { "Select Chats" }
}

private final class ConceptSecretPasscodeControllerArguments {
    let changePasscode: () -> Void
    let changeTimeout: () -> Void
    let deletePasscode: () -> Void
    let addAccount: () -> Void
    let removeAccount: (AccountRecordId) -> Void
    let changeOnRevealNavigateTo: () -> Void
    
    init(
        changePasscode: @escaping () -> Void,
        changeTimeout: @escaping () -> Void,
        deletePasscode: @escaping () -> Void,
        addAccount: @escaping () -> Void,
        removeAccount: @escaping (AccountRecordId) -> Void,
        changeOnRevealNavigateTo: @escaping () -> Void
    ) {
        self.changePasscode = changePasscode
        self.changeTimeout = changeTimeout
        self.deletePasscode = deletePasscode
        self.addAccount = addAccount
        self.removeAccount = removeAccount
        self.changeOnRevealNavigateTo = changeOnRevealNavigateTo
    }
}

private enum ConceptSecretPasscodeControllerSection: Int32 {
    case state
    case timeout
    case accounts
    case secretChats
    case onRevealNavigateTo
    case changePasscode
    case delete
}

private enum ConceptSecretPasscodeControllerEntry: ItemListNodeEntry {
    case state(String)
    case timeout(String, String)
    case timeoutDesc(String)
    case accountsHeader(String)
    case accountsAdd(String)
    case account(Int32, PresentationDateTimeFormat, PresentationPersonNameOrder, AccountEntry)
    case onRevealNavigateTo(UIImage?, Bool)
    case onRevealNavigateToDesc(String)
    case changePasscode(String)
    case delete(String)
    case deleteDesc(String)
    
    var section: ItemListSectionId {
        switch self {
        case .state:
            return ConceptSecretPasscodeControllerSection.state.rawValue
        case .timeout, .timeoutDesc:
            return ConceptSecretPasscodeControllerSection.timeout.rawValue
        case .accountsHeader, .accountsAdd, .account:
            return ConceptSecretPasscodeControllerSection.accounts.rawValue
        case .onRevealNavigateTo, .onRevealNavigateToDesc:
            return ConceptSecretPasscodeControllerSection.onRevealNavigateTo.rawValue
        case .changePasscode:
            return ConceptSecretPasscodeControllerSection.changePasscode.rawValue
        case .delete, .deleteDesc:
            return ConceptSecretPasscodeControllerSection.delete.rawValue
        }
    }
    
    enum StableId: Hashable {
        case state
        case timeout
        case timeoutDesc
        case accountsHeader
        case accountsAdd
        case account(AccountRecordId)
        case onRevealNavigateTo
        case onRevealNavigateToDesc
        case changePasscode
        case delete
        case deleteDesc
    }
    
    var stableId: StableId {
        switch self {
        case .state:
            return .state
        case .timeout:
            return .timeout
        case .timeoutDesc:
            return .timeoutDesc
        case .accountsHeader:
            return .accountsHeader
        case .accountsAdd:
            return .accountsAdd
        case let .account(_, _, _, entry):
            return .account(entry.accountId)
        case .onRevealNavigateTo:
            return .onRevealNavigateTo
        case .onRevealNavigateToDesc:
            return .onRevealNavigateToDesc
        case .changePasscode:
            return .changePasscode
        case .delete:
            return .delete
        case .deleteDesc:
            return .deleteDesc
        }
    }
    
    static func <(lhs: ConceptSecretPasscodeControllerEntry, rhs: ConceptSecretPasscodeControllerEntry) -> Bool {
        if lhs.section != rhs.section {
            return lhs.section < rhs.section
        }
        
        switch lhs {
        case .timeout:
            switch rhs {
            case .timeout:
                return false
            default:
                return true
            }
        case .timeoutDesc:
            return false
        case .accountsHeader:
            switch rhs {
            case .accountsHeader:
                return false
            default:
                return true
            }
        case .accountsAdd:
            switch rhs {
            case .accountsHeader, .accountsAdd:
                return false
            case .account:
                return true
            default:
                assertionFailure()
                return false
            }
        case let .account(lhsIndex, _, _, _):
            switch rhs {
            case let .account(rhsIndex, _, _, _):
                return lhsIndex < rhsIndex
            default:
                return false
            }
        case .delete:
            switch rhs {
            case .delete:
                return false
            default:
                return true
            }
        case .deleteDesc:
            return false
        case .onRevealNavigateTo:
            switch rhs {
            case .onRevealNavigateTo:
                return false
            default:
                return true
            }
        case .onRevealNavigateToDesc:
            return false
        case .state, .changePasscode:
            return false
        }
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ConceptSecretPasscodeControllerArguments
        switch self {
        case let .state(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .timeout(title, value):
            return ItemListDisclosureItem(presentationData: presentationData,systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: {
                arguments.changeTimeout()
            })
        case let .timeoutDesc(text), let .deleteDesc(text), let .onRevealNavigateToDesc(text):
            return ItemListTextItem(presentationData: presentationData, text: .markdown(text), sectionId: self.section)
        case let .accountsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .accountsAdd(title):
            return ItemListPeerActionItem(presentationData: presentationData, systemStyle: .glass, icon: generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Add"), color: presentationData.theme.list.itemAccentColor), title: title, sectionId: self.section, action: {
                    arguments.addAccount()
                })
        case let .account(_, dateTimeFormat, nameDisplayOrder, entry):
            return ItemListPeerItem(presentationData: presentationData, systemStyle: .glass, dateTimeFormat: dateTimeFormat, nameDisplayOrder: nameDisplayOrder, context: entry._peerItemContext.context, peer: entry.peer, nameStyle: .plain, presence: nil, text: .none, label: .none, editing: ItemListPeerItemEditing(editable: true, editing: false, revealed: nil), switchValue: nil, enabled: true, selectable: false, sectionId: self.section, action: nil, setPeerIdWithRevealedOptions: { _, _ in }, removePeer: { _ in
                arguments.removeAccount(entry.accountId)
            })
        case let .changePasscode(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.changePasscode()
            })
        case let .delete(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.deletePasscode()
            })
        case let .onRevealNavigateTo(avatarImage, enabled):
            return ItemListDisclosureItem(presentationData: presentationData,systemStyle: .glass, title: presentationData.strings.SecretPasscodeSettings_OnRevealNavigateTo, enabled: enabled, label: avatarImage != nil ? "" : presentationData.strings.SecretPasscodeSettings_OnRevealNavigateTo_None, labelStyle: avatarImage != nil ? .image(image: avatarImage!, size: avatarImage!.size) : .text, sectionId: self.section, style: .blocks, action: {
                arguments.changeOnRevealNavigateTo()
            })
        }
    }
}

private struct ConceptSecretPasscodeControllerState: Equatable {
    let settings: ConceptSecretPasscode
    
    func withUpdated(settings: ConceptSecretPasscode) -> ConceptSecretPasscodeControllerState {
        return ConceptSecretPasscodeControllerState(settings: settings)
    }
}

private func secretPasscodeControllerEntries(presentationData: PresentationData, state: ConceptSecretPasscodeControllerState, accountEntries: [AccountEntry], onRevealNavigateToAvatarImage: UIImage?) -> [ConceptSecretPasscodeControllerEntry] {
    var entries: [ConceptSecretPasscodeControllerEntry] = []
    
    entries.append(.state(state.settings.active ? presentationData.strings.SecretPasscodeStatus_Revealed : presentationData.strings.SecretPasscodeStatus_Hidden))
    
    entries.append(.timeout(presentationData.strings.SecretPasscodeSettings_AutoHide, autolockStringForTimeout(strings: presentationData.strings, timeout: state.settings.timeout)))
    entries.append(.timeoutDesc(presentationData.strings.SecretPasscodeSettings_AutoHideDesc))
    
    entries.append(.accountsHeader(presentationData.strings.SecretPasscodeSettings_AccountsHeader.uppercased()))
    entries.append(.accountsAdd(presentationData.strings.SecretPasscodeSettings_AddAccount))
    
    for (index, value) in accountEntries.enumerated() {
        entries.append(.account(Int32(index), presentationData.dateTimeFormat, presentationData.nameDisplayOrder, value))
    }
    
    entries.append(.onRevealNavigateTo(onRevealNavigateToAvatarImage, !accountEntries.isEmpty))
    entries.append(.onRevealNavigateToDesc(presentationData.strings.SecretPasscodeSettings_OnRevealNavigateToDesc))
    
    entries.append(.changePasscode(presentationData.strings.SecretPasscodeSettings_ChangePasscode))
    
    entries.append(.delete(presentationData.strings.SecretPasscodeSettings_DeleteSecretPasscode))
    entries.append(.deleteDesc(presentationData.strings.SecretPasscodeSettings_DeleteSecretPasscodeNotice))
    
    return entries
}

struct EquatableAccountContext: Equatable {
    let context: AccountContext
    
    static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.context.account.id == rhs.context.account.id
    }
}

private struct AccountEntry: Equatable {
    let accountId: AccountRecordId
    let peer: EnginePeer
    let _peerItemContext: EquatableAccountContext // note that account may be hidden, use only for ItemListPeerItem
}

private struct SecretChatEntry: Equatable {
    let secretChatId: ConceptSecretChatId
    let peer: EngineRenderedPeer
    let _peerItemContext: EquatableAccountContext // note that account may be hidden, use only for ItemListPeerItem
    let accountName: String
    let lastActivityOrStatus: String
}

private func _getAccountsIncludingHiddenOnes(sharedContext: SharedAccountContext) -> Signal<[(AccountContext, EnginePeer)], NoError> {
    return combineLatest(sharedContext.activeAccountContexts, sharedContext.inactiveAccountContexts)
    |> mapToSignal { activeAccountContexts, inactiveAccounts in
        let contexts = activeAccountContexts.accounts.map({ $0.1 }) + inactiveAccounts.map({ $0.1 })
        return combineLatest(contexts.map { context in
            return context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
            |> map { peer in
                return peer.flatMap { (context, $0) }
            }
        })
        |> map { accounts in
            return accounts.compactMap { $0 }
        }
    }
}

private func getAccountEntries(sharedContext: SharedAccountContext, accountIds: Set<AccountRecordId>) -> Signal<[AccountEntry], NoError> {
    return _getAccountsIncludingHiddenOnes(sharedContext: sharedContext)
    |> map { accountsAndPeers in
        return accountsAndPeers.filter {
            return accountIds.contains($0.0.account.id)
        }
        .map {
            return AccountEntry(accountId: $0.0.account.id, peer: $0.1, _peerItemContext: EquatableAccountContext(context: $0.0))
        }
    }
}

private func getSecretChatEntries(sharedContext: SharedAccountContext, secretChats: Set<ConceptSecretChatId>, presentationData: PresentationData) -> Signal<[SecretChatEntry], NoError> {
    return .single([])
}

public func secretPasscodeController(context: AccountContext, passcode: String, isNew: Bool) -> ViewController {
    let statePromise = Promise<ConceptSecretPasscodeControllerState>()
    statePromise.set(context.sharedContext.conceptSecretPasscodes
    |> take(1)
    |> map { conceptSecretPasscodes in
        let secretPasscode = conceptSecretPasscodes.secretPasscodes.first(where: { $0.passcode == passcode })!
        return ConceptSecretPasscodeControllerState(settings: secretPasscode)
    })
    
    let updateState: (@escaping (ConceptSecretPasscodeControllerState) -> ConceptSecretPasscodeControllerState) -> Void = { f in
        let _ = (statePromise.get()
        |> take(1)).start(next: { [weak statePromise] state in
            statePromise?.set(.single(f(state)))
        })
    }
    
    var pushControllerImpl: ((ViewController) -> Void)?
    var popControllerImpl: (() -> Void)?
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments) -> Void)?
    var presentControllerInCurrentImpl: ((ViewController) -> Void)?
    
    let hapticFeedback = HapticFeedback()
    
    let arguments = ConceptSecretPasscodeControllerArguments(changePasscode: {
        let _ = (combineLatest(context.sharedContext.conceptSecretPasscodes, statePromise.get())
        |> take(1)
        |> deliverOnMainQueue).start(next: { conceptSecretPasscodes, state in
            let controller = PasscodeSetupController(context: context, mode: .secretSetup(.digits6))
            
            controller.validate = { (newPasscode: String) -> String? in
                if conceptSecretPasscodes.secretPasscodes.contains(where: { $0.passcode == newPasscode }) && newPasscode != state.settings.passcode {
                    return "Passcode in use"
                }
                
                return nil
            }
            
            controller.complete = { newPasscode, numerical in
                updateState { state in
                    let _ = updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                        return current.withUpdatedItem(passcode: state.settings.passcode) { sp in
                            return sp.withUpdated(passcode: newPasscode)
                        }
                    }).start()
                    
                    return state.withUpdated(settings: state.settings.withUpdated(passcode: newPasscode))
                }
                
                popControllerImpl?()
            }
            
            pushControllerImpl?(controller)
        })
    }, changeTimeout: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        var items: [ActionSheetItem] = []
        let setAction: (Int32?) -> Void = { value in
            updateState { state in
                let _ = updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                    return current.withUpdatedItem(passcode: state.settings.passcode) { sp in
                        return sp.withUpdated(timeout: value)
                    }
                }).start()
                
                return state.withUpdated(settings: state.settings.withUpdated(timeout: value))
            }
        }
        
        let values: [Int32] = [/*0, */10, 1 * 60, 5 * 60, 15 * 60, 1 * 60 * 60, 5 * 60 * 60]
        
        for value in values {
            var t: Int32?
            if value != 0 {
                t = value
            }
            items.append(ActionSheetButtonItem(title: autolockStringForTimeout(strings: presentationData.strings, timeout: t), color: .accent, action: { [weak actionSheet] in
                actionSheet?.dismissAnimated()
                
                setAction(t)
            }))
        }
        
        actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])])
        
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }, deletePasscode: {
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let actionSheet = ActionSheetController(presentationData: presentationData)
        
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: presentationData.strings.SecretPasscodeSettings_DeleteSecretPasscodeNotice),
                ActionSheetButtonItem(title: presentationData.strings.SecretPasscodeSettings_DeleteSecretPasscode, color: .destructive, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    
                    let _ = (statePromise.get()
                    |> take(1)).start(next: { state in
                        let _ = updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                            let updated = current.secretPasscodes.filter { $0.passcode != state.settings.passcode }
                            let updatedAllHidableAccountIds = updated.reduce(into: Set<AccountRecordId>()) { result, sp in
                                result.formUnion(sp.accountIds)
                            }
                            return ConceptSecretPasscodes(secretPasscodes: updated, dbCoveringAccounts: current.dbCoveringAccounts.filter({ updatedAllHidableAccountIds.contains($0.key) }), cacheCoveringAccounts: current.cacheCoveringAccounts.filter({ updatedAllHidableAccountIds.contains($0.key) }))
                        }).start()
                    })
                    
                    popControllerImpl?()
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        
        presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
    }, addAccount: {
        let _ = (combineLatest(activeAccountsAndPeers(context: context, includePrimary: true), Signal<Set<AccountRecordId>, NoError>.single(Set()), statePromise.get())
        |> take(1)
        |> deliverOnMainQueue).start(next: { accountsAndPeers, allHidableAccountIds, state in
            // don't need hidden accounts here
            let notIncludedAccounts = accountsAndPeers.1.filter({ (context, _, _) in
                return !allHidableAccountIds.contains(context.account.id)
            })
            let notIncludedAccountsInThisSecretPasscode = accountsAndPeers.1.filter({ (context, _, _) in
                return !state.settings.accountIds.contains(context.account.id)
            })
            if notIncludedAccountsInThisSecretPasscode.count > 1 {
                var accountSelectionCompleted: ((AccountContext) -> Void)?
                
                let accountsController = accountSelectionController(context: context, areItemsDisclosable: false, excludeAccountIds: state.settings.accountIds, accountSelected: { selectedContext in
                    accountSelectionCompleted?(selectedContext)
                })
                
                accountSelectionCompleted = { [weak accountsController] selectedContext in
                    if notIncludedAccounts.count == 1 && selectedContext.account.id == notIncludedAccounts.first?.0.account.id {
                        accountsController?.dismiss()
                        presentWarningAtLeastOneAccountMustRemainUnhidden()
                        return
                    }
                    
                    updateState { state in
                        let _ = (Signal<(db: AccountRecordId, cache: AccountRecordId)?, NoError>.single(nil)
                        |> mapToSignal { (coveringAccount: (db: AccountRecordId, cache: AccountRecordId)?) -> Signal<Void, NoError> in
                            return updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                                let updated = current.withUpdatedItem(passcode: state.settings.passcode) { sp in
                                    var usp = sp
                                        .withUpdated(accountIds: sp.accountIds.union([selectedContext.account.id]))
                                        .withUpdated(secretChats: sp.secretChats.filter({ $0.accountId != selectedContext.account.id }))
                                    if usp.onRevealNavigateTo?.accountId == selectedContext.account.id && usp.onRevealNavigateTo?.peerId != nil {
                                        usp = usp.withUpdated(onRevealNavigateTo: nil)
                                    }
                                    return usp
                                }.secretPasscodes
                                var dbCoveringAccounts = current.dbCoveringAccounts
                                var cacheCoveringAccounts = current.cacheCoveringAccounts
                                assert(coveringAccount != nil)
                                if let coveringAccount {
                                    assert(selectedContext.account.id != coveringAccount.db)
                                    dbCoveringAccounts[selectedContext.account.id] = coveringAccount.db
                                    assert(selectedContext.account.id != coveringAccount.cache)
                                    cacheCoveringAccounts[selectedContext.account.id] = coveringAccount.cache
                                }
                                return ConceptSecretPasscodes(secretPasscodes: updated, dbCoveringAccounts: dbCoveringAccounts, cacheCoveringAccounts: cacheCoveringAccounts)
                            })
                        }).start(completed: {
                            if #available(iOSApplicationExtension 14.0, iOS 14.0, *) {
                                WidgetCenter.shared.reloadAllTimelines()
                            }
                        })
                        
                        var usp = state.settings
                            .withUpdated(accountIds: state.settings.accountIds.union([selectedContext.account.id]))
                            .withUpdated(secretChats: state.settings.secretChats.filter({ $0.accountId != selectedContext.account.id }))
                        if usp.onRevealNavigateTo?.accountId == selectedContext.account.id && usp.onRevealNavigateTo?.peerId != nil {
                            usp = usp.withUpdated(onRevealNavigateTo: nil)
                        }
                        return state.withUpdated(settings: usp)
                    }
                    
                    let _ = (Signal<Void, NoError>.single(Void())).start()
                    
                    let _ = (updateIntentsSettingsInteractively(accountManager: context.sharedContext.accountManager) { current in
                        if current.account == selectedContext.account.peerId {
                            return current.withUpdatedAccount(nil)
                        } else {
                            return current
                        }
                    }).start()
                    
                    deleteAllSendMessageIntents()
                    
                    //context.sharedContext.applicationBindings.clearAllNotifications()
                    
                    // reset imported contacts that are not in contact list, it does not delete existing contacts
                    let _ = selectedContext.engine.contacts.resetSavedContacts().start()
                    
                    let _ = (areThereAnyWidgetsContainingChatsFromAccount(id: selectedContext.account.id)
                    |> deliverOnMainQueue).start(next: { result in
                        if result {
                            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                            let alert = textAlertController(context: context, title: nil, text: presentationData.strings.SecretPasscode_SomeWidgetContainsChatsFromJustAddedAccount, actions: [TextAlertAction(type: .defaultAction, title: presentationData.strings.Common_OK, action: {})])
                            presentControllerImpl?(alert, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
                        }
                    })
                    
                    accountsController?.dismiss()
                }
                
                presentControllerImpl?(accountsController, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
            } else {
                presentWarningAtLeastOneAccountMustRemainUnhidden()
            }
            
            func presentWarningAtLeastOneAccountMustRemainUnhidden() {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                presentControllerInCurrentImpl?(UndoOverlayController(presentationData: presentationData, content: .info(title: nil, text: presentationData.strings.SecretPasscodeSettings_AtLeastOneAccountMustRemainUnhidden, timeout: nil, customUndoText: nil), elevatedLayout: false, action: { _ in return false }))
                hapticFeedback.warning()
            }
        })
    }, removeAccount: { accountId in
        updateState { state in
            let _ = updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                let updated = current.withUpdatedItem(passcode: state.settings.passcode) { sp in
                    var usp = sp.withUpdated(accountIds: sp.accountIds.filter({ $0 != accountId }))
                    if usp.onRevealNavigateTo == ConceptNavigateTo(accountId: accountId, peerId: nil) {
                        usp = usp.withUpdated(onRevealNavigateTo: nil)
                    }
                    return usp
                }.secretPasscodes
                let updatedAllHidableAccountIds = updated.reduce(into: Set<AccountRecordId>()) { result, sp in
                    result.formUnion(sp.accountIds)
                }
                return ConceptSecretPasscodes(secretPasscodes: updated, dbCoveringAccounts: current.dbCoveringAccounts.filter({ updatedAllHidableAccountIds.contains($0.key) }), cacheCoveringAccounts: current.cacheCoveringAccounts.filter({ updatedAllHidableAccountIds.contains($0.key) }))
            }).start()
            
            var usp = state.settings.withUpdated(accountIds: state.settings.accountIds.filter({ $0 != accountId }))
            if usp.onRevealNavigateTo == ConceptNavigateTo(accountId: accountId, peerId: nil) {
                usp = usp.withUpdated(onRevealNavigateTo: nil)
            }
            return state.withUpdated(settings: usp)
        }
    }, changeOnRevealNavigateTo: {
        let _ = (statePromise.get()
        |> take(1)
        |> mapToSignal { state in
            return combineLatest(getAccountEntries(sharedContext: context.sharedContext, accountIds: state.settings.accountIds), getSecretChatEntries(sharedContext: context.sharedContext, secretChats: state.settings.secretChats, presentationData: context.sharedContext.currentPresentationData.with { $0 }))
            |> take(1)
        }
        |> deliverOnMainQueue).start(next: { accountEntries, secretChatEntries in
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let actionSheet = ActionSheetController(presentationData: presentationData)
            
            var itemGroups: [ActionSheetItemGroup] = []
            
            if !accountEntries.isEmpty {
                var items: [ActionSheetItem] = []
                items.append(ActionSheetTextItem(title: presentationData.strings.SecretPasscodeSettings_AccountsHeader.uppercased()))
                
                for entry in accountEntries {
                    items.append(ActionSheetButtonItem(title: entry.peer.debugDisplayTitle, action: { [weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        
                        updateState { state in
                            let _ = updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                                return current.withUpdatedItem(passcode: state.settings.passcode) { sp in
                                    return sp.withUpdated(onRevealNavigateTo: ConceptNavigateTo(accountId: entry.accountId, peerId: nil))
                                }
                            }).start()
                            
                            return state.withUpdated(settings: state.settings.withUpdated(onRevealNavigateTo: ConceptNavigateTo(accountId: entry.accountId, peerId: nil)))
                        }
                    }))
                }
                
                itemGroups.append(ActionSheetItemGroup(items: items))
            }

            
            itemGroups.append(ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.SecretPasscodeSettings_OnRevealNavigateTo_None, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    
                    updateState { state in
                        let _ = updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                            return current.withUpdatedItem(passcode: state.settings.passcode) { sp in
                                return sp.withUpdated(onRevealNavigateTo: nil)
                            }
                        }).start()
                        
                        return state.withUpdated(settings: state.settings.withUpdated(onRevealNavigateTo: nil))
                    }
                })
            ]))
            
            itemGroups.append(ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: presentationData.strings.Common_Cancel, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ]))
            
            actionSheet.setItemGroups(itemGroups)
            
            presentControllerImpl?(actionSheet, ViewControllerPresentationArguments(presentationAnimation: .modalSheet))
        })
    })
    
    let signal = combineLatest(context.sharedContext.presentationData, statePromise.get())
    |> mapToSignal { presentationData, state in
        return combineLatest(.single(presentationData), .single(state), getAccountEntries(sharedContext: context.sharedContext, accountIds: state.settings.accountIds), getSecretChatEntries(sharedContext: context.sharedContext, secretChats: state.settings.secretChats, presentationData: presentationData))
    }
    |> mapToSignal {  presentationData, state, accountEntries, secretChatEntries -> Signal<(PresentationData, ConceptSecretPasscodeControllerState, [AccountEntry], [SecretChatEntry], UIImage?), NoError> in
        var onRevealNavigateToAvatarImage: Signal<UIImage?, NoError> = .single(nil)
        let avatarImageSize = CGSize(width: 30.0, height: 30.0)
        
        if let accountId = state.settings.onRevealNavigateTo?.accountId {
            if state.settings.onRevealNavigateTo?.peerId != nil {
                // Do nothing
            } else {
                if let entry = accountEntries.first(where: { $0.accountId == accountId }) {
                    onRevealNavigateToAvatarImage = peerAvatarCompleteImage(account: entry._peerItemContext.context.account, peer: entry.peer, size: avatarImageSize)
                }
            }
        }
        
        return combineLatest(.single(presentationData), .single(state), .single(accountEntries), .single(secretChatEntries), onRevealNavigateToAvatarImage)
    }
    |> deliverOnMainQueue
    |> map { (presentationData: PresentationData, state: ConceptSecretPasscodeControllerState, accountEntries: [AccountEntry], secretChatEntries: [SecretChatEntry], onRevealNavigateToAvatarImage: UIImage?) -> (ItemListControllerState, (ItemListNodeState, ConceptSecretPasscodeControllerArguments)) in
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(presentationData.strings.SecretPasscodeSettings_Title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: secretPasscodeControllerEntries(presentationData: presentationData, state: state, accountEntries: accountEntries, onRevealNavigateToAvatarImage: onRevealNavigateToAvatarImage), style: .blocks)
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    
    pushControllerImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    
    popControllerImpl = { [weak controller] in
        let _ = (controller?.navigationController as? NavigationController)?.popViewController(animated: true)
    }
    
    presentControllerImpl = { [weak controller] c, p in
        controller?.present(c, in: .window(.root), with: p)
    }
    
    presentControllerInCurrentImpl = { [weak controller] c in
        controller?.present(c, in: .current)
    }
    
    controller.didAppear = { [weak controller] (firstTime: Bool) in
        if firstTime && isNew {
            Queue.mainQueue().after(0.5) {
                let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                let tooltipController = TooltipController(content: .text(presentationData.strings.SecretPasscodeSettings_Intro), baseFontSize: presentationData.listsFontSize.baseDisplaySize, timeout: 10.0, dismissByTapOutside: true)
                controller?.present(tooltipController, in: .window(.root), with: TooltipControllerPresentationArguments(sourceNodeAndRect: {
                    if let controller {
                        return (controller.displayNode, controller.frameForItemNode({ node in
                            if node is ItemListSectionHeaderItemNode {
                                return true
                            }
                            return false
                        })?.offsetBy(dx: 0.0, dy: 20.0) ?? CGRect())
                    }
                    return nil
                }))
            }
        }
    }
    
    controller.tag = "ConceptSecretPasscodeController"
    
    return controller
}

extension ItemListController {
    private static var tagKey: Int?
    
    public var tag: String? {
        get {
            return objc_getAssociatedObject(self, &Self.tagKey) as? String
        }
        set {
            objc_setAssociatedObject(self, &Self.tagKey, newValue, .OBJC_ASSOCIATION_RETAIN)
        }
    }
}

extension ConceptSecretPasscode {
    public init(passcode: String, active: Bool) {
        self.init(passcode: passcode, active: active, timeout: 5 * 60, accountIds: [], secretChats: [], onRevealNavigateTo: nil)
    }
    
    public func withUpdated(passcode: String) -> ConceptSecretPasscode {
        return ConceptSecretPasscode(passcode: passcode, active: self.active, timeout: self.timeout, accountIds: self.accountIds, secretChats: self.secretChats, onRevealNavigateTo: self.onRevealNavigateTo)
    }
    
    public func withUpdated(timeout: Int32?) -> ConceptSecretPasscode {
        return ConceptSecretPasscode(passcode: self.passcode, active: self.active, timeout: timeout, accountIds: self.accountIds, secretChats: self.secretChats, onRevealNavigateTo: self.onRevealNavigateTo)
    }
    
    public func withUpdated(accountIds: Set<AccountRecordId>) -> ConceptSecretPasscode {
        return ConceptSecretPasscode(passcode: self.passcode, active: self.active, timeout: self.timeout, accountIds: accountIds, secretChats: self.secretChats, onRevealNavigateTo: self.onRevealNavigateTo)
    }
    
    public func withUpdated(secretChats: Set<ConceptSecretChatId>) -> ConceptSecretPasscode {
        return ConceptSecretPasscode(passcode: self.passcode, active: self.active, timeout: self.timeout, accountIds: self.accountIds, secretChats: secretChats, onRevealNavigateTo: self.onRevealNavigateTo)
    }
    
    public func withUpdated(onRevealNavigateTo: ConceptNavigateTo?) -> ConceptSecretPasscode {
        return ConceptSecretPasscode(passcode: self.passcode, active: self.active, timeout: self.timeout, accountIds: self.accountIds, secretChats: self.secretChats, onRevealNavigateTo: onRevealNavigateTo)
    }
}

extension ConceptSecretPasscodes {
    public func withUpdatedItem(passcode: String, _ f: (ConceptSecretPasscode) -> ConceptSecretPasscode) -> ConceptSecretPasscodes {
        if let ind = self.secretPasscodes.firstIndex(where: { $0.passcode == passcode }) {
            var updated = self.secretPasscodes
            updated[ind] = f(self.secretPasscodes[ind])
            return ConceptSecretPasscodes(secretPasscodes: updated, dbCoveringAccounts: self.dbCoveringAccounts, cacheCoveringAccounts: self.cacheCoveringAccounts)
        }
        return self
    }
    
    public func activeSecretChatPeerIds(accountId: AccountRecordId) -> Set<PeerId> {
        var result = Set<PeerId>()
        for secretPasscode in self.secretPasscodes {
            if secretPasscode.active {
                for secretChat in secretPasscode.secretChats {
                    if secretChat.accountId == accountId {
                        result.insert(secretChat.peerId)
                    }
                }
            }
        }
        return result
    }
    
    public func inactiveSecretChatPeerIdsForAllAccounts() -> Set<PeerId> {
        var active = Set<PeerId>()
        var inactive = Set<PeerId>()
        for secretPasscode in self.secretPasscodes {
            for secretChat in secretPasscode.secretChats {
                if secretPasscode.active {
                    active.insert(secretChat.peerId)
                } else {
                    inactive.insert(secretChat.peerId)
                }
            }
        }
        return inactive.subtracting(active)
    }
    
    public func allSecretChatPeerIdsForAllAccounts() -> Set<PeerId> {
        var result = Set<PeerId>()
        for secretPasscode in self.secretPasscodes {
            for secretChat in secretPasscode.secretChats {
                result.insert(secretChat.peerId)
            }
        }
        return result
    }
}

private func areThereAnyWidgetsContainingChatsFromAccount(id accountId: AccountRecordId) -> Signal<Bool, NoError> {
    return .single(false)
}

private func autolockStringForTimeout(strings: PresentationStrings, timeout: Int32?) -> String {
    if let timeout = timeout {
        if timeout == 0 {
            return strings.PasscodeSettings_AutoLock_IfAwayFor_1minute
        } else if timeout == 10 {
            return "If away for 10s"
        } else if timeout == 1 * 60 {
            return strings.PasscodeSettings_AutoLock_IfAwayFor_1minute
        } else if timeout == 5 * 60 {
            return strings.PasscodeSettings_AutoLock_IfAwayFor_5minutes
        } else if timeout == 15 * 60 {
            return strings.PasscodeSettings_AutoLock_IfAwayFor_5minutes.replacingOccurrences(of: "5", with: "15")
        } else if timeout == 1 * 60 * 60 {
            return strings.PasscodeSettings_AutoLock_IfAwayFor_1hour
        } else if timeout == 5 * 60 * 60 {
            return strings.PasscodeSettings_AutoLock_IfAwayFor_5hours
        } else {
            return ""
        }
    } else {
        return strings.PasscodeSettings_AutoLock_Disabled
    }
}

