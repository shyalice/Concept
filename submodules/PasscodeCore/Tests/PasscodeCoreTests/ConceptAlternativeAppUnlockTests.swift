import Foundation
import LocalAuthentication
import XCTest
@testable import PasscodeCore

final class ConceptAlternativeAppUnlockTests: XCTestCase {
    private final class Storage: PasscodeStorage {
        var values: [String: Data] = [:]

        func read(_ account: String, context: LAContext?) throws -> Data? { return self.values[account] }
        func write(_ data: Data, account: String, biometric: Bool) throws { self.values[account] = data }
        func remove(_ account: String) throws { self.values.removeValue(forKey: account) }
    }

    private func store() -> PasscodeCredentialStore {
        return PasscodeCredentialStore(storage: Storage(), iterations: { PasscodeCrypto.minimumIterations }, clock: { (1, 100) })
    }

    func testAlternativeUnlockDoesNotReplacePrimaryCredentialOrAuthorizeSettings() throws {
        let store = self.store()
        let reference = try store.setPasscode("123456", kind: .digits6, session: nil)
        XCTAssertTrue(try store.verifyAlternativeAppUnlock(reference: reference, validate: { true }))
        XCTAssertThrowsError(try store.verify("654321", reference: reference, scope: .settings)) { error in
            XCTAssertEqual(error as? PasscodeError, .invalidCode)
        }
        let session = try store.verify("123456", reference: reference, scope: .settings)
        XCTAssertEqual(session.scope, .settings)
        session.invalidate()
    }

    func testSharedCooldownAppliesBeforeAlternativeCodeIsChecked() throws {
        let store = self.store()
        let reference = try store.setPasscode("123456", kind: .digits6, session: nil)
        for _ in 0 ..< 6 {
            XCTAssertThrowsError(try store.verify("000000", reference: reference, scope: .appUnlock))
        }
        var checked = false
        XCTAssertThrowsError(try store.verifyAlternativeAppUnlock(reference: reference, validate: { checked = true; return true })) { error in
            XCTAssertEqual(error as? PasscodeError, .cooldown(60))
        }
        XCTAssertFalse(checked)
    }

    func testSuccessfulAlternativeCodeClearsPreviousFailedAttempts() throws {
        let store = self.store()
        let reference = try store.setPasscode("123456", kind: .digits6, session: nil)
        for _ in 0 ..< 5 {
            XCTAssertThrowsError(try store.verify("000000", reference: reference, scope: .appUnlock))
        }
        XCTAssertTrue(try store.verifyAlternativeAppUnlock(reference: reference, validate: { true }))
        XCTAssertThrowsError(try store.verify("000000", reference: reference, scope: .appUnlock))
        XCTAssertEqual(try store.cooldownRemaining(), 0)
    }

    func testStaleCredentialDoesNotEvaluateAlternativeCode() throws {
        let store = self.store()
        _ = try store.setPasscode("123456", kind: .digits6, session: nil)
        let other = self.store()
        let stale = try other.setPasscode("123456", kind: .digits6, session: nil)
        var checked = false
        XCTAssertThrowsError(try store.verifyAlternativeAppUnlock(reference: stale, validate: { checked = true; return true })) { error in
            XCTAssertEqual(error as? PasscodeError, .staleAuthorization)
        }
        XCTAssertFalse(checked)
    }

    func testNoPrimaryCredentialCannotBeUnlockedByAnAlternative() {
        XCTAssertThrowsError(try self.store().verifyAlternativeAppUnlock(reference: nil, validate: { true })) { error in
            XCTAssertEqual(error as? PasscodeError, .authenticationRequired)
        }
    }
}
