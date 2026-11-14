import Foundation
import XCTest
@testable import ConceptBadgeCatalog

final class ConceptBadgeCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1800000000)
    private func catalog(schema: Int = 3, revision: Int = 6, issued: Int = 1800000000, expires: Int = 1800086400, badges: [String: [String: String]] = ["channel:17": ["role": "moderator", "glyph": "butterfly"]]) -> Data {
        return try! JSONSerialization.data(withJSONObject: ["schema": schema, "revision": revision, "issued": issued, "expires": expires, "badges": badges])
    }
    func testPlainHTTPSCatalogAndTypedPeers() {
        let decoded = ConceptBadgeCatalog.decode(catalog(), minimumRevision: 6, now: now)
        XCTAssertEqual(decoded?.badges["channel:17"]?.role, .moderator)
        XCTAssertEqual(decoded?.badges["channel:17"]?.hasRosette, true)
        XCTAssertNil(decoded?.badges["17"])
    }
    func testRejectsExpiredFutureAndRollbackCatalogs() {
        XCTAssertNil(ConceptBadgeCatalog.decode(catalog(expires: 1799999999), minimumRevision: 6, now: now))
        XCTAssertNil(ConceptBadgeCatalog.decode(catalog(issued: 1800000301), minimumRevision: 6, now: now))
        XCTAssertNil(ConceptBadgeCatalog.decode(catalog(revision: 5), minimumRevision: 6, now: now))
        XCTAssertNil(ConceptBadgeCatalog.decode(catalog(expires: 1800691200), minimumRevision: 6, now: now))
    }
    func testRejectsLegacyEnvelopeHTMLAndInvalidRecords() {
        XCTAssertNil(ConceptBadgeCatalog.decode(catalog(schema: 2), minimumRevision: 1, now: now))
        XCTAssertNil(ConceptBadgeCatalog.decode(Data("<html>challenge</html>".utf8), minimumRevision: 1, now: now))
        for key in ["01", "bot:17", "-17", "group:0", "4503599627370496"] {
            XCTAssertNil(ConceptBadgeCatalog.decode(catalog(badges: [key: ["role": "member", "glyph": "star"]]), minimumRevision: 1, now: now))
        }
        XCTAssertNil(ConceptBadgeCatalog.decode(catalog(badges: ["17": ["role": "administrator", "glyph": "star"]]), minimumRevision: 1, now: now))
    }
}
