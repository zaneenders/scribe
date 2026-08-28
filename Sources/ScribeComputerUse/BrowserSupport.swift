#if canImport(AppKit)
import Foundation

private let allowedBrowserSchemes: Set<String> = ["http", "https"]

func validatedBrowserURL(_ value: String) -> URL? {
  guard let components = URLComponents(string: value),
    let scheme = components.scheme?.lowercased(),
    allowedBrowserSchemes.contains(scheme),
    components.host?.isEmpty == false,
    let url = components.url
  else { return nil }
  return url
}

func normalizedURLString(_ value: AnyObject?) -> String {
  guard let value else { return "" }
  if let url = value as? URL { return url.absoluteString }
  if let string = value as? String, validatedBrowserURL(string) != nil { return string }
  return ""
}
#endif
