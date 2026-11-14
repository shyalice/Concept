import Foundation
import SwiftSignalKit

/// The caller serializes updates and disposal on its delivery queue.
public final class NotificationAccountSubscriptions<Id: Hashable> {
    private var entries: [Id: (identity: ObjectIdentifier, disposable: Disposable)] = [:]

    public init() {}

    public func update(_ accounts: [Id: ObjectIdentifier], subscribe: (Id) -> Disposable) {
        for id in Array(self.entries.keys) {
            if self.entries[id]?.identity != accounts[id] {
                self.entries.removeValue(forKey: id)?.disposable.dispose()
            }
        }
        for (id, identity) in accounts where self.entries[id] == nil {
            self.entries[id] = (identity, subscribe(id))
        }
    }

    public func dispose() {
        let entries = self.entries
        self.entries.removeAll()
        for entry in entries.values { entry.disposable.dispose() }
    }

    deinit { self.dispose() }
}
