// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vid2GIF",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vid2GIF",
            path: "Sources/Vid2GIF",
            resources: [.copy("Icons")]
        ),
        .testTarget(name: "Vid2GIFTests", dependencies: ["Vid2GIF"])
    ]
)
