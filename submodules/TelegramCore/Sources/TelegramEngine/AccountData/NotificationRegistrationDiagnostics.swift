import Foundation

/// Delivery diagnostics contain no device tokens, payloads or message content.
public enum NotificationRegistrationDiagnostics {
    private static let lock = NSLock()
    private static let apnsKey = "Concept.PushDiagnostics.APNS"
    private static let serverKey = "Concept.PushDiagnostics.Telegram"

    public static func beginSession() {
        self.lock.lock()
        defer { self.lock.unlock() }
        UserDefaults.standard.set("waiting", forKey: self.apnsKey)
        UserDefaults.standard.removeObject(forKey: self.serverKey)
    }

    public static func recordAPNs(error: Error? = nil) {
        let status: String
        if let error {
            let error = error as NSError
            status = "\(error.domain) (\(error.code)): \(error.localizedDescription)"
        } else {
            status = "registered"
        }
        UserDefaults.standard.set(status, forKey: self.apnsKey)
    }

    public static func recordServerResult(accountId: Int64, result: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        var values = UserDefaults.standard.dictionary(forKey: self.serverKey) as? [String: String] ?? [:]
        values[String(accountId)] = result
        UserDefaults.standard.set(values, forKey: self.serverKey)
    }

    public static func snapshot() -> (apns: String, telegram: [String]) {
        self.lock.lock()
        defer { self.lock.unlock() }
        return (
            UserDefaults.standard.string(forKey: self.apnsKey) ?? "waiting",
            (UserDefaults.standard.dictionary(forKey: self.serverKey) as? [String: String] ?? [:]).values.sorted()
        )
    }
}
