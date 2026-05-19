import Foundation
import SystemPackage

enum FileSystemToolHelpers {
  static func requireParentDirectoryForWrite(filesystemPath: String, userPath: String) throws {
    let parent = URL(fileURLWithPath: filesystemPath).deletingLastPathComponent()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue
    else {
      throw PathResolution.PathError(
        description: "parent directory does not exist for write: \(userPath)")
    }
  }

  static func readFileWhole(path: String, workingDirectory: FilePath) throws -> String {
    let fp = try PathResolution.resolve(reading: path, cwd: workingDirectory)
    let s = fp.string
    return try String(contentsOfFile: s, encoding: .utf8)
  }
}
