import Foundation
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import AccountContext
import TelegramCore

private final class ReplacementArguments {
    let toggle: (Int32, Bool) -> Void
    let action: (Int32) -> Void
    let text: (Int32, String) -> Void
    init(toggle: @escaping (Int32, Bool) -> Void, action: @escaping (Int32) -> Void, text: @escaping (Int32, String) -> Void = { _, _ in }) {
        self.toggle = toggle; self.action = action; self.text = text
    }
}

private enum ReplacementEntry: ItemListNodeEntry {
    case toggle(Int32, Int32, PresentationTheme, String, Bool)
    case action(Int32, Int32, PresentationTheme, String)
    case info(Int32, Int32, PresentationTheme, String)
    case input(Int32, Int32, PresentationTheme, String, String)
    var stableId: Int32 { switch self { case let .toggle(i, _, _, _, _), let .action(i, _, _, _), let .info(i, _, _, _), let .input(i, _, _, _, _): return i } }
    var section: ItemListSectionId { switch self { case let .toggle(_, s, _, _, _), let .action(_, s, _, _), let .info(_, s, _, _), let .input(_, s, _, _, _): return s } }
    static func <(lhs: Self, rhs: Self) -> Bool { lhs.stableId < rhs.stableId }
    static func ==(lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.toggle(i, s, a, t, v), .toggle(j, q, b, u, w)): return i == j && s == q && a === b && t == u && v == w
        case let (.action(i, s, a, t), .action(j, q, b, u)), let (.info(i, s, a, t), .info(j, q, b, u)): return i == j && s == q && a === b && t == u
        case let (.input(i, s, a, t, v), .input(j, q, b, u, w)): return i == j && s == q && a === b && t == u && v == w
        default: return false
        }
    }
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! ReplacementArguments
        switch self {
        case let .toggle(id, _, _, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: section, style: .blocks, updated: { arguments.toggle(id, $0) })
        case let .action(id, _, _, title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: section, style: .blocks, action: { arguments.action(id) })
        case let .info(_, _, _, title): return ItemListTextItem(presentationData: presentationData, text: .plain(title), sectionId: section)
        case let .input(id, _, _, title, value):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: title, textColor: presentationData.theme.list.itemPrimaryTextColor), text: value, placeholder: "", type: .regular(capitalization: false, autocorrection: false), returnKeyType: .done, clearType: .always, sectionId: section, textUpdated: { arguments.text(id, $0) }, action: {})
        }
    }
}

private func replacementEditor(context: AccountContext, rule: ConceptTextReplacementRule?, save: @escaping (ConceptTextReplacementRule?) -> Void) -> ViewController {
    let ru = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.hasPrefix("ru") }
    let value = Atomic(value: rule ?? ConceptTextReplacementRule(source: "", replacement: ""))
    let promise = ValuePromise(value.with { $0 }, ignoreRepeated: true)
    var dismiss: (() -> Void)?
    let arguments = ReplacementArguments(toggle: { _, enabled in promise.set(value.modify { var r = $0; r.enabled = enabled; return r }) }, action: { _ in save(nil); dismiss?() }, text: { id, text in
        promise.set(value.modify { var r = $0; if id == 0 { r.source = String(text.prefix(1024)) } else { r.replacement = String(text.prefix(4096)) }; return r })
    })
    let signal = combineLatest(context.sharedContext.presentationData, promise.get()) |> map { presentation, rule -> (ItemListControllerState, (ItemListNodeState, ReplacementArguments)) in
        let t = presentation.theme
        var entries: [ReplacementEntry] = [
            .input(0, 0, t, ru ? "Найти: " : "Find: ", rule.source),
            .input(1, 0, t, ru ? "Заменить: " : "Replace: ", rule.replacement),
            .toggle(2, 1, t, ru ? "Правило включено" : "Rule Enabled", rule.enabled),
            .info(3, 1, t, ru ? "Пустая замена удаляет найденный текст. Учитывается регистр; регулярные выражения не используются." : "An empty replacement deletes matching text. Matches are case-sensitive; regular expressions are not used.")
        ]
        if rule.source.isEmpty == false { entries.append(.info(4, 1, t, "\"" + rule.source + "\" → \"" + rule.replacement + "\"")) }
        let button = ItemListNavigationButton(content: .text(presentation.strings.Common_Save), style: .bold, enabled: !rule.source.isEmpty, action: { save(value.with { $0 }); dismiss?() })
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentation), title: .text(ru ? "Замена текста" : "Text Replacement"), leftNavigationButton: nil, rightNavigationButton: button, backNavigationButton: ItemListBackButton(title: presentation.strings.Common_Back))
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentation), entries: entries, style: .blocks), arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    dismiss = { [weak controller] in controller?.navigationController?.popViewController(animated: true) }
    return controller
}

public func conceptTextReplacementController(context: AccountContext) -> ViewController {
    let ru = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.hasPrefix("ru") }
    let revision = ValuePromise(0)
    var counter = 0
    var push: ((ViewController) -> Void)?
    let refresh = { counter += 1; revision.set(counter) }
    let arguments = ReplacementArguments(toggle: { _, value in ConceptTextReplacement.isEnabled = value; refresh() }, action: { id in
        let rules = ConceptTextReplacement.rules
        let index = Int(id - 3)
        if id >= 3 && id % 2 == 0 {
            let removeIndex = Int((id - 4) / 2)
            guard rules.indices.contains(removeIndex) else { return }
            var updated = rules; updated.remove(at: removeIndex); ConceptTextReplacement.rules = updated; refresh(); return
        }
        let editIndex = id == 2 ? nil : Optional(index / 2)
        if let editIndex, !rules.indices.contains(editIndex) { return }
        guard editIndex != nil || rules.count < 100 else { return }
        push?(replacementEditor(context: context, rule: editIndex.map { rules[$0] }, save: { rule in
            var updated = ConceptTextReplacement.rules
            if let editIndex, updated.indices.contains(editIndex) {
                if let rule { updated[editIndex] = rule } else { updated.remove(at: editIndex) }
            } else if let rule, updated.count < 100 { updated.append(rule) }
            ConceptTextReplacement.rules = updated; refresh()
        }))
    })
    let signal = combineLatest(context.sharedContext.presentationData, revision.get()) |> map { presentation, _ -> (ItemListControllerState, (ItemListNodeState, ReplacementArguments)) in
        let t = presentation.theme
        var entries: [ReplacementEntry] = [
            .toggle(0, 0, t, ru ? "Заменять перед отправкой" : "Replace Before Sending", ConceptTextReplacement.isEnabled),
            .info(1, 0, t, ru ? "Правила применяются по порядку к новым сообщениям и подписям. Сообщение сразу отправляется с заменами, без отметки о редактировании. Пустое сообщение после замен не отправляется. Пересланные сообщения и структурированные документы не изменяются." : "Rules apply in order to new messages and captions before sending, without an edited label. An empty message after replacements is not sent. Forwarded messages and structured documents are unchanged."),
            .action(2, 1, t, ru ? "Добавить правило" : "Add Rule")
        ]
        for (index, rule) in ConceptTextReplacement.rules.enumerated() {
            entries.append(.action(Int32(3 + index * 2), Int32(2 + index), t, (rule.enabled ? "" : "⏸ ") + rule.source + " → " + (rule.replacement.isEmpty ? "∅" : rule.replacement)))
            entries.append(.action(Int32(4 + index * 2), Int32(2 + index), t, ru ? "Удалить правило" : "Delete Rule"))
        }
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentation), title: .text(ru ? "Замены при отправке" : "Text Replacement"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentation.strings.Common_Back))
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentation), entries: entries, style: .blocks), arguments))
    }
    let controller = ItemListController(context: context, state: signal)
    push = { [weak controller] in controller?.push($0) }
    return controller
}
