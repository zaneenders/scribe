import Foundation
import PackagePlugin

@main struct GitVersionPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let outputFile = context.pluginWorkDirectoryURL.appendingPathComponent("GitVersion.swift")

    let gitDir = context.package.directoryURL.appendingPathComponent(".git")
    var inputFiles: [URL] = []

    if FileManager.default.fileExists(atPath: gitDir.path) {
      let headFile = gitDir.appendingPathComponent("HEAD")
      if FileManager.default.fileExists(atPath: headFile.path) {
        inputFiles.append(headFile)
      }
      let indexFile = gitDir.appendingPathComponent("index")
      if FileManager.default.fileExists(atPath: indexFile.path) {
        inputFiles.append(indexFile)
      }
      let refsDir = gitDir.appendingPathComponent("refs")
      if FileManager.default.fileExists(atPath: refsDir.path) {
        inputFiles.append(refsDir)
      }
    }

    return [
      .buildCommand(
        displayName: "Embedding git version hash",
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          """
          HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
          if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
            DIRTY=" (modified)"
          else
            DIRTY=""
          fi
          echo "enum GitVersion { static let hash = \\\"$HASH$DIRTY\\\" }" > "$0"
          """,
          outputFile.path,
        ],
        inputFiles: inputFiles,
        outputFiles: [outputFile]
      )
    ]
  }
}
