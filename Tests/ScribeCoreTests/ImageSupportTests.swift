import Foundation
import Testing

@testable import ScribeCore

@Suite
struct ImageSupportTests {


  @Test func detectsPNGByMagicBytes() {
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    #expect(ImageSupport.detectImageType(data: data) == "image/png")
  }

  @Test func detectsJPEGByMagicBytes() {
    let data = Data([0xFF, 0xD8, 0xFF, 0xE0])
    #expect(ImageSupport.detectImageType(data: data) == "image/jpeg")
  }

  @Test func detectsGIFByMagicBytes() {
    let data = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
    #expect(ImageSupport.detectImageType(data: data) == "image/gif")
  }

  @Test func detectsBMPByMagicBytes() {
    let data = Data([0x42, 0x4D, 0x00, 0x00])
    #expect(ImageSupport.detectImageType(data: data) == "image/bmp")
  }

  @Test func detectsTIFFLittleEndianByMagicBytes() {
    let data = Data([0x49, 0x49, 0x2A, 0x00])
    #expect(ImageSupport.detectImageType(data: data) == "image/tiff")
  }

  @Test func detectsTIFFBigEndianByMagicBytes() {
    let data = Data([0x4D, 0x4D, 0x00, 0x2A])
    #expect(ImageSupport.detectImageType(data: data) == "image/tiff")
  }

  @Test func detectsWebPByMagicBytes() {
    // RIFF....WEBP
    var data = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00])
    data.append(contentsOf: [0x57, 0x45, 0x42, 0x50])
    #expect(ImageSupport.detectImageType(data: data) == "image/webp")
  }

  @Test func detectsHEICByMagicBytes() {
    // ftyp box: size(4) + "ftyp"(4) + "heic"(4)
    var data = Data([0x00, 0x00, 0x00, 0x14]) // 20 bytes
    data.append(contentsOf: [0x66, 0x74, 0x79, 0x70]) // "ftyp"
    data.append(contentsOf: [0x68, 0x65, 0x69, 0x63]) // "heic"
    data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // padding
    #expect(ImageSupport.detectImageType(data: data) == "image/heic")
  }

  @Test func rejectsNonImageData() {
    let data = Data([0x00, 0x00, 0x00, 0x00])
    #expect(ImageSupport.detectImageType(data: data) == nil)
  }

  @Test func rejectsTooShortData() {
    let data = Data([0x89, 0x50])
    #expect(ImageSupport.detectImageType(data: data) == nil)
  }


  @Test func detectsImageFileByMagicBytes() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let pngPath = dir.appendingPathComponent("not-really-a-txt.txt").path
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: pngPath))
    #expect(ImageSupport.isImageFile(path: pngPath) == true)

    let txtPath = dir.appendingPathComponent("actually-text.png").path
    try Data("hello world".utf8).write(to: URL(fileURLWithPath: txtPath))
    #expect(ImageSupport.isImageFile(path: txtPath) == false)
  }


  @Test func detectImageTypeUsesMagicBytesNotExtension() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    // A PNG file with a .jpg extension — magic bytes should win
    let path = dir.appendingPathComponent("tricky.jpg").path
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: URL(fileURLWithPath: path))
    #expect(ImageSupport.detectImageType(path: path) == "image/png")
  }

  @Test func base64EncodesImage() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let imagePath = dir.appendingPathComponent("test.png").path
    let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    try data.write(to: URL(fileURLWithPath: imagePath))

    let (mimeType, base64, bytes) = try ImageSupport.base64ImageData(from: imagePath)
    #expect(mimeType == "image/png")
    #expect(bytes == data.count)
    #expect(!base64.isEmpty)
    #expect(Data(base64Encoded: base64) == data)
  }

}
