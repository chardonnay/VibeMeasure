// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeMeasureMac",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "VibeMeasureMac", targets: ["VibeMeasureMac"])
    ],
    targets: [
        .executableTarget(
            name: "VibeMeasureMac",
            path: "VibeMeasureMac/Sources/VibeMeasureMac"
        ),
        .testTarget(
            name: "VibeMeasureMacTests",
            dependencies: ["VibeMeasureMac"],
            path: "VibeMeasureMac/Tests/VibeMeasureMacTests"
        )
    ]
)
