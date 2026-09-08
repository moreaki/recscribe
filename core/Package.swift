// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RecScribeCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RecScribeCore", targets: ["RecScribeCore"]),
        .executable(name: "recscribe-text", targets: ["RecScribeTextCLI"])
    ],
    targets: [
        .target(name: "RecScribeCore", resources: [.copy("Resources/transcript.schema.json"), .copy("Resources/transcript-v1.1.schema.json")]),
        .executableTarget(name: "RecScribeTextCLI", dependencies: ["RecScribeCore"]),
        .testTarget(name: "RecScribeCoreTests", dependencies: ["RecScribeCore"])
    ]
)
