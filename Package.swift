// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacOSFileEditor",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FileEditor", targets: ["EditorApp"])],
    dependencies: [],
    targets: [
        .target(name: "EditorCore"),
        .executableTarget(name: "EditorApp", dependencies: ["EditorCore"]),
        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "EditorAppTests", dependencies: ["EditorApp", "EditorCore"])
    ],
    swiftLanguageVersions: [.v5]
)
