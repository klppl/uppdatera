// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Uppdatera",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Uppdatera", targets: ["Uppdatera"]),
    ],
    targets: [
        .target(name: "UppdateraCore"),
        .executableTarget(name: "Uppdatera", dependencies: ["UppdateraCore"]),
        .testTarget(name: "UppdateraCoreTests", dependencies: ["UppdateraCore"]),
    ]
)
