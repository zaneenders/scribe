import Foundation
import PackagePlugin

/// Explicit maintainer workflow for refreshing the checked-in libghostty-vt
/// binary and headers. This is intentionally a command plugin rather than a
/// build-tool plugin: normal Scribe builds remain offline and do not require
/// Zig, Git, or a lengthy native dependency build.
@main
struct GhosttyVtRefreshPlugin: CommandPlugin {
  private let repository = "https://github.com/ghostty-org/ghostty.git"
  // Keep this immutable and review upgrades deliberately alongside the C API.
  private let revision = "7e3ddc2c891b1076caa235de9681a9b598bc3546"
  private let minimumZig = Version(0, 16, 0)

  func performCommand(context: PluginContext, arguments: [String]) async throws {
    let options = try Options(arguments: arguments)
    let package = context.package.directoryURL
    let vendor = package.appendingPathComponent("Vendor/GhosttyVt", isDirectory: true)
    let fileManager = FileManager.default

    let localZig = package.appendingPathComponent(
      "Vendor/.tools/zig-\(minimumZig.description)/zig")
    guard let zig = findExecutable("zig", extraPaths: [localZig.path]) else {
      throw RefreshError.missingZig(minimumZig.description)
    }
    let installedZig = try Version(Self.capture(zig, ["version"]).trimmingCharacters(in: .whitespacesAndNewlines))
    guard installedZig >= minimumZig else {
      throw RefreshError.oldZig(found: installedZig.description, required: minimumZig.description)
    }

    let work = context.pluginWorkDirectoryURL.appendingPathComponent("ghostty-vt-refresh", isDirectory: true)
    if fileManager.fileExists(atPath: work.path) { try fileManager.removeItem(at: work) }
    try fileManager.createDirectory(at: work, withIntermediateDirectories: true)

    let source = options.source.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? package.appendingPathComponent("Vendor/GhosttySource", isDirectory: true)
    guard fileManager.fileExists(atPath: source.appendingPathComponent("build.zig").path) else {
      throw RefreshError.invalidSource(
        source.path + " (initialize it with `git submodule update --init --recursive`)")
    }

    let sourceRevision = Self.gitRevision(at: source) ?? "local-source"
    if sourceRevision != revision {
      Diagnostics.warning(
        "Ghostty checkout is at \(sourceRevision), while the reviewed revision is \(revision). " +
          "Review C API and license changes before committing the result.")
    }
    let outputLibrary: URL
    let platform: String

    #if os(macOS)
    platform = "macos-universal"
    guard let lipo = findExecutable("lipo", extraPaths: ["/usr/bin/lipo"]) else {
      throw RefreshError.missingTool("lipo")
    }
    let arm = try build(
      zig: zig, source: source, work: work,
      target: "aarch64-macos", name: "arm64")
    let intel = try build(
      zig: zig, source: source, work: work,
      target: "x86_64-macos", name: "x86_64")
    outputLibrary = work.appendingPathComponent("libghostty-vt.a")
    try Self.run(lipo, ["-create", arm.path, intel.path, "-output", outputLibrary.path])
    let architectures = try Self.capture(lipo, ["-archs", outputLibrary.path])
    guard architectures.contains("arm64"), architectures.contains("x86_64") else {
      throw RefreshError.verificationFailed("universal archive reports: \(architectures)")
    }
    #elseif os(Linux)
    platform = "linux-\(Self.hostArchitecture())"
    outputLibrary = try build(zig: zig, source: source, work: work, target: nil, name: "linux")
    #else
    throw RefreshError.unsupportedPlatform
    #endif

    let stagedHeaders = work.appendingPathComponent("Headers", isDirectory: true)
    try fileManager.createDirectory(at: stagedHeaders, withIntermediateDirectories: true)
    try Self.copyTree(
      from: source.appendingPathComponent("include/ghostty", isDirectory: true),
      to: stagedHeaders.appendingPathComponent("ghostty", isDirectory: true))
    // Upstream's module map exposes the full macOS application API as
    // `GhosttyKit`. Scribe deliberately exposes only libghostty-vt.
    try "module GhosttyVt {\n    umbrella header \"ghostty/vt.h\"\n    export *\n}\n"
      .write(to: stagedHeaders.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

    guard fileManager.fileExists(atPath: stagedHeaders.appendingPathComponent("ghostty/vt.h").path) else {
      throw RefreshError.verificationFailed("upstream public headers were not found")
    }

    let destinationLibrary: URL
    #if os(macOS)
    destinationLibrary = vendor.appendingPathComponent("Libraries/macos/libghostty-vt.a")
    #else
    destinationLibrary = vendor.appendingPathComponent("Libraries/linux/libghostty-vt.a")
    #endif

    if options.dryRun {
      Diagnostics.remark("Verified \(platform) libghostty-vt; --dry-run left Vendor unchanged")
      return
    }

    try fileManager.createDirectory(
      at: destinationLibrary.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fileManager.fileExists(atPath: destinationLibrary.path) {
      try fileManager.removeItem(at: destinationLibrary)
    }
    try fileManager.copyItem(at: outputLibrary, to: destinationLibrary)

    let destinationHeaders = vendor.appendingPathComponent("Headers", isDirectory: true)
    if fileManager.fileExists(atPath: destinationHeaders.path) {
      try fileManager.removeItem(at: destinationHeaders)
    }
    try fileManager.copyItem(at: stagedHeaders, to: destinationHeaders)

    let upstreamLicense = source.appendingPathComponent("LICENSE")
    if fileManager.fileExists(atPath: upstreamLicense.path) {
      let destinationLicense = vendor.appendingPathComponent("LICENSE")
      if fileManager.fileExists(atPath: destinationLicense.path) {
        try fileManager.removeItem(at: destinationLicense)
      }
      try fileManager.copyItem(at: upstreamLicense, to: destinationLicense)
    }

    let checksumTool: (URL, [String])
    if let shasum = findExecutable("shasum", extraPaths: ["/usr/bin/shasum"]) {
      checksumTool = (shasum, ["-a", "256", destinationLibrary.path])
    } else if let sha256sum = findExecutable("sha256sum", extraPaths: ["/usr/bin/sha256sum"]) {
      checksumTool = (sha256sum, [destinationLibrary.path])
    } else {
      throw RefreshError.missingTool("shasum or sha256sum")
    }
    let checksum = try Self.capture(checksumTool.0, checksumTool.1)
      .split(separator: " ").first.map(String.init) ?? "unknown"
    let provenance = """
    # Generated libghostty-vt provenance

    repository: \(repository)
    revision: \(sourceRevision)
    zig: \(installedZig)
    optimize: ReleaseFast
    platform: \(platform)
    library: \(destinationLibrary.path.replacingOccurrences(of: package.path + "/", with: ""))
    sha256: \(checksum)

    """
    try provenance.write(
      to: vendor.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
    Diagnostics.remark("Updated \(destinationLibrary.path)")
  }

  private func build(
    zig: URL, source: URL, work: URL, target: String?, name: String
  ) throws -> URL {
    let prefix = work.appendingPathComponent("install-\(name)", isDirectory: true)
    var arguments = [
      "build", "-Demit-lib-vt=true", "-Doptimize=ReleaseFast",
      "--prefix", prefix.path,
    ]
    if let target { arguments.append("-Dtarget=\(target)") }
    Diagnostics.remark("Building libghostty-vt (\(target ?? "native"))…")
    let cache = work.appendingPathComponent("zig-cache-\(name)", isDirectory: true)
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    try Self.run(
      zig, arguments, currentDirectory: source,
      environment: [
        "ZIG_GLOBAL_CACHE_DIR": cache.appendingPathComponent("global").path,
        "ZIG_LOCAL_CACHE_DIR": cache.appendingPathComponent("local").path,
      ])
    let result = prefix.appendingPathComponent("lib/libghostty-vt.a")
    guard FileManager.default.fileExists(atPath: result.path) else {
      throw RefreshError.missingBuildOutput(result.path)
    }
    return result
  }

  private func findExecutable(_ name: String, extraPaths: [String] = []) -> URL? {
    for path in extraPaths {
      let direct = URL(fileURLWithPath: path)
      if FileManager.default.isExecutableFile(atPath: direct.path) { return direct }
      let nested = direct.appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: nested.path) { return nested }
    }
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
      .split(separator: ":").map(String.init)
    for path in paths {
      let candidate = URL(fileURLWithPath: path).appendingPathComponent(name)
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
  }

  private static func run(
    _ executable: URL,
    _ arguments: [String],
    currentDirectory: URL? = nil,
    environment: [String: String] = [:]
  ) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw RefreshError.commandFailed(executable.path, process.terminationStatus)
    }
  }

  private static func capture(_ executable: URL, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.standardError
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw RefreshError.commandFailed(executable.path, process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func gitRevision(at source: URL) -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", source.path, "rev-parse", "HEAD"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func copyTree(from source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    guard let enumerator = fileManager.enumerator(
      at: source, includingPropertiesForKeys: [.isDirectoryKey])
    else { throw RefreshError.invalidSource(source.path) }
    while let item = enumerator.nextObject() as? URL {
      let relative = item.path.replacingOccurrences(of: source.path + "/", with: "")
      let target = destination.appendingPathComponent(relative)
      let isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
      if isDirectory {
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
      } else {
        try fileManager.copyItem(at: item, to: target)
      }
    }
  }

  private static func hostArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
  }
}

private struct Options {
  var source: String?
  var dryRun = false

  init(arguments: [String]) throws {
    var parsedSource: String?

    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--source":
        guard let path = iterator.next() else { throw RefreshError.missingArgument("--source") }
        parsedSource = path
      case "--dry-run": dryRun = true
      case "--help", "-h":
        Diagnostics.remark(
          "Usage: swift package refresh-ghostty-vt [--source /path/to/ghostty] [--dry-run]")
        throw RefreshError.helpRequested
      default: throw RefreshError.unknownArgument(argument)
      }
    }
    source = parsedSource
  }
}

private struct Version: Comparable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int

  init(_ major: Int, _ minor: Int, _ patch: Int) {
    self.major = major; self.minor = minor; self.patch = patch
  }

  init(_ string: String) throws {
    let parts = string.split(separator: ".").prefix(3).compactMap { Int($0) }
    guard parts.count >= 2 else { throw RefreshError.invalidZigVersion(string) }
    major = parts[0]; minor = parts[1]; patch = parts.count > 2 ? parts[2] : 0
  }

  var description: String { "\(major).\(minor).\(patch)" }

  static func < (lhs: Self, rhs: Self) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

private enum RefreshError: Error, CustomStringConvertible {
  case helpRequested
  case missingZig(String)
  case oldZig(found: String, required: String)
  case invalidZigVersion(String)
  case missingTool(String)
  case invalidSource(String)
  case unsupportedPlatform
  case commandFailed(String, Int32)
  case missingBuildOutput(String)
  case verificationFailed(String)
  case missingArgument(String)
  case unknownArgument(String)

  var description: String {
    switch self {
    case .helpRequested: "Help requested"
    case .missingZig(let version):
      """
      Zig >= \(version) is required to build libghostty-vt.

      Install the pinned, checksummed project-local Zig toolchain and retry:
        ./Scripts/bootstrap-zig.sh
        swift package --allow-writing-to-package-directory refresh-ghostty-vt

      Normal `swift build` calls do not require Zig after the archive is generated.
      """
    case .oldZig(let found, let required): "Zig \(found) is installed; >= \(required) is required."
    case .invalidZigVersion(let value): "Could not parse Zig version: \(value)"
    case .missingTool(let tool): "Required tool not found: \(tool)"
    case .invalidSource(let path): "Not a Ghostty source checkout: \(path)"
    case .unsupportedPlatform: "Refreshing libghostty-vt is currently supported on macOS and Linux."
    case .commandFailed(let command, let status): "\(command) exited with status \(status)."
    case .missingBuildOutput(let path): "Ghostty build did not produce \(path)."
    case .verificationFailed(let reason): "Built artifact verification failed: \(reason)"
    case .missingArgument(let option): "Missing value for \(option)."
    case .unknownArgument(let argument): "Unknown argument: \(argument)"
    }
  }
}
