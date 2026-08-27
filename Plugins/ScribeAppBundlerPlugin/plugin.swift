import Foundation
import PackagePlugin

@main
struct ScribeAppBundlerPlugin: CommandPlugin {
  func performCommand(context: PluginContext, arguments: [String]) async throws {
    #if !os(macOS)
    throw BundlerError.unsupportedPlatform
    #else
    let packageDirectory = context.package.directoryURL
    let outputURL = URL(fileURLWithPath: "dist/Scribe.app", relativeTo: packageDirectory)
      .standardizedFileURL
    let configuration = PackageManager.BuildConfiguration.release

    Diagnostics.remark("Building products (\(configuration.rawValue))…")
    let build = try packageManager.build(
      .all(includingTests: false),
      parameters: .init(configuration: configuration, logging: .concise)
    )
    guard build.succeeded else {
      throw BundlerError.buildFailed(log: build.logText)
    }

    guard let macBinary = Self.executable(named: "scribe-mac", in: build.builtArtifacts) else {
      throw BundlerError.missingArtifact("scribe-mac")
    }
    guard let cliBinary = Self.executable(named: "scribe", in: build.builtArtifacts) else {
      throw BundlerError.missingArtifact("scribe")
    }

    let packagingDirectory = packageDirectory.appendingPathComponent("Packaging", isDirectory: true)
    let infoPlist = packagingDirectory.appendingPathComponent("Info.plist")
    let appIcon = packagingDirectory.appendingPathComponent("AppIcon.icns")
    guard FileManager.default.fileExists(atPath: infoPlist.path) else {
      throw BundlerError.missingResource("Packaging/Info.plist")
    }
    guard FileManager.default.fileExists(atPath: appIcon.path) else {
      throw BundlerError.missingResource("Packaging/AppIcon.icns")
    }

    let contentsURL = outputURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    let helpersURL = contentsURL.appendingPathComponent("Helpers", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)

    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    for directory in [macOSURL, helpersURL, resourcesURL] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    try Self.installExecutable(from: macBinary, to: macOSURL.appendingPathComponent("scribe-mac"))
    try Self.installExecutable(from: cliBinary, to: helpersURL.appendingPathComponent("scribe"))
    try FileManager.default.copyItem(at: infoPlist, to: contentsURL.appendingPathComponent("Info.plist"))
    try FileManager.default.copyItem(at: appIcon, to: resourcesURL.appendingPathComponent("AppIcon.icns"))

    Diagnostics.remark("Signing embedded CLI…")
    try Self.run(
      "/usr/bin/codesign",
      arguments: ["--force", "--sign", "-", helpersURL.appendingPathComponent("scribe").path]
    )
    Diagnostics.remark("Signing app bundle…")
    try Self.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", outputURL.path])
    Diagnostics.remark("Verifying app signature…")
    try Self.run(
      "/usr/bin/codesign",
      arguments: ["--verify", "--deep", "--strict", "--verbose=2", outputURL.path]
    )

    Diagnostics.remark("Created \(outputURL.path)")
    #endif
  }

  #if os(macOS)
  private static func executable(
    named name: String,
    in artifacts: [PackageManager.BuildResult.BuiltArtifact]
  ) -> URL? {
    artifacts.first {
      $0.kind == .executable && $0.url.lastPathComponent == name
    }?.url
  }

  private static func installExecutable(from source: URL, to destination: URL) throws {
    try FileManager.default.copyItem(at: source, to: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
  }

  private static func run(_ executable: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw BundlerError.commandFailed(executable: executable, status: process.terminationStatus)
    }
  }
  #endif
}

private enum BundlerError: Error, CustomStringConvertible {
  case unsupportedPlatform
  case buildFailed(log: String)
  case missingArtifact(String)
  case missingResource(String)
  case commandFailed(executable: String, status: Int32)

  var description: String {
    switch self {
    case .unsupportedPlatform:
      "Scribe.app bundling is only supported on macOS."
    case .buildFailed(let log):
      "Failed to build products.\n\(log)"
    case .missingArtifact(let name):
      "Could not find built executable for product \(name)."
    case .missingResource(let path):
      "Missing required packaging resource at \(path)."
    case .commandFailed(let executable, let status):
      "\(executable) failed with status \(status)."
    }
  }
}
