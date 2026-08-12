import Foundation
import PackagePlugin

/// Runs a cheap artifact preflight before every ScribeTerminal build. It never
/// invokes Zig; it only replaces an opaque compiler/linker failure with the
/// exact one-time bootstrap command developers need to run.
@main
struct GhosttyVtPresencePlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let package = context.package.directoryURL
    let vendor = package.appendingPathComponent("Vendor/GhosttyVt", isDirectory: true)

    #if os(macOS)
    let library = vendor.appendingPathComponent("Libraries/macos/libghostty-vt.a")
    #elseif os(Linux)
    let library = vendor.appendingPathComponent("Libraries/linux/libghostty-vt.a")
    #else
    let library = vendor.appendingPathComponent("Libraries/unsupported/libghostty-vt.a")
    #endif

    let required = [
      library.path,
      vendor.appendingPathComponent("Headers/ghostty/vt.h").path,
      vendor.appendingPathComponent("Headers/module.modulemap").path,
    ]
    let outputDirectory = context.pluginWorkDirectoryURL.appendingPathComponent("preflight")
    let quoted = required.map(Self.shellQuote).joined(separator: " ")
    let script = """
    missing=""
    for path in \(quoted); do
      if [ ! -f "$path" ]; then
        missing="$missing\\n  - $path"
      fi
    done
    if [ -n "$missing" ]; then
      printf >&2 'error: Missing generated libghostty-vt artifacts:%b\\n\\n' "$missing"
      printf >&2 'Initialize the pinned Ghostty source and build the library once:\n'
      printf >&2 '  git submodule update --init --recursive\n'
      printf >&2 '  swift package --allow-writing-to-package-directory refresh-ghostty-vt\n\\n'
      printf >&2 'Run the same refresh command whenever the Ghostty submodule is updated.\n'
      exit 1
    fi
    mkdir -p "$0"
    touch "$0/present"
    """

    return [
      .prebuildCommand(
        displayName: "Checking generated libghostty-vt artifacts",
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script, outputDirectory.path],
        outputFilesDirectory: outputDirectory
      )
    ]
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
