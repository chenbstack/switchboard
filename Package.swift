// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwitchBoard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SwitchBoard", path: "Sources/SwitchBoard")
    ]
)
