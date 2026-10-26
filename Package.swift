// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Folivyn",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Folivyn", targets: ["EditorApp"]),
        .library(name: "PreviewSupport", type: .static, targets: ["EditorCore", "EditorUI"])
    ],
    dependencies: [],
    targets: [
        .target(name: "EditorCore", resources: [.process("Resources")]),
        .target(name: "EditorUI", resources: [.process("Resources")]),
        .executableTarget(name: "EditorApp", dependencies: ["EditorCore", "EditorUI"]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "EditorAppTests", dependencies: ["EditorApp", "EditorCore", "EditorUI"])
    ],
    swiftLanguageVersions: [.v5]
)
