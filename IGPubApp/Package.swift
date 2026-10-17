// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IGPub",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IGPubCore"),
        .executableTarget(name: "IGPubApp", dependencies: ["IGPubCore"]),
        .testTarget(name: "IGPubCoreTests", dependencies: ["IGPubCore"]),
    ]
)
