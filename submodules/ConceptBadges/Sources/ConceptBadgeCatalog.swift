import Foundation

public struct ConceptBadge: Codable, Equatable {
    public enum Role: String, Codable { case member, moderator, developer, supporter }
    public enum Glyph: String, Codable { case butterfly, heart, star, sparkle }
    public let role: Role
    public let glyph: Glyph
    public var hasRosette: Bool { role == .moderator || role == .developer }
    public init(role: Role, glyph: Glyph = .butterfly) { self.role = role; self.glyph = glyph }
}

public struct ConceptBadgeCatalog: Decodable {
    public let schema: Int
    public let revision: Int64
    public let issued: Int64
    public let expires: Int64
    public let badges: [String: ConceptBadge]

    public static func decode(_ data: Data, minimumRevision: Int64, now: Date) -> ConceptBadgeCatalog? {
        guard data.count <= 8 * 1024 * 1024,
              let catalog = try? JSONDecoder().decode(Self.self, from: data),
              catalog.schema == 3,
              catalog.revision >= max(1, minimumRevision), catalog.badges.count <= 50000,
              catalog.issued > 0, catalog.issued <= Int64(now.timeIntervalSince1970) + 300,
              catalog.expires <= Int64(now.timeIntervalSince1970) + 7 * 86400 + 300,
              catalog.expires > Int64(now.timeIntervalSince1970),
              catalog.expires > catalog.issued, catalog.expires - catalog.issued <= 7 * 86400,
              catalog.badges.keys.allSatisfy({ id in
                  let parts = id.split(separator: ":", omittingEmptySubsequences: false)
                  let numberPart: String
                  if parts.count == 1 { numberPart = id }
                  else if parts.count == 2, parts[0] == "group" || parts[0] == "channel" { numberPart = String(parts[1]) }
                  else { return false }
                  guard let number = Int64(numberPart) else { return false }
                  return number > 0 && number < 1 << 52 && String(number) == numberPart
              }) else { return nil }
        return catalog
    }
}
