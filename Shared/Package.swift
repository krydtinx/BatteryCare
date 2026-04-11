// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryCareShared",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BatteryCareShared", targets: ["BatteryCareShared"])
    ],
    targets: [
        .target(name: "BatteryCareShared", path: "Sources/BatteryCareShared")
    ]
)
