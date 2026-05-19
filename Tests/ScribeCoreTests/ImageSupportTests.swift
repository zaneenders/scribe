import Foundation
import Testing

@testable import ScribeCore

@Suite
struct ImageSupportTests {

  @Test func detectsImageExtensions() {
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.png") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.jpg") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.jpeg") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.gif") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.webp") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.bmp") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.tiff") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/photo.heic") == true)
    #expect(ImageSupport.isImageFile(path: "/tmp/document.txt") == false)
    #expect(ImageSupport.isImageFile(path: "/tmp/code.swift") == false)
  }

  @Test func mimeTypeMapping() {
    #expect(ImageSupport.mimeType(for: "test.png") == "image/png")
    #expect(ImageSupport.mimeType(for: "test.jpg") == "image/jpeg")
    #expect(ImageSupport.mimeType(for: "test.jpeg") == "image/jpeg")
    #expect(ImageSupport.mimeType(for: "test.gif") == "image/gif")
    #expect(ImageSupport.mimeType(for: "test.webp") == "image/webp")
    #expect(ImageSupport.mimeType(for: "test.bmp") == "image/bmp")
    #expect(ImageSupport.mimeType(for: "test.tiff") == "image/tiff")
    #expect(ImageSupport.mimeType(for: "test.tif") == "image/tiff")
    #expect(ImageSupport.mimeType(for: "test.heic") == "image/heic")
    #expect(ImageSupport.mimeType(for: "test.unknown") == "application/octet-stream")
  }

  @Test func extractsAbsoluteImagePath() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let imagePath = dir.appendingPathComponent("test.png").path
    let data = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic bytes
    try data.write(to: URL(fileURLWithPath: imagePath))

    let text = "Look at this image: \(imagePath)"
    let paths = ImageSupport.extractImagePaths(from: text, workingDirectory: "/tmp")
    #expect(paths.count == 1)
    #expect(paths.first == imagePath)
  }

  @Test func extractsRelativeImagePath() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let imagePath = dir.appendingPathComponent("test.png").path
    let data = Data([0x89, 0x50, 0x4E, 0x47])
    try data.write(to: URL(fileURLWithPath: imagePath))

    let text = "Look at ./test.png"
    let paths = ImageSupport.extractImagePaths(from: text, workingDirectory: dir.path)
    #expect(paths.count == 1)
    #expect(paths.first == imagePath)
  }

  @Test func ignoresNonExistentPaths() {
    let text = "Look at /tmp/nonexistent.png"
    let paths = ImageSupport.extractImagePaths(from: text, workingDirectory: "/tmp")
    #expect(paths.isEmpty)
  }

  @Test func ignoresNonImagePaths() {
    let text = "Look at /tmp/document.txt"
    let paths = ImageSupport.extractImagePaths(from: text, workingDirectory: "/tmp")
    #expect(paths.isEmpty)
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
