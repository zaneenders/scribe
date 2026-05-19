import Foundation

/// Shared helpers for detecting image files, reading them as base64 data URIs,
/// and extracting image path references from user-typed text.
public enum ImageSupport {
  public static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif",
  ]

  public static func isImageFile(path: String) -> Bool {
    let ext = (path as NSString).pathExtension.lowercased()
    return imageExtensions.contains(ext)
  }

  public static func mimeType(for path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    case "bmp": return "image/bmp"
    case "tiff", "tif": return "image/tiff"
    case "heic", "heif": return "image/heic"
    default: return "application/octet-stream"
    }
  }

  public static func base64ImageData(from path: String) throws -> (
    mimeType: String, base64: String, bytes: Int
  ) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let base64 = data.base64EncodedString()
    let mimeType = self.mimeType(for: path)
    return (mimeType, base64, data.count)
  }

  /// Extracts image file paths from a text string.
  ///
  /// Looks for substrings that end with a known image extension and appear to
  /// be file paths (absolute, tilde-relative, or contain a `/`). Each candidate
  /// is resolved against `workingDirectory` and only included if it points to an
  /// existing file.
  public static func extractImagePaths(from text: String, workingDirectory: String)
    -> [String]
  {
    var results: [String] = []
    let lowercased = text.lowercased()

    for ext in imageExtensions {
      var searchStart = lowercased.startIndex
      while let range = lowercased[searchStart...].range(of: "." + ext) {
        let extEnd = range.upperBound

        // Walk backwards to find the earliest plausible start of the path.
        var earliestStart = range.lowerBound
        while earliestStart > text.startIndex {
          let prev = text.index(before: earliestStart)
          let char = text[prev]
          if char.isWhitespace || ["\"", "'", "(", "[", "{", ":", ";", ","].contains(char) {
            earliestStart = text.index(after: prev)
            break
          }
          earliestStart = prev
        }

        // Try progressively shorter paths by moving the start forward.
        var currentStart = earliestStart
        while currentStart <= range.lowerBound {
          let candidate = String(text[currentStart..<extEnd])
          if let resolved = resolveImagePath(candidate, workingDirectory: workingDirectory),
            !results.contains(resolved)
          {
            results.append(resolved)
            break
          }
          if currentStart >= range.lowerBound { break }
          currentStart = text.index(after: currentStart)
        }

        searchStart = extEnd
      }
    }

    return results
  }

  private static func resolveImagePath(_ candidate: String, workingDirectory: String) -> String?
  {
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Only consider paths that look like file paths.
    guard
      trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix(".")
        || trimmed.contains("/")
    else { return nil }

    let resolved: String
    if trimmed.hasPrefix("/") {
      resolved = trimmed
    } else if trimmed.hasPrefix("~") {
      resolved = NSString(string: trimmed).expandingTildeInPath
    } else {
      resolved = (workingDirectory as NSString).appendingPathComponent(trimmed)
    }

    let standardized = URL(fileURLWithPath: resolved).standardizedFileURL.path
    var isDir: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir),
      !isDir.boolValue
    else { return nil }

    return standardized
  }
}
