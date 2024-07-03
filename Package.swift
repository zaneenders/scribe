// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [
        .macOS("14.0")
    ],
    dependencies: [
        // View documentation locally with the following command
        // swift package --disable-sandbox preview-documentation --target Scribe
        .package(
            url: "https://github.com/apple/swift-docc-plugin.git",
            from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "Scribe"),
        .testTarget(
            name: "ScribeTests",
            dependencies: ["Scribe"]),
    ]
)
