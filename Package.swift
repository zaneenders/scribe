// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scribe",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "scribe", targets: ["MyScribe"])
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
        .package(
            url: "https://github.com/swiftlang/swift-format.git",
            from: "600.0.0"
        ),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),

    ],
    targets: [
        .target(
            name: "Scribe",
            dependencies: [
                .product(name: "_NIOFileSystem", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ]),
        .executableTarget(
            name: "MyScribe",
            dependencies: [
                "MyConfig",
                "Scribe",
                .product(name: "SwiftFormat", package: "swift-format"),
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
