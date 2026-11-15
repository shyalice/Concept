import Foundation

/// A readable file inside the app container needs no security-scoped grant.
final class ICloudFileAccess {
    let url: URL
    private let hasSecurityScope: Bool

    init?(url: URL) {
        guard url.isFileURL else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        guard scoped || FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        self.url = url
        self.hasSecurityScope = scoped
    }

    deinit {
        if self.hasSecurityScope { self.url.stopAccessingSecurityScopedResource() }
    }
}
