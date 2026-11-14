import Foundation

/// A version actually observed by this client. The server does not supply old edits.
public struct ConceptMessageRevision: Codable, Equatable {
    public let text: String
    public let timestamp: Int32
    public let formattingData: Data?

    public init(text: String, timestamp: Int32, formattingData: Data? = nil) {
        self.text = text
        self.timestamp = timestamp
        self.formattingData = formattingData
    }
}

/// Pure revision policy, shared by all Postbox message replacement paths.
public enum ConceptEditHistory {
    public static func appendingPreviousVersion(
        to revisions: [ConceptMessageRevision],
        previous: ConceptMessageRevision,
        previousEditDate: Int32?,
        updatedText: String,
        updatedFormattingData: Data?,
        updatedEditDate: Int32?
    ) -> [ConceptMessageRevision] {
        guard let updatedEditDate, updatedEditDate >= previous.timestamp else {
            return revisions
        }
        let contentChanged = previous.text != updatedText || previous.formattingData != updatedFormattingData
        // Telegram may advance edit_date while replaying identical content
        // (including changes to non-visible metadata). That is not a new edit.
        guard contentChanged else {
            return revisions
        }
        guard revisions.last.map({ $0.text == previous.text && $0.formattingData == previous.formattingData }) != true else {
            return revisions
        }
        return revisions + [previous]
    }

    public static func visibleRevisions(_ revisions: [ConceptMessageRevision], currentText: String, currentFormattingData: Data?) -> [ConceptMessageRevision] {
        var result: [ConceptMessageRevision] = []
        for revision in revisions {
            if let last = result.last, last.text == revision.text, last.formattingData == revision.formattingData { continue }
            result.append(revision)
        }
        if let last = result.last, last.text == currentText, last.formattingData == currentFormattingData { result.removeLast() }
        return result
    }
}
