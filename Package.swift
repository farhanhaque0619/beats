// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Bassline",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Bassline",
            path: "Sources/Bassline"
        )
    ]
)
