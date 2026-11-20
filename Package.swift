// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LocalTeX",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "LocalTeX")],
    swiftLanguageModes: [.v5]
)
