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
    let cwd: FilePath!
    do {
        cwd = try await fs.currentWorkingDirectory
    } catch {
        System.Log.error("Unable to find currentWorkingDirectory.")
        return
    }
    let packageFP = cwd.appending("/Package.swift")
    guard let _ = try? await fs.info(forFileAt: packageFP) else {
        System.Log.trace("Not a swift package not Package.swift found")
        return
    }
    do {
        try await process(config, packageFP)
    } catch {
        System.Log.error("Unable to format: \(packageFP.string)")
    }
    guard let cwd = try? await fs.openDirectory(atPath: cwd) else {
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
                    try await process(config, path.path)
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

private func process(_ config: Configuration, _ file: FilePath) async throws {
    let formatter = SwiftFormatter(
        configuration: config, findingConsumer: nil)
    let url: URL = URL(fileURLWithPath: file.string)
    let fh = try await FileSystem.shared.openFile(
        forReadingAndWritingAt: file, options: .modifyFile(createIfNecessary: true))
    let info = try await fh.info()
    var buffer = ""
    let contents = try await fh.readToEnd(maximumSizeAllowed: .bytes(info.size))
    System.Log.trace("Formatting: \(file)")
    let source = String(buffer: contents)
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
    try await fh.close()
}
