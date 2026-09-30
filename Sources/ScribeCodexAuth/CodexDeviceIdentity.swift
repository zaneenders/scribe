import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Standalone Scribe has its own device key. Enrollment and broker permission are separate server actions.
public enum CodexDeviceIdentity {
  private static func key(baseDirectory: URL?) throws -> P256.Signing.PrivateKey {
    let directory = baseDirectory ?? CodexCredentialStore.resolveBaseDirectory()
    let lock = try CodexStoreLock(directory: directory, name: "codex-device.lock")
    defer { withExtendedLifetime(lock) {} }
    let path = directory.appendingPathComponent("codex-device-key.json")
    if FileManager.default.fileExists(atPath: path.path) {
      return try P256.Signing.PrivateKey(rawRepresentation: JSONDecoder().decode(Data.self, from: Data(contentsOf: path)))
    }
    let key = P256.Signing.PrivateKey()
    try CodexSecureFile.write(key.rawRepresentation, to: path)
    return key
  }

  private static func publicKey(_ key: P256.Signing.PrivateKey) -> [String: String] {
    let raw = key.publicKey.x963Representation
    return ["kty": "EC", "crv": "P-256", "x": encode(Data(raw[1..<33])), "y": encode(Data(raw[33..<65]))]
  }
  private static func encode(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  private static func json(_ value: [String: String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
  }
  public static func enrollment(baseDirectory: URL? = nil) throws -> (thumbprint: String, jwk: Data) {
    let jwk = try json(publicKey(key(baseDirectory: baseDirectory)))
    return (encode(Data(SHA256.hash(data: jwk))), jwk)
  }
  public static func bearer(baseDirectory: URL? = nil) throws -> String {
    let key = try key(baseDirectory: baseDirectory)
    let thumbprint = encode(Data(SHA256.hash(data: try json(publicKey(key)))))
    let header = try encode(json(["alg": "ES256", "typ": "JWT", "kid": thumbprint]))
    let now = Int(Date().timeIntervalSince1970)
    let payload = try encode(JSONSerialization.data(withJSONObject: [
      "sub": thumbprint, "iat": now, "exp": now + 300, "jti": UUID().uuidString
    ], options: [.sortedKeys]))
    let input = "\(header).\(payload)"
    return try input + "." + encode(key.signature(for: Data(input.utf8)).rawRepresentation)
  }
}
