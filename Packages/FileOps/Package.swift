// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileOps",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FileOps", targets: ["FileOps"]),
    ],
    dependencies: [
        .package(path: "../FSCore"),
    ],
    targets: [
        .target(
            name: "FileOps",
            dependencies: [.product(name: "FSCore", package: "FSCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "FileOpsTests",
            dependencies: ["FileOps"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
