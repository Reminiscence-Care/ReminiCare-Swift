// swift-tools-version: 6.0

// Used only by xtool (`xtool dev`) to build and install the app without Xcode,
// e.g. from Linux/WSL. Xcode and CI use ReminiCare.xcodeproj instead.

import PackageDescription

let package = Package(
    name: "ReminiCare",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        // xtool expects exactly one library product: the app.
        .library(name: "ReminiCare", targets: ["ReminiCare"]),
    ],
    dependencies: [
        .package(path: "ReminiCareKit"),
    ],
    targets: [
        .target(
            name: "ReminiCare",
            dependencies: [.product(name: "ReminiCareKit", package: "ReminiCareKit")],
            path: "ReminiCare",
            // Asset catalogs need actool (macOS only); the app icon comes from xtool.yml.
            exclude: ["Assets.xcassets"]
        ),
    ]
)
