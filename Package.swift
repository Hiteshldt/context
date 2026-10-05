// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Context",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Context", targets: ["Context"])],
    targets: [
        .executableTarget(name: "Context")
    ]
)
