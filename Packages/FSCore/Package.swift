// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FSCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FSCore", targets: ["FSCore"]),
    ],
    targets: [
        .target(
            name: "FSCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "FSCoreTests",
            dependencies: ["FSCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
