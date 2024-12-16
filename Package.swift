// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [
        .macOS("15.0")
    ],
    dependencies: [
        /*
        swift package --disable-sandbox preview-documentation --target Scribe
        */
        .package(
            url: "https://github.com/apple/swift-docc-plugin.git",
            from: "1.3.0"),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.77.0"
        ),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.2"),
    ],
    targets: [
        .target(
            name: "Scribe",
            dependencies: [
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .executableTarget(
            name: "MyScribe",
            dependencies: [
                "MyConfig",
                "Scribe",
            ]),
        .target(
            name: "MyConfig",
            dependencies: ["Scribe"]),
        .testTarget(
            name: "ScribeTests",
            dependencies: [
                "MyScribe",
                "Scribe",
            ]),
    ]
)
