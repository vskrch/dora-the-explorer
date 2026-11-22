// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Thumbnails",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "Thumbnails", targets: ["Thumbnails"]),
    ],
    dependencies: [
        .package(path: "../FSCore"),
    ],
    targets: [
        .target(
            name: "Thumbnails",
            dependencies: [.product(name: "FSCore", package: "FSCore")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
            ]
        ),
        .testTarget(
            name: "ThumbnailsTests",
            dependencies: ["Thumbnails"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
