import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

#if canImport(Darwin)
import Darwin
private func secureRandomBytes(count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  return bytes
}
#elseif canImport(Glibc)
import Glibc
private func secureRandomBytes(count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  let fd = open("/dev/urandom", O_RDONLY)
  precondition(fd >= 0, "Cannot open /dev/urandom")
  defer { close(fd) }
  let bytesRead = read(fd, &bytes, count)
  precondition(bytesRead == count, "Cannot read sufficient bytes from /dev/urandom")
  return bytes
}
#elseif canImport(Musl)
import Musl
private func secureRandomBytes(count: Int) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: count)
  let fd = open("/dev/urandom", O_RDONLY)
  precondition(fd >= 0, "Cannot open /dev/urandom")
  defer { close(fd) }
  let bytesRead = read(fd, &bytes, count)
  precondition(bytesRead == count, "Cannot read sufficient bytes from /dev/urandom")
  return bytes
}
#endif

enum PKCE {
  struct Pair: Sendable {
    let verifier: String
    let challenge: String
  }

  static func generate() -> Pair {
    let bytes = secureRandomBytes(count: 32)

    let verifier = Data(bytes).base64URLEncodedStringNoPadding()

    let verifierData = Data(verifier.utf8)
    let hash = SHA256.hash(data: verifierData)
    let challenge = Data(hash).base64URLEncodedStringNoPadding()

    return Pair(verifier: verifier, challenge: challenge)
  }
}

extension Data {
  fileprivate func base64URLEncodedStringNoPadding() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
