import Foundation

public enum CodexServerTransport {
  public static func origin(_ value: String, sshTunnel: Bool = false) throws -> String {
    guard var parts = URLComponents(string: value), let host = parts.host?.lowercased(), !host.isEmpty,
      parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
      parts.path.isEmpty || parts.path == "/",
      parts.scheme == "https" || (sshTunnel && parts.scheme == "http" && ["127.0.0.1", "[::1]", "::1"].contains(host))
    else { throw CodexAuthorityError.invalidTransport }
    parts.host = host
    parts.path = ""
    if parts.scheme == "https" && parts.port == 443 { parts.port = nil }
    guard let result = parts.url?.absoluteString else { throw CodexAuthorityError.invalidTransport }
    return result
  }
}

