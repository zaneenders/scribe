// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "scribe",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "scribe", targets: ["ScribeCLI"]),
    .executable(name: "scribe-mac", targets: ["ScribeMac"]),
    .library(name: "ScribeCore", targets: ["ScribeCore"]),
    .library(name: "ScribeKit", targets: ["ScribeKit"]),
  ],
  dependencies: [
    .package(url: "https://github.com/zaneenders/chroma", revision: "c01a148"),
    .package(url: "https://github.com/zaneenders/slate", revision: "b9e8dca"),
    .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
    .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-configuration", from: "1.0.0"),
    .package(
      url: "https://github.com/swiftlang/swift-subprocess.git",
      revision: "049ddf9",
      traits: ["SubprocessFoundation"]
    ),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-markdown.git", from: "0.6.0"),
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.4.1"),
    .package(url: "https://github.com/apple/swift-profile-recorder.git", .upToNextMinor(from: "0.3.13")),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
  ],
  targets: [
    .target(
      name: "ScribeLLM",
      dependencies: [
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ],
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    ),
    .target(
      name: "ScribeLLMCodex",
      dependencies: [
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ],
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    ),
    .target(
      name: "ScribeCodexAuth",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .target(
      name: "ScribeKit",
      dependencies: [
        "ScribeCore",
        "ScribeLLM",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "_NIOFileSystem", package: "swift-nio"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .target(
      name: "ScribeCore",
      dependencies: [
        "ScribeLLM",
        "ScribeLLMCodex",
        "ScribeCodexAuth",
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "Configuration", package: "swift-configuration"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "_NIOFileSystem", package: "swift-nio"),
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .executableTarget(
      name: "ScribeCLI",
      dependencies: [
        "ScribeCore",
        "ScribeCodexAuth",
        "ScribeKit",
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "Subprocess", package: "swift-subprocess"),
        .product(name: "SlateCore", package: "slate"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "Markdown", package: "swift-markdown"),
        .product(name: "_RopeModule", package: "swift-collections"),
        .product(name: "ProfileRecorderServer", package: "swift-profile-recorder"),
        .product(name: "_NIOFileSystem", package: "swift-nio"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
        .unsafeFlags(["-Xcc", "-fno-omit-frame-pointer"]),
      ],
      plugins: [
        "GitVersionPlugin"
      ]
    ),
    .executableTarget(
      name: "ScribeMac",
      dependencies: [
        "ScribeCore",
        "ScribeKit",
        .product(name: "Chroma", package: "chroma"),
        .product(name: "MetalBackend", package: "chroma"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ProfileRecorderServer", package: "swift-profile-recorder"),
        .product(name: "SystemPackage", package: "swift-system"),
      ],
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
      name: "ScribeCoreTests",
      dependencies: [
        "ScribeCore",
        "ScribeLLM",
        "ScribeLLMCodex",
        "ScribeCodexAuth",
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .testTarget(
      name: "ScribeCLITests",
      dependencies: [
        "ScribeCLI",
        "ScribeKit",
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
  ]
)
