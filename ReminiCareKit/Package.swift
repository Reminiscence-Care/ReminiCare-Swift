// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReminiCareKit",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ReminiCareKit", targets: ["ReminiCareKit"]),
    ],
    targets: [
        .target(
            name: "ReminiCareKit",
            resources: [.copy("Resources/Topics"), .copy("Resources/HomeImage.png")]
        ),
        .testTarget(
            name: "ReminiCareKitTests",
            dependencies: ["ReminiCareKit"]
        ),
    ]
)
