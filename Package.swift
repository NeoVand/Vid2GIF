// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vid2GIF",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Vid2GIF",
            path: "Sources/Vid2GIF"
        )
    ]
)
