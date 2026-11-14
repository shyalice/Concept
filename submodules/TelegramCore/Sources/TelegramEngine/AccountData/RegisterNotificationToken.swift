import Foundation
import ConceptNotifications
import SwiftSignalKit
import Postbox
internal import TelegramApi


public enum NotificationTokenType {
    case aps(encrypt: Bool)
    case voip
}

func _internal_unregisterNotificationToken(account: Account, token: Data, type: NotificationTokenType, otherAccountUserIds: [PeerId.Id]) -> Signal<Never, NoError> {
    let mappedType: Int32
    switch type {
        case .aps:
            mappedType = 1
        case .voip:
            mappedType = 9
    }
    return account.network.request(Api.functions.account.unregisterDevice(tokenType: mappedType, token: hexString(token), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
    |> retryRequest
    |> ignoreValues
}

func _internal_registerNotificationToken(account: Account, token: Data, type: NotificationTokenType, sandbox: Bool, otherAccountUserIds: [PeerId.Id], excludeMutedChats: Bool) -> Signal<NotificationRegistrationResult, NoError> {
    return masterNotificationsKey(account: account, ignoreDisabled: false)
    |> map { $0.data }
    |> mapToSignal { masterKey -> Signal<NotificationRegistrationResult, NoError> in
        let mappedType: Int32
        var keyData = Data()
        switch type {
            case let .aps(encrypt):
                mappedType = 1
                if encrypt {
                    keyData = masterKey
                }
            case .voip:
                mappedType = 9
                keyData = masterKey
        }
        var flags: Int32 = 0
        if excludeMutedChats {
            flags |= 1 << 0
        }
        if mappedType != 9 {
            NotificationRegistrationDiagnostics.recordServerResult(accountId: account.id.int64, result: "waiting")
        }
        return account.network.request(Api.functions.account.registerDevice(flags: flags, tokenType: mappedType, token: hexString(token), appSandbox: sandbox ? .boolTrue : .boolFalse, secret: Buffer(data: keyData), otherUids: otherAccountUserIds.map({ $0._internalGetInt64Value() })))
        |> map { result -> NotificationRegistrationResult in
            let outcome: NotificationRegistrationResult
            if case .boolTrue = result { outcome = .registered } else { outcome = .failed(code: "REGISTRATION_REJECTED", retryAfter: nil) }
            if mappedType != 9 { NotificationRegistrationDiagnostics.recordServerResult(accountId: account.id.int64, result: outcome.diagnostic) }
            return outcome
        }
        |> `catch` { error -> Signal<NotificationRegistrationResult, NoError> in
            let result = NotificationRegistrationResult.failure(code: error.errorDescription, status: error.errorCode)
            if mappedType != 9 { NotificationRegistrationDiagnostics.recordServerResult(accountId: account.id.int64, result: result.diagnostic) }
            return .single(result)
        }
    }
}
