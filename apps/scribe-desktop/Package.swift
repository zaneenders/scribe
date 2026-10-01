// swift-tools-version: 6.4
import PackageDescription

var products: [Product] = []
var targets: [Target] = [
  .target(
    name: "ScribeBlocks",
    dependencies: [
      .product(name: "ScribeCore", package: "scribe"),
      .product(name: "ScribeKit", package: "scribe"),
      .product(name: "ScribeCodexAuth", package: "scribe"),
      .product(name: "Chroma", package: "chroma"),
      .product(name: "Logging", package: "swift-log"),
      .product(name: "ProfileRecorderServer", package: "swift-profile-recorder"),
      .product(name: "SystemPackage", package: "swift-system"),
    ],
    path: "Sources/ScribeMac",
    swiftSettings: [
      .swiftLanguageMode(.v6),
      .treatAllWarnings(as: .error),
      .unsafeFlags(["-Xcc", "-fno-omit-frame-pointer"]),
    ],
    plugins: [
      "GitVersionPlugin"
    ]
  ),
  .testTarget(
    name: "ScribeBlocksTests",
    dependencies: [
      "ScribeBlocks",
      .product(name: "ChromaTesting", package: "chroma"),
    ],
    swiftSettings: [
      .swiftLanguageMode(.v6),
      .treatAllWarnings(as: .error),
    ]
  ),
  .plugin(
    name: "GitVersionPlugin",
    capability: .buildTool()
  ),
  .plugin(
    name: "ScribeAppBundlerPlugin",
    capability: .command(
      intent: .custom(
        verb: "bundle",
        description: "Build Scribe.app from the scribe-mac executable"
      ),
      permissions: [
        .writeToPackageDirectory(
          reason: "Writes the assembled Scribe.app bundle under the package directory"
        )
      ]
    )
  ),
]

#if os(macOS)
products.append(.executable(name: "scribe-mac", targets: ["ScribeMac"]))
targets.append(.testTarget(name: "ScribeMacLaunchTests", dependencies: ["ScribeMac", "ScribeBlocks"]))
targets.append(
  .executableTarget(
    name: "ScribeMac",
    dependencies: [
      "ScribeBlocks",
      .product(name: "Chroma", package: "chroma"),
      .product(name: "MetalBackend", package: "chroma"),
    ],
    path: "Sources/ScribeMacApp",
    swiftSettings: [
      .swiftLanguageMode(.v6),
      .treatAllWarnings(as: .error),
    ]
  )
)
#elseif os(Linux)
products.append(.executable(name: "scribe-wayland", targets: ["ScribeWayland"]))
targets.append(
  .executableTarget(
    name: "ScribeWayland",
    dependencies: [
      "ScribeBlocks",
      .product(name: "Chroma", package: "chroma"),
      .product(name: "WaylandBackend", package: "chroma"),
    ],
    path: "Sources/ScribeWaylandApp",
    swiftSettings: [
      .swiftLanguageMode(.v6),
      .treatAllWarnings(as: .error),
    ]
  )
)
#endif

let package = Package(
  name: "scribe-desktop",
  platforms: [.macOS(.v27)],
  products: products,
  dependencies: [
    .package(path: "../.."),
    .package(url: "https://github.com/zaneenders/chroma", revision: "22e85af08e2913f2b9653b99dda1d6832bf4cdcb"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-profile-recorder.git", .upToNextMinor(from: "0.3.13")),
  ],
  targets: targets
)
