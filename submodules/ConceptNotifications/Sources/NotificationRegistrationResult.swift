import Foundation

public enum NotificationRegistrationResult: Equatable {
    case registered
    case tokenInvalidated
    case failed(code: String, retryAfter: TimeInterval?)

    public static func failure(code: String, status: Int32) -> NotificationRegistrationResult {
        if code == "TOKEN_WAS_INVALIDATED" { return .tokenInvalidated }
        if code.hasPrefix("FLOOD_WAIT_"), let seconds = Double(code.dropFirst("FLOOD_WAIT_".count)), seconds > 0 {
            return .failed(code: code, retryAfter: min(86400.0, seconds))
        }
        if status >= 500 || status < 0 {
            return .failed(code: code, retryAfter: 1.0)
        }
        return .failed(code: code, retryAfter: nil)
    }

    public var diagnostic: String {
        switch self {
        case .registered: return "accepted"
        case .tokenInvalidated: return "TOKEN_WAS_INVALIDATED"
        case let .failed(code, _): return code
        }
    }
}
