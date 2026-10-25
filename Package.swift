// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "QuickNoteSearch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "QuickNoteSearch", path: "Sources/QuickNoteSearch"),
        .testTarget(name: "QuickNoteSearchTests", dependencies: ["QuickNoteSearch"], path: "Tests/QuickNoteSearchTests"),
    ]
)
