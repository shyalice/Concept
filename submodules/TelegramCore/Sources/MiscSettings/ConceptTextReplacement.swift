import Foundation

public struct ConceptTextReplacementRule: Codable, Equatable {
    public var source: String
    public var replacement: String
    public var enabled: Bool
    public init(source: String, replacement: String, enabled: Bool = true) {
        self.source = source; self.replacement = replacement; self.enabled = enabled
    }
}

public struct ConceptTextReplacementResult {
    public let text: String
    public let ranges: [Range<Int>?]
}

/// Telegram entity ranges use UTF-16 offsets. Rules are literal, case-sensitive
/// and applied once each in list order; a replacement is never recursively
/// matched by the same rule. All callers share this transformation before send.
public enum ConceptTextReplacement {
    public static func apply(text: String, ranges: [Range<Int>], rules: [ConceptTextReplacementRule]) -> ConceptTextReplacementResult {
        var text = text
        var ranges: [Range<Int>?] = ranges.map { $0.lowerBound >= 0 && $0.upperBound <= (text as NSString).length && !$0.isEmpty ? $0 : nil }
        for rule in rules.prefix(100) where rule.enabled && !rule.source.isEmpty && rule.source != rule.replacement {
            let value = text as NSString
            var search = NSRange(location: 0, length: value.length)
            var matches: [NSRange] = []
            while search.length > 0 {
                let range = value.range(of: rule.source, options: .literal, range: search)
                guard range.location != NSNotFound else { break }
                matches.append(range)
                let next = range.location + range.length
                search = NSRange(location: next, length: value.length - next)
            }
            guard !matches.isEmpty else { continue }
            let replacementLength = (rule.replacement as NSString).length
            let expectedLength = value.length + matches.count * (replacementLength - (rule.source as NSString).length)
            // Limit accidental expansion without sending a truncated message.
            guard expectedLength <= 131072 else { continue }
            let updated = NSMutableString(string: text)
            for match in matches.reversed() {
                updated.replaceCharacters(in: match, with: rule.replacement)
                let lower = match.location
                let upper = lower + match.length
                let delta = replacementLength - match.length
                ranges = ranges.map { range in
                    guard let range else { return nil }
                    let start: Int
                    if range.lowerBound <= lower { start = range.lowerBound }
                    else if range.lowerBound >= upper { start = range.lowerBound + delta }
                    else { start = lower }
                    let end: Int
                    if range.upperBound <= lower { end = range.upperBound }
                    else if range.upperBound >= upper { end = range.upperBound + delta }
                    else { end = lower + replacementLength }
                    return start < end ? start ..< end : nil
                }
            }
            text = updated as String
        }
        return ConceptTextReplacementResult(text: text, ranges: ranges)
    }
}
