// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "apfel",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        // Pure-logic library — no FoundationModels, testable
        .target(
            name: "ApfelCore",
            dependencies: [],
            path: "Sources/Core"
        ),
        // Main executable — depends on ApfelCore + Hummingbird + FoundationModels
        .executableTarget(
            name: "apfel",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                "ApfelCore",
            ],
            path: "Sources",
            exclude: ["Core"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "./Info.plist",
                ])
            ]
        ),
        // Test runner — pure Swift, no XCTest/Testing (Command Line Tools only)
        .executableTarget(
            name: "apfel-tests",
            dependencies: ["ApfelCore"],
            path: "Tests/apfelTests"
        ),
    ]
)
