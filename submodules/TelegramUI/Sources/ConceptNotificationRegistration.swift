import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import ConceptNotifications

func conceptNotificationRegistrationRequest(account: AccountContext, token: Data, sandbox: Bool, otherUserIds: [EnginePeer.Id.Id]) -> NotificationRegistrationRequest {
    let others = otherUserIds.filter { $0 != account.account.peerId.id }
    let data: [String: Any] = ["token": token.base64EncodedString(), "sandbox": sandbox, "others": others.map { $0._internalGetInt64Value() }.sorted()]
    let fingerprint = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])) ?? token
    return NotificationRegistrationRequest(key: .init(accountId: account.account.id.int64, channel: "messages"), credential: token, fingerprint: fingerprint, register: {
        return account.engine.accountData.registerNotificationToken(token: token, type: .aps(encrypt: true), sandbox: sandbox, otherAccountUserIds: others, excludeMutedChats: false)
    }, unregister: {
        return account.engine.accountData.unregisterNotificationToken(token: token, type: .aps(encrypt: false), otherAccountUserIds: others)
    })
}
