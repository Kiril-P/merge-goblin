// swift-tools-version:5.9
import PackageDescription

// One executable target on purpose. The app is small, the tests reach into it with
// @testable, and a library/app split would mean marking every model `public` for no
// reader. Core/ is still the part with no AppKit in it: keep it that way.
let package = Package(
    name: "MergeGoblin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GoblinBar", targets: ["Goblin"]),
    ],
    targets: [
        .executableTarget(
            name: "Goblin",
            path: "Sources/Goblin",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "GoblinTests",
            dependencies: ["Goblin"],
            path: "tests/GoblinTests"
        ),
    ]
)
