// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppCore", targets: ["AppCore"]),
    ],
    dependencies: [
        .package(path: "../FSCore"),
    ],
    targets: [
        .target(
            name: "AppCore",
            dependencies: [.product(name: "FSCore", package: "FSCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
