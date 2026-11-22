// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShellIntegration",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "ShellIntegration", targets: ["ShellIntegration"]),
    ],
    dependencies: [
        .package(path: "../FSCore"),
    ],
    targets: [
        .target(
            name: "ShellIntegration",
            dependencies: [.product(name: "FSCore", package: "FSCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ShellIntegrationTests",
            dependencies: ["ShellIntegration"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
