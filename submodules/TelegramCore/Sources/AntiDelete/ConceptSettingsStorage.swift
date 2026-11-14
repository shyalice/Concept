import Foundation

/// Shares client privacy settings with the notification process. Message content
/// and edit history belong in account Postboxes, never in this defaults suite.
final class ConceptSettingsStorage {
    static let shared = ConceptSettingsStorage()
    private let lock = NSLock()
    private var current = UserDefaults.standard

    var defaults: UserDefaults {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.current
    }

    func configure(suiteName: String) {
        guard let shared = UserDefaults(suiteName: suiteName) else { return }
        if !Bundle.main.bundlePath.hasSuffix(".appex") {
            let existing = shared.persistentDomain(forName: suiteName) ?? [:]
            let retentionKeys: Set<String> = ["antiDelete.enabled", "antiDelete.archiveMedia", "antiDelete.deletedMessageTransparency"]
            for (key, value) in UserDefaults.standard.dictionaryRepresentation() {
                let isClientSetting = retentionKeys.contains(key) || key.hasPrefix("GhostMode.") || key.hasPrefix("MiscSettings.")
                if isClientSetting && existing[key] == nil {
                    shared.set(value, forKey: key)
                }
            }
        }
        shared.register(defaults: [
            "antiDelete.enabled": true,
            "antiDelete.archiveMedia": true,
            "antiDelete.deletedMessageTransparency": AntiDeleteManager.defaultDeletedMessageTransparency
        ])
        self.lock.lock()
        self.current = shared
        self.lock.unlock()
    }
}
