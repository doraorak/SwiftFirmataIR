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
        // The core client (register file / repeat op live here).
        .package(url: "https://github.com/doraorak/SwiftFirmataClient.git", from: "16.0.0"),
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
