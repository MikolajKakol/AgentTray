// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "AgentTrayCore", targets: ["AgentTrayCore"]),
]

var targets: [Target] = [
    .target(name: "AgentTrayCore"),
    .testTarget(name: "AgentTrayCoreTests", dependencies: ["AgentTrayCore"]),
]

// The menu bar app needs SwiftUI/AppKit, so it only exists on macOS.
// On other platforms the package still builds and tests the core library.
#if os(macOS)
products.append(.executable(name: "AgentTray", targets: ["AgentTray"]))
targets.append(.executableTarget(name: "AgentTray", dependencies: ["AgentTrayCore"]))
#endif

let package = Package(
    name: "AgentTray",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
