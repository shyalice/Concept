import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import TelegramCore
import TelegramUIPreferences

private final class ConceptSecretPasscodeSetupControllerArguments {
    let updatePasscode: (String) -> Void
    let toggleAccount: (AccountRecordId) -> Void
    let save: () -> Void
    
    init(updatePasscode: @escaping (String) -> Void, toggleAccount: @escaping (AccountRecordId) -> Void, save: @escaping () -> Void) {
        self.updatePasscode = updatePasscode
        self.toggleAccount = toggleAccount
        self.save = save
    }
}

private enum ConceptSecretPasscodeSetupSection: Int32 {
    case passcode
    case accounts
}

private enum ConceptSecretPasscodeSetupEntry: ItemListNodeEntry {
    case passcodeHeader(String)
    case passcode(String, String)
    case accountsHeader(String)
    case account(Int32, AccountRecordId, String, Bool)
    
    var section: ItemListSectionId {
        switch self {
        case .passcodeHeader, .passcode:
            return ConceptSecretPasscodeSetupSection.passcode.rawValue
        case .accountsHeader, .account:
            return ConceptSecretPasscodeSetupSection.accounts.rawValue
        }
    }
    
    var stableId: Int32 {
        switch self {
        case .passcodeHeader: return 0
        case .passcode: return 1
        case .accountsHeader: return 2
        case let .account(index, _, _, _): return 3 + index
        }
    }
    
    static func ==(lhs: ConceptSecretPasscodeSetupEntry, rhs: ConceptSecretPasscodeSetupEntry) -> Bool {
        switch lhs {
        case let .passcodeHeader(text):
            if case .passcodeHeader(text) = rhs { return true }
            return false
        case let .passcode(placeholder, text):
            if case .passcode(placeholder, text) = rhs { return true }
            return false
        case let .accountsHeader(text):
            if case .accountsHeader(text) = rhs { return true }
            return false
        case let .account(index, id, title, isSelected):
            if case .account(index, id, title, isSelected) = rhs { return true }
            return false
        }
    }
    
    static func <(lhs: ConceptSecretPasscodeSetupEntry, rhs: ConceptSecretPasscodeSetupEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ConceptSecretPasscodeSetupControllerArguments
        switch self {
        case let .passcodeHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .passcode(placeholder, text):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: "Passcode:", textColor: presentationData.theme.list.itemPrimaryTextColor), text: text, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), returnKeyType: .done, clearType: .always, sectionId: self.section, textUpdated: { value in
                arguments.updatePasscode(value)
            }, action: {})
        case let .accountsHeader(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .account(_, id, title, isSelected):
            return ItemListSwitchItem(presentationData: presentationData,systemStyle: .glass, title: title, value: isSelected, sectionId: self.section, style: .blocks, updated: { _ in
                arguments.toggleAccount(id)
            })
        }
    }
}

private struct ConceptSecretPasscodeSetupState: Equatable {
    var passcode: String
    var selectedAccounts: Set<AccountRecordId>
}

public func conceptSecretPasscodeSetupController(context: AccountContext, passcode: ConceptSecretPasscode?) -> ViewController {
    let initialState = ConceptSecretPasscodeSetupState(
        passcode: passcode?.passcode ?? "",
        selectedAccounts: passcode?.accountIds ?? Set()
    )
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((ConceptSecretPasscodeSetupState) -> ConceptSecretPasscodeSetupState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    
    var dismissImpl: (() -> Void)?
    
    let arguments = ConceptSecretPasscodeSetupControllerArguments(
        updatePasscode: { text in
            updateState { state in
                var state = state
                state.passcode = text
                return state
            }
        },
        toggleAccount: { accountId in
            updateState { state in
                var state = state
                if state.selectedAccounts.contains(accountId) {
                    state.selectedAccounts.remove(accountId)
                } else {
                    state.selectedAccounts.insert(accountId)
                }
                return state
            }
        },
        save: {
            let state = stateValue.with { $0 }
            guard !state.passcode.isEmpty else { return }
            
            let _ = updateConceptSecretPasscodes(context.sharedContext.accountManager, { current in
                var secretPasscodes = current.secretPasscodes
                if let passcode = passcode, let index = secretPasscodes.firstIndex(where: { $0.passcode == passcode.passcode }) {
                    secretPasscodes[index] = secretPasscodes[index].withUpdated(active: secretPasscodes[index].active)
                    secretPasscodes[index] = ConceptSecretPasscode(passcode: state.passcode, active: secretPasscodes[index].active, timeout: secretPasscodes[index].timeout, accountIds: state.selectedAccounts, secretChats: secretPasscodes[index].secretChats, onRevealNavigateTo: secretPasscodes[index].onRevealNavigateTo)
                } else {
                    // It's a new passcode
                    secretPasscodes.append(ConceptSecretPasscode(passcode: state.passcode, active: true, timeout: nil, accountIds: state.selectedAccounts, secretChats: [], onRevealNavigateTo: nil))
                }
                return ConceptSecretPasscodes(secretPasscodes: secretPasscodes, dbCoveringAccounts: current.dbCoveringAccounts, cacheCoveringAccounts: current.cacheCoveringAccounts)
            }).start()
            
            dismissImpl?()
        }
    )
    
    let activeAccountsSignal = context.sharedContext.activeAccountContexts
        |> mapToSignal { activeAccountContexts -> Signal<[AccountWithInfo], NoError> in
            let (_, accounts, _) = activeAccountContexts
            return combineLatest(accounts.map { _, context, _ -> Signal<AccountWithInfo?, NoError> in
                return context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                |> map { peer -> AccountWithInfo? in
                    guard let peer = peer else { return nil }
                    return AccountWithInfo(account: context.account, peer: peer)
                }
                |> distinctUntilChanged
            })
            |> map { accountsWithInfo -> [AccountWithInfo] in
                return accountsWithInfo.compactMap { $0 }
            }
        }
        |> take(1)
    
    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get(),
        activeAccountsSignal
    ) |> map { presentationData, state, accounts -> (ItemListControllerState, (ItemListNodeState, ConceptSecretPasscodeSetupControllerArguments)) in
        var entries: [ConceptSecretPasscodeSetupEntry] = []
        
        entries.append(.passcodeHeader("SECRET PASSCODE"))
        entries.append(.passcode("Enter passcode", state.passcode))
        
        entries.append(.accountsHeader("HIDE ACCOUNTS"))
        
        for (i, accountInfo) in accounts.enumerated() {
            let title = accountInfo.peer.debugDisplayTitle
            let isSelected = state.selectedAccounts.contains(accountInfo.account.id)
            entries.append(.account(Int32(i), accountInfo.account.id, title, isSelected))
        }
        
        let rightButton = ItemListNavigationButton(content: .text(presentationData.strings.Common_Save), style: .bold, enabled: !state.passcode.isEmpty, action: {
            arguments.save()
        })
        
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text("Setup Passcode"), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks)
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    
    return controller
}
