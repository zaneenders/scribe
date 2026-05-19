import Foundation

/// Shared helpers for detecting image files, reading them as base64 data URIs,
/// and extracting image path references from user-typed text.
public enum ImageSupport {

  // MARK: - Magic-byte image detection

  /// Detects whether a file is an image by reading its first bytes.
  /// Returns the MIME type if recognized, or `nil` if not an image.
  public static func detectImageType(path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 32), data.count >= 4 else { return nil }
    return detectImageType(data: data)
  }

  /// Detects image type from raw byte data.
  /// Returns the MIME type if recognized, or `nil` if not an image.
  public static func detectImageType(data: Data) -> String? {
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data.prefix(32))

    // PNG: 89 50 4E 47
    if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
      return "image/png"
    }

    // JPEG: FF D8 FF
    if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
      return "image/jpeg"
    }

    // GIF: 47 49 46 38 ("GIF8")
    if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
      return "image/gif"
    }

    // BMP: 42 4D ("BM")
    if bytes[0] == 0x42, bytes[1] == 0x4D {
      return "image/bmp"
    }

    // TIFF: 49 49 2A 00 (little endian) or 4D 4D 00 2A (big endian)
    if (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
      || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)
    {
      return "image/tiff"
    }

    // WebP: starts with RIFF, has WEBP at offset 8
    if bytes.count >= 12,
      bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
      bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50
    {
      return "image/webp"
    }

    // HEIC/HEIF: ISO Base Media File Format (ftyp box).
    // First 4 bytes = box size, next 4 = "ftyp", then brand around offset 8.
    if bytes.count >= 12,
      bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70
    {
      // Check for heic / heix / mif1 brands
      let brand = String(bytes: bytes[8..<12].map { $0 }, encoding: .ascii)
      if brand == "heic" || brand == "heix" || brand == "mif1" || brand == "msf1" {
        return "image/heic"
      }
      return "image/heif"
    }

    return nil
  }

  public static func isImageFile(path: String) -> Bool {
    detectImageType(path: path) != nil
  }

  public static func base64ImageData(from path: String) throws -> (
    mimeType: String, base64: String, bytes: Int
  ) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let base64 = data.base64EncodedString()
    let mimeType = detectImageType(data: data) ?? "application/octet-stream"
    return (mimeType, base64, data.count)
  }

  // MARK: - Path extraction

  /// Extracts image file paths from a text string.
  ///
  /// Looks for substrings that end with a known image extension and appear to
  /// be file paths (absolute, tilde-relative, or contain a `/`). Each candidate
  /// is resolved against `workingDirectory` and only included if it points to an
  /// existing file that passes magic-byte image detection.
  public static func extractImagePaths(from text: String, workingDirectory: String)
    -> [String]
  {
    var results: [String] = []
    let lowercased = text.lowercased()
    let extensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "heif"]

    for ext in extensions {
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
            !results.contains(resolved),
            isImageFile(path: resolved)
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
