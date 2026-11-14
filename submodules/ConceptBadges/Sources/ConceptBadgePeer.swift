import TelegramCore

public extension EnginePeer.Id {
    /// The numeric user form stays compatible with existing assignments. Groups
    /// and channels occupy separate namespaces, including anonymous send-as peers.
    var conceptBadgeKey: String? {
        let id = self.id._internalGetInt64Value()
        guard id > 0 && id < 1 << 52 else { return nil }
        switch self.namespace {
        case Namespaces.Peer.CloudUser: return String(id)
        case Namespaces.Peer.CloudGroup: return "group:\(id)"
        case Namespaces.Peer.CloudChannel: return "channel:\(id)"
        default: return nil
        }
    }
}
