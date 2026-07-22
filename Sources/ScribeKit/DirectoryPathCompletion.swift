import Foundation
import ScribeCore
import SystemPackage

/// Resolves and completes filesystem directory paths for the macOS directory palette.
public enum DirectoryPathCompletion {
  public struct TabResult: Equatable, Sendable {
    public let text: String
    public let matches: [String]

    public init(text: String, matches: [String]) {
      self.text = text
      self.matches = matches
    }
  }

  public struct ResolveResult: Equatable, Sendable {
    public let path: String?
    public let error: String?

    public init(path: String?, error: String?) {
      self.path = path
      self.error = error
    }
  }

  /// Resolves `input` to an absolute existing directory path.
  public static func resolve(input: String, relativeTo baseCWD: String) -> ResolveResult {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return ResolveResult(path: nil, error: "path is empty")
    }

    do {
      let resolved = try resolveAbsolutePath(trimmed, baseCWD: baseCWD)
      let st = FileStat.stat(resolved)
      guard st.exists else {
        return ResolveResult(path: nil, error: "path does not exist: \(trimmed)")
      }
      guard st.isDirectory else {
        return ResolveResult(path: nil, error: "not a directory: \(trimmed)")
      }
      return ResolveResult(path: resolved.string, error: nil)
    } catch let error as PathResolutionError {
      return ResolveResult(path: nil, error: error.localizedDescription)
    } catch {
      return ResolveResult(path: nil, error: error.localizedDescription)
    }
  }

  /// Tab-completes directory names in `input`, returning the updated text and visible matches.
  public static func tabComplete(input: String, relativeTo baseCWD: String) -> TabResult {
    let (parentPath, prefix, prefixStartIndex) = completionContext(input: input, baseCWD: baseCWD)
    guard let parentPath else {
      return TabResult(text: input, matches: [])
    }

    let entries: [String]
    do {
      entries = try listDirectoryNames(parentPath)
    } catch {
      return TabResult(text: input, matches: [])
    }

    let matches = entries.filter { $0.hasPrefix(prefix) }.sorted()
    guard !matches.isEmpty else {
      return TabResult(text: input, matches: [])
    }

    if matches.count == 1 {
      let completed = replaceCompletionPrefix(
        input: input,
        prefixStartIndex: prefixStartIndex,
        replacement: matches[0] + "/")
      return TabResult(text: completed, matches: matches)
    }

    let common = longestCommonPrefix(matches)
    let extendedPrefix = String(common.dropFirst(prefix.count))
    guard !extendedPrefix.isEmpty else {
      return TabResult(text: input, matches: matches)
    }

    let completed = replaceCompletionPrefix(
      input: input,
      prefixStartIndex: prefixStartIndex,
      replacement: prefix + extendedPrefix)
    return TabResult(text: completed, matches: matches)
  }

  // MARK: - Private

  private struct PathResolutionError: Error, CustomStringConvertible {
    let description: String
  }

  private static func resolveAbsolutePath(_ input: String, baseCWD: String) throws -> FilePath {
    let expanded = expandTilde(input)
    let baseURL = URL(fileURLWithPath: baseCWD, isDirectory: true).standardizedFileURL
    let combined: URL
    if expanded.hasPrefix("/") {
      combined = URL(fileURLWithPath: expanded).standardizedFileURL
    } else {
      combined = baseURL.appendingPathComponent(expanded).standardizedFileURL
    }
    return FilePath(combined.resolvingSymlinksInPath().path)
  }

  private static func expandTilde(_ path: String) -> String {
    guard path.hasPrefix("~") else { return path }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == "~" { return home }
    if path.hasPrefix("~/") {
      return home + String(path.dropFirst(1))
    }
    return path
  }

  private static func completionContext(
    input: String,
    baseCWD: String
  ) -> (parentPath: FilePath?, prefix: String, prefixStartIndex: String.Index) {
    if input.isEmpty {
      return (FilePath(baseCWD), "", input.startIndex)
    }

    if input == "~" {
      let home = FileManager.default.homeDirectoryForCurrentUser.path
      return (FilePath(home), "", input.startIndex)
    }

    if input.hasSuffix("/") {
      do {
        let parent = try resolveAbsolutePath(String(input.dropLast()), baseCWD: baseCWD)
        return (parent, "", input.endIndex)
      } catch {
        return (nil, "", input.startIndex)
      }
    }

    guard let slashIndex = input.lastIndex(of: "/") else {
      if input.hasPrefix("~/") {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let prefix = String(input.dropFirst(2))
        return (FilePath(home), prefix, input.index(input.startIndex, offsetBy: 2))
      }
      if input.hasPrefix("~") {
        return (nil, input, input.startIndex)
      }
      let prefix = input
      return (FilePath(baseCWD), prefix, input.startIndex)
    }

    let parentPart = String(input[..<slashIndex])
    let prefixStart = input.index(after: slashIndex)
    let prefix = String(input[prefixStart...])

    if parentPart.isEmpty {
      return (FilePath("/"), prefix, prefixStart)
    }

    do {
      let parent = try resolveAbsolutePath(parentPart, baseCWD: baseCWD)
      return (parent, prefix, prefixStart)
    } catch {
      return (nil, prefix, prefixStart)
    }
  }

  private static func listDirectoryNames(_ path: FilePath) throws -> [String] {
    let st = FileStat.stat(path)
    guard st.exists else {
      throw PathResolutionError(description: "path does not exist: \(path.string)")
    }
    guard st.isDirectory else {
      throw PathResolutionError(description: "not a directory: \(path.string)")
    }
    return try listDirectoryContents(path).filter { name in
      let child = path.appending(name)
      return FileStat.stat(child).isDirectory
    }
  }

  private static func replaceCompletionPrefix(
    input: String,
    prefixStartIndex: String.Index,
    replacement: String
  ) -> String {
    String(input[..<prefixStartIndex]) + replacement
  }

  private static func longestCommonPrefix(_ strings: [String]) -> String {
    guard let first = strings.first else { return "" }
    var prefix = first
    for string in strings.dropFirst() {
      while !string.hasPrefix(prefix) {
        prefix = String(prefix.dropLast())
        if prefix.isEmpty { return "" }
      }
    }
    return prefix
  }
}
