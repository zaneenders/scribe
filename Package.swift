// swift-tools-version: 6.4
import PackageDescription

let products: [Product] = [
  .library(name: "ScribeCodexAuth", targets: ["ScribeCodexAuth"]),
  .library(name: "ScribeCore", targets: ["ScribeCore"]),
  .library(name: "ScribeKit", targets: ["ScribeKit"]),
]

let targets: [Target] = [
  .target(
    name: "ScribeLLM",
    dependencies: [
      .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
    ],
    swiftSettings: [
      .swiftLanguageMode(.v6),
    ],
    plugins: [
      .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
    ]
  ),
  .target(
    name: "ScribeLLMResponses",
    dependencies: [
      "ScribeCodexAuth",
      .product(name: "AsyncHTTPClient", package: "async-http-client"),
      .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      .product(name: "OpenAPIAsyncHTTPClient", package: "swift-openapi-async-http-client"),
    ],
    swiftSettings: [
      .swiftLanguageMode(.v6),
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
      "ScribeCodexAuth",
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
      "ScribeLLMResponses",
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
  .testTarget(
    name: "ScribeCoreTests",
    dependencies: [
      "ScribeCore",
      "ScribeLLM",
      "ScribeLLMResponses",
      "ScribeCodexAuth",
    ],
    swiftSettings: [
      .swiftLanguageMode(.v6),
      .treatAllWarnings(as: .error),
    ]
  ),
  .testTarget(
    name: "ScribeKitTests",
    dependencies: [
      "ScribeKit",
      "ScribeCore",
      "ScribeLLM",
    ],
    swiftSettings: [
      .swiftLanguageMode(.v6),
      .treatAllWarnings(as: .error),
    ]
  ),
]

let package = Package(
  name: "scribe",
  platforms: [
    .macOS(.v27)
  ],
  products: products,
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
    .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-configuration", from: "1.0.0"),
    .package(
      url: "https://github.com/swiftlang/swift-subprocess.git",
      from: "1.0.0",
      traits: ["SubprocessFoundation"]
    ),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.10.0"),
    .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.24.0"),
  ],
  targets: targets
)
