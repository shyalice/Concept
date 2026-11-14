// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "ConceptBadgeCatalog", platforms: [.macOS(.v13)], targets: [
    .target(name: "ConceptBadgeCatalog", path: "Sources", exclude: ["ConceptBadgeService.swift", "ConceptBadgePeer.swift", "ConceptBadgeView.swift"]),
    .testTarget(name: "ConceptBadgeCatalogTests", dependencies: ["ConceptBadgeCatalog"], path: "Tests")
])
