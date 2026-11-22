// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Archives",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Archives", targets: ["Archives"]),
    ],
    dependencies: [
        .package(path: "../FSCore"),
    ],
    targets: [
        .target(
            name: "Archives",
            dependencies: [.product(name: "FSCore", package: "FSCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ArchivesTests",
            dependencies: ["Archives"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
