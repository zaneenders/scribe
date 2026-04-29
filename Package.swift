// swift-tools-version: 6.3
import PackageDescription

let package = Package(
  name: "Scribe",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .executable(name: "scribe", targets: ["ScribeCLI"]),
    .library(name: "ScribeCore", targets: ["ScribeCore"]),
    .library(name: "ScribeLLM", targets: ["ScribeLLM"]),
    .library(name: "ScribeTUI", targets: ["ScribeTUI"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
    .package(url: "https://github.com/swift-server/swift-openapi-async-http-client", from: "1.0.0"),
    .package(url: "https://github.com/apple/swift-system.git", from: "1.4.0"),
    .package(url: "https://github.com/apple/swift-configuration", from: "1.0.0"),
    .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.4.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
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
      name: "ScribeCore",
      dependencies: [
        "ScribeLLM",
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "SystemPackage", package: "swift-system"),
        .product(name: "Configuration", package: "swift-configuration"),
        .product(name: "Subprocess", package: "swift-subprocess"),
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .target(
      name: "ScribeTUI",
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
    .executableTarget(
      name: "ScribeCLI",
      dependencies: [
        "ScribeCore",
        "ScribeTUI",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6),
        .treatAllWarnings(as: .error),
      ]
    ),
  ]
)
