// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftFirmataIR",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "SwiftFirmataIR", targets: ["SwiftFirmataIR"]),
    ],
    dependencies: [
        // The core client. For local co-development against a checkout, swap this for
        // `.package(path: "../SwiftFirmataClient")`.
        .package(url: "https://github.com/doraorak/SwiftFirmataClient.git", from: "14.6.0"),
    ],
    targets: [
        .target(
            name: "SwiftFirmataIR",
            dependencies: [
                .product(name: "SwiftFirmataClient", package: "SwiftFirmataClient"),
            ]
        ),
        .testTarget(
            name: "SwiftFirmataIRTests",
            dependencies: ["SwiftFirmataIR"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
