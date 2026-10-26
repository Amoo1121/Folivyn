// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Folivyn",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Folivyn", targets: ["EditorApp"])],
    dependencies: [],
    targets: [
        .target(name: "EditorCore", resources: [.process("Resources")]),
        .executableTarget(name: "EditorApp", dependencies: ["EditorCore"], resources: [.process("Resources")]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "EditorAppTests", dependencies: ["EditorApp", "EditorCore"])
    ],
    swiftLanguageVersions: [.v5]
)
