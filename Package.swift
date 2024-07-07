// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [
        .macOS("14.0")
    ],
    products: [
        .library(name: "ScribeCore", targets: ["ScribeCore"])
    ],
    dependencies: [
        /*
        Below are Package dependencies but not for output. Comment out if not
        needed for faster build times.
        */
        .package(
            url: "https://github.com/apple/swift-format.git",
            from: "510.1.0"),
        // View documentation locally with the following command
        // swift package --disable-sandbox preview-documentation --target ScribeCore
        .package(
            url: "https://github.com/apple/swift-docc-plugin.git",
            from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ScribeCore"),
        .testTarget(
            name: "ScribeCoreTests",
            dependencies: ["ScribeCore"]),
    ]
)
