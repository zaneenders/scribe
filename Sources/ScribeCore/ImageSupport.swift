import Foundation

public enum ImageSupport {

  public static func detectImageType(path: String) -> String? {
    guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 32), data.count >= 4 else { return nil }
    return detectImageType(data: data)
  }

  public static func detectImageType(data: Data) -> String? {
    guard data.count >= 4 else { return nil }
    let bytes = [UInt8](data.prefix(32))

    if bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
      return "image/png"
    }

    if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
      return "image/jpeg"
    }

    if bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x38 {
      return "image/gif"
    }

    if bytes[0] == 0x42, bytes[1] == 0x4D {
      return "image/bmp"
    }

    if (bytes[0] == 0x49 && bytes[1] == 0x49 && bytes[2] == 0x2A && bytes[3] == 0x00)
      || (bytes[0] == 0x4D && bytes[1] == 0x4D && bytes[2] == 0x00 && bytes[3] == 0x2A)
    {
      return "image/tiff"
    }

    if bytes.count >= 12,
      bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
      bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50
    {
      return "image/webp"
    }

    if bytes.count >= 12,
      bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70
    {

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

}
