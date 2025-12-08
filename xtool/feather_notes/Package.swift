// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "feather_notes",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "feather_notes",
            targets: ["feather_notes"]
        ),
    ],
    targets: [
        .target(
            name: "feather_notes"
        ),
    ]
)
