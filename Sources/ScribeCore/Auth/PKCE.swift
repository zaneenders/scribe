#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

// MARK: - Secure Random Bytes (platform wrapper)

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

/// PKCE (Proof Key for Code Exchange) utilities for the OAuth 2.0
/// authorization code flow with S256 challenge method.
enum PKCE {
  /// A generated PKCE pair: verifier and S256 challenge.
  struct Pair: Sendable {
    let verifier: String
    let challenge: String
  }

  /// Generate a cryptographically random code verifier and its
  /// S256 code challenge.  The verifier is 32 random bytes,
  /// base64url-encoded without padding (43 characters).
  static func generate() -> Pair {
    // 32 random bytes → 43-char base64url verifier
    let bytes = secureRandomBytes(count: 32)

    let verifier = Data(bytes).base64URLEncodedStringNoPadding()

    // SHA-256 hash of the ASCII verifier, then base64url-encode
    let verifierData = Data(verifier.utf8)
    let hash = SHA256.hash(data: verifierData)
    let challenge = Data(hash).base64URLEncodedStringNoPadding()

    return Pair(verifier: verifier, challenge: challenge)
  }
}

extension Data {
  /// Base64URL-encoded string (using `-` and `_`) with no trailing `=`.
  fileprivate func base64URLEncodedStringNoPadding() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
