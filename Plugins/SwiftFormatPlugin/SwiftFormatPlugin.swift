import Foundation
import PackagePlugin
import RegexBuilder

@main
/// `swift package --allow-writing-to-package-directory format`
@available(macOS 13, *)
struct SwiftFormatPlugin: CommandPlugin {
    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        let swiftFormatTool = try context.tool(named: "swift-format")
        let configFile = context.package.directory
            .appending(".swift-format.json")
        // Package.swift files
        let packages = context.package.directory.appending(
            subpath: "Package.swift")
        var paths = Set<String>()
        paths.insert(packages.string)
        // Plugin Files
        let plugins: Path = context.package.directory.appending(
            subpath: "Plugins")
        let plugin_paths = try! FileManager.default.subpathsOfDirectory(
            atPath: plugins.string)
        for p in plugin_paths {
            if p.contains(".swift") {
                paths.insert("Plugins/" + p)
            }
        }
        // Target files
        for target in context.package.targets {
            paths.insert("\(target.directory)")
        }

        let swiftFormatExec = URL(
            fileURLWithPath: swiftFormatTool.path.string)
        let swiftFormatArgs: [String] = [
            "--configuration", "\(configFile)",
            "--in-place",
            "--recursive",
            "--parallel",
        ]

        let process = try Process.run(
            swiftFormatExec, arguments: swiftFormatArgs + paths)
        for p in paths {
            print("formatting: \(p)")
        }
        process.waitUntilExit()
        if !(process.terminationReason == .exit
            && process.terminationStatus == 0)
        {
            fatalError(
                "\(process.terminationReason):\(process.terminationStatus)")
        }
    }
}
