import Foundation
import Scribe
import SwiftFormat
import _NIOFileSystem

private func myConfig() -> Configuration {
    var config = Configuration()
    config.fileScopedDeclarationPrivacy.accessLevel = .private
    config.tabWidth = 4
    config.indentation = .spaces(4)
    config.spacesAroundRangeFormationOperators = false
    config.indentConditionalCompilationBlocks = false
    config.indentSwitchCaseLabels = false
    config.lineBreakAroundMultilineExpressionChainComponents = false
    config.lineBreakBeforeControlFlowKeywords = false
    config.lineLength = 120
    config.maximumBlankLines = 1
    config.prioritizeKeepingFunctionOutputTogether = true
    config.respectsExistingLineBreaks = true
    config.rules["AllPublicDeclarationsHaveDocumentation"] = false
    config.rules["AlwaysUseLiteralForEmptyCollectionInit"] = false
    config.rules["AlwaysUseLowerCamelCase"] = false
    config.rules["AmbiguousTrailingClosureOverload"] = true
    config.rules["BeginDocumentationCommentWithOneLineSummary"] = false
    config.rules["DoNotUseSemicolons"] = true
    config.rules["DontRepeatTypeInStaticProperties"] = true
    config.rules["FileScopedDeclarationPrivacy"] = true
    config.rules["FullyIndirectEnum"] = true
    config.rules["GroupNumericLiterals"] = true
    config.rules["IdentifiersMustBeASCII"] = true
    config.rules["NeverForceUnwrap"] = false
    config.rules["NeverUseForceTry"] = false
    config.rules["NeverUseImplicitlyUnwrappedOptionals"] = false
    config.rules["NoAccessLevelOnExtensionDeclaration"] = true
    config.rules["NoAssignmentInExpressions"] = true
    config.rules["NoBlockComments"] = true
    config.rules["NoCasesWithOnlyFallthrough"] = true
    config.rules["NoEmptyTrailingClosureParentheses"] = true
    config.rules["NoLabelsInCasePatterns"] = true
    config.rules["NoLeadingUnderscores"] = false
    config.rules["NoParensAroundConditions"] = true
    config.rules["NoVoidReturnOnFunctionSignature"] = true
    config.rules["OmitExplicitReturns"] = true
    config.rules["OneCasePerLine"] = true
    config.rules["OneVariableDeclarationPerLine"] = true
    config.rules["OnlyOneTrailingClosureArgument"] = true
    config.rules["OrderedImports"] = true
    config.rules["ReplaceForEachWithForLoop"] = true
    config.rules["ReturnVoidInsteadOfEmptyTuple"] = true
    config.rules["UseEarlyExits"] = false
    config.rules["UseExplicitNilCheckInConditions"] = false
    config.rules["UseLetInEveryBoundCaseVariable"] = false
    config.rules["UseShorthandTypeNames"] = true
    config.rules["UseSingleLinePropertyGetter"] = false
    config.rules["UseSynthesizedInitializer"] = false
    config.rules["UseTripleSlashForDocumentationComments"] = true
    config.rules["UseWhereClausesInForLoops"] = false
    config.rules["ValidateDocumentationComments"] = false
    return config
}

func format() async throws {
    System.enableLogging(tracing: false, write_to_file: false)
    await format(myConfig())
}

private func format(_ config: Configuration) async {

    let fs = FileSystem.shared

    let cwd = FileManager.default.currentDirectoryPath
    let package = "/Package.swift"
    let path = cwd + package
    let cwdFP = FilePath(cwd)
    let packageFP = FilePath(path)
    guard let _ = try? await fs.info(forFileAt: packageFP) else {
        System.Log.trace("Not a swift package not Package.swift found")
        return
    }
    process(config, packageFP)
    guard let cwd = try? await fs.openDirectory(atPath: cwdFP) else {
        return
    }
    var count: Int = 0
    do {
        for try await path in cwd.listContents() {
            let s = path.name.string
            if s.contains("Sources") || s.contains("Plugins")
                || s.contains("Tests")
            {
                count += await getSwift(config, path.path)
            }
        }
        try? await cwd.close()
    } catch {
        System.Log.error("\(error.localizedDescription)")
    }
    System.Log.trace("\(count)")
}

private func getSwift(
    _ config: Configuration, _ fp: FilePath
) async
    -> Int
{
    let fs = FileSystem.shared
    guard let fh = try? await fs.openDirectory(atPath: fp) else {
        return 0
    }
    var count: Int = 0
    do {
        for try await path in fh.listContents() {
            switch path.type {
            case .directory:
                count += await getSwift(config, path.path)
            default:
                if path.name.string.contains(".swift") {
                    process(config, path.path)
                    count += 1
                }
            }
        }
        try? await fh.close()
    } catch {
        System.Log.error("\(error.localizedDescription)")
    }
    return count
}

private func process(_ config: Configuration, _ file: FilePath) {
    var buffer = ""
    let formatter = SwiftFormatter(
        configuration: config, findingConsumer: nil)
    let url: URL = URL(fileURLWithPath: file.string)
    guard let fh = try? FileHandle(forUpdating: url) else {
        System.Log.error("failed to find: \(file)")
        return
    }
    System.Log.trace("Formatting: \(file)")
    let sourceData = fh.readDataToEndOfFile()
    defer { fh.closeFile() }
    guard let source = String(data: sourceData, encoding: .utf8) else {
        return
    }
    do {
        try formatter.format(
            source: source,
            assumingFileURL: url,
            selection: .infinite,
            to: &buffer,
            parsingDiagnosticHandler: nil)

        if buffer != source {
            let bufferData = buffer.data(using: .utf8)!
            try bufferData.write(to: url, options: .atomic)
        }
    } catch {
        System.Log.error("\(error.localizedDescription)")
    }
}
