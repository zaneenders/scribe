// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "scribe",
    dependencies: [
        /*
        swift package --disable-sandbox preview-documentation --target Scribe
        */
        .package(
            url: "https://github.com/apple/swift-docc-plugin.git",
            from: "1.3.0")
    ],
    targets: [
        .target(name: "Scribe"),
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
