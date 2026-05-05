import Foundation
import PackagePlugin

@main struct GitVersionPlugin: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let outputFile = context.pluginWorkDirectory.appending("GitVersion.swift")

    return [
      .buildCommand(
        displayName: "Embedding git version hash",
        executable: .init("/bin/sh"),
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
          outputFile.string,
        ],
        inputFiles: [],
        outputFiles: [outputFile]
      )
    ]
  }
}
