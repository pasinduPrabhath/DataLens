// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DataLens",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DataLens",
            path: "Sources/DataLens",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
