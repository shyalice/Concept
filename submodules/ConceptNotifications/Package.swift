// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConceptNotifications",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ConceptNotifications", targets: ["ConceptNotifications"])],
    dependencies: [.package(path: "../SSignalKit")],
    targets: [
        .target(name: "ConceptNotifications", dependencies: [.product(name: "SwiftSignalKit", package: "SSignalKit")]),
        .testTarget(name: "ConceptNotificationsTests", dependencies: ["ConceptNotifications", .product(name: "SwiftSignalKit", package: "SSignalKit")], path: "Tests")
    ]
)
