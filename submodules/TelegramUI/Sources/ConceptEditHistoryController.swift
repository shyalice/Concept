import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import ItemListUI
import PresentationDataUtils
import SGStrings

private final class ConceptEditHistoryArguments {
    let copy: (String) -> Void

    init(copy: @escaping (String) -> Void) {
        self.copy = copy
    }
}

private enum ConceptEditHistoryEntry: ItemListNodeEntry {
    case notice(PresentationTheme, String)
    case header(Int32, PresentationTheme, String)
    case text(Int32, PresentationTheme, String)
    case copy(Int32, PresentationTheme, String, String)

    var section: ItemListSectionId {
        switch self {
        case .notice: return 0
        case let .header(index, _, _), let .text(index, _, _), let .copy(index, _, _, _): return index + 1
        }
    }

    var stableId: Int32 {
        switch self {
        case .notice: return 0
        case let .header(index, _, _): return index * 3 + 1
        case let .text(index, _, _): return index * 3 + 2
        case let .copy(index, _, _, _): return index * 3 + 3
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.notice(a, x), .notice(b, y)): return a === b && x == y
        case let (.header(i, a, x), .header(j, b, y)), let (.text(i, a, x), .text(j, b, y)):
            return i == j && a === b && x == y
        case let (.copy(i, a, x, v), .copy(j, b, y, w)):
            return i == j && a === b && x == y && v == w
        default: return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ConceptEditHistoryArguments
        switch self {
        case let .notice(_, text), let .text(_, _, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(_, _, title):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: title, sectionId: self.section)
        case let .copy(_, _, title, value):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.copy(value)
            })
        }
    }
}

func conceptEditHistoryController(context: AccountContext, message: EngineRawMessage) -> ViewController {
    let arguments = ConceptEditHistoryArguments(copy: { text in
        UIPasteboard.general.string = text
    })
    let signal = combineLatest(
        context.sharedContext.presentationData,
        context.engine.data.subscribe(TelegramEngine.EngineData.Item.Messages.Message(id: message.id))
    )
    |> map { presentationData, currentMessage -> (ItemListControllerState, (ItemListNodeState, ConceptEditHistoryArguments)) in
        let current = currentMessage?._asMessage() ?? message
        let language = presentationData.strings.baseLanguageCode
        let history = conceptVisibleMessageRevisions(message: EngineMessage(current))
        let currentVersion = ConceptMessageRevision(text: current.text, timestamp: current.editedTime ?? current.timestamp)
        let versions = history + [currentVersion]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language)
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        var entries: [ConceptEditHistoryEntry] = [
            .notice(presentationData.theme, i18n("Message.EditHistory.Notice", language))
        ]
        for (index, version) in versions.enumerated() {
            let title: String
            if index == versions.count - 1 {
                title = i18n("Message.EditHistory.Current", language)
            } else if index == 0 {
                title = i18n("Message.EditHistory.FirstObserved", language)
            } else {
                title = i18n("Message.EditHistory.Version", language) + " \(index + 1)"
            }
            let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(version.timestamp)))
            let row = Int32(index)
            entries.append(.header(row, presentationData.theme, title + " · " + date))
            entries.append(.text(row, presentationData.theme, version.text.isEmpty ? i18n("Message.EditHistory.EmptyText", language) : version.text))
            if !version.text.isEmpty {
                entries.append(.copy(row, presentationData.theme, presentationData.strings.Conversation_ContextMenuCopy, version.text))
            }
        }
        return (
            ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(i18n("Message.EditHistory.Title", language)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back)),
            (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), arguments)
        )
    }
    return ItemListController(context: context, state: signal)
}
