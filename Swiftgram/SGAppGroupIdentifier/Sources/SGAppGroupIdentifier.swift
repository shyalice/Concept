import Foundation

public let FALLBACK_BASE_BUNDLE_ID: String = "kill.myself.Concept"

private let extensionBundleSuffixes: [String] = [
    ".watchkitapp.watchkitextension",
    ".SGActionRequestHandler",
    ".NotificationContent",
    ".NotificationService",
    ".BroadcastUpload",
    ".SiriIntents",
    ".Share",
    ".Widget"
]

private struct SignedAppGroupInformation {
    let identifiers: [String]
    let containerUrls: [String: URL]
}

private func signedAppGroupInformation() -> SignedAppGroupInformation {
    guard let proxyClass = NSClassFromString("LSBundleProxy") as? NSObject.Type,
          let proxy = proxyClass.perform(NSSelectorFromString("bundleProxyForCurrentProcess"))?.takeUnretainedValue() as? NSObject else {
        return SignedAppGroupInformation(identifiers: [], containerUrls: [:])
    }

    var identifiers: [String] = []
    if proxy.responds(to: NSSelectorFromString("entitlements")),
       let entitlements = proxy.perform(NSSelectorFromString("entitlements"))?.takeUnretainedValue() as? [String: Any],
       let value = entitlements["com.apple.security.application-groups"] {
        if let array = value as? [String] {
            identifiers = array
        } else if let identifier = value as? String {
            identifiers = [identifier]
        }
    }

    var containerUrls: [String: URL] = [:]
    if proxy.responds(to: NSSelectorFromString("groupContainerURLs")),
       let values = proxy.perform(NSSelectorFromString("groupContainerURLs"))?.takeUnretainedValue() as? [String: URL] {
        containerUrls = values
    }

    return SignedAppGroupInformation(identifiers: identifiers, containerUrls: containerUrls)
}

private func embeddedProvisioningAppGroupIdentifiers() -> [String] {
    guard let profileUrl = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let profileData = try? Data(contentsOf: profileUrl),
          let profileString = String(data: profileData, encoding: .isoLatin1),
          let plistStart = profileString.range(of: "<?xml"),
          let plistEnd = profileString.range(of: "</plist>", options: [], range: plistStart.lowerBound ..< profileString.endIndex) else {
        return []
    }

    let plistString = String(profileString[plistStart.lowerBound ..< plistEnd.upperBound])
    guard let plistData = plistString.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
          let dictionary = plist as? [String: Any],
          let entitlements = dictionary["Entitlements"] as? [String: Any],
          let identifiers = entitlements["com.apple.security.application-groups"] as? [String] else {
        return []
    }

    return identifiers
}

public func sgBaseBundleIdentifier() -> String {
    guard let bundleId = Bundle.main.bundleIdentifier else {
        return FALLBACK_BASE_BUNDLE_ID
    }

    if Bundle.main.bundlePath.hasSuffix(".appex") {
        for suffix in extensionBundleSuffixes where bundleId.hasSuffix(suffix) {
            return String(bundleId.dropLast(suffix.count))
        }

        if let lastDotRange = bundleId.range(of: ".", options: [.backwards]) {
            return String(bundleId[..<lastDotRange.lowerBound])
        }
    }

    return bundleId
}

public func sgAppGroupIdentifiers() -> [String] {
    var result: [String] = []
    let candidates = signedAppGroupInformation().identifiers + embeddedProvisioningAppGroupIdentifiers() + [
        "group.\(sgBaseBundleIdentifier())",
        "group.ph.telegra.Telegraph",
        "group.app.swiftgram.ios"
    ]

    for identifier in candidates where !identifier.isEmpty && !result.contains(identifier) {
        result.append(identifier)
    }

    return result
}

public func sgAppGroupContainerURL() -> URL? {
    let signedInformation = signedAppGroupInformation()
    let identifiers = sgAppGroupIdentifiers()

    for identifier in identifiers {
        if let url = signedInformation.containerUrls[identifier] {
            return url
        }
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return url
        }
    }

    return nil
}

public func sgAppGroupIdentifier() -> String {
    let signedInformation = signedAppGroupInformation()
    let identifiers = sgAppGroupIdentifiers()
    for identifier in identifiers {
        if signedInformation.containerUrls[identifier] != nil {
            return identifier
        }
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) != nil {
            return identifier
        }
    }
    return identifiers.first ?? "group.\(FALLBACK_BASE_BUNDLE_ID)"
}
