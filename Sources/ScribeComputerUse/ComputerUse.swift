#if canImport(AppKit)
import AppKit
import ApplicationServices
import Foundation
import Logging
import ScreenCaptureKit
import ScribeCore
import SystemPackage

public enum ComputerUseError: Error, LocalizedError {
  case accessibilityPermissionMissing
  case screenRecordingPermissionMissing
  case windowNotFound(Int)
  case stateNotFound(String)
  case elementNotFound(String)
  case unsupportedAction(String)
  case accessibilityFailure(String)
  case captureFailure(String)

  public var errorDescription: String? {
    switch self {
    case .accessibilityPermissionMissing:
      return
        "Scribe needs Accessibility permission in System Settings → Privacy & Security → Accessibility. Enable Scribe (or the terminal running the scribe CLI), then retry."
    case .screenRecordingPermissionMissing:
      return
        "Scribe needs Screen Recording permission in System Settings → Privacy & Security → Screen & System Audio Recording. Enable Scribe (or the terminal running the scribe CLI), then retry."
    case .windowNotFound(let id): return "Window id \(id) is no longer available. Call find_windows again."
    case .stateNotFound(let id): return "UI state \(id) is unavailable. Call observe_ui again."
    case .elementNotFound(let ref):
      return "Element \(ref) is unavailable or does not belong to that UI state. Call observe_ui again."
    case .unsupportedAction(let action): return "Unsupported UI action: \(action)."
    case .accessibilityFailure(let message): return "Accessibility operation failed: \(message)"
    case .captureFailure(let message): return "Window capture failed: \(message)"
    }
  }
}

private struct WindowRecord {
  let id: CGWindowID
  let pid: pid_t
  let app: String
  let title: String
  let frame: CGRect
  let layer: Int
  let onscreen: Bool
}

private struct Observation {
  let window: WindowRecord
  let pageURL: String
  let elements: [String: AXUIElement]
  let nodes: [UIOutlineNode]
  let treeTruncated: Bool
}

/// Owns all live AX references. Tool implementations share one actor so refs remain
/// valid across find/observe/act calls without exposing AXUIElement as Sendable.
public actor ComputerUseSession {
  private var observations: [String: Observation] = [:]
  private var observationOrder: [String] = []

  public init() {}

  fileprivate func findWindows(query: String?) throws -> [WindowRecord] {
    guard accessibilityTrusted(prompt: true) else {
      throw ComputerUseError.accessibilityPermissionMissing
    }
    let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
      return []
    }
    return raw.compactMap { entry in
      guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        let app = entry[kCGWindowOwnerName as String] as? String,
        let bounds = entry[kCGWindowBounds as String] as? [String: Any],
        let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
      else { return nil }
      let title = entry[kCGWindowName as String] as? String ?? ""
      let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
      let onscreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true
      guard layer == 0, frame.width >= 80, frame.height >= 60 else { return nil }
      if !needle.isEmpty && !app.lowercased().contains(needle) && !title.lowercased().contains(needle) {
        return nil
      }
      return WindowRecord(
        id: id, pid: pid, app: app, title: title, frame: frame, layer: layer, onscreen: onscreen)
    }.prefix(30).map { $0 }
  }

  func observe(
    windowID: Int,
    includeImage: Bool,
    options: UIObservationOptions,
    offset: Int
  ) async throws -> ObserveUIResult {
    guard accessibilityTrusted(prompt: true) else {
      throw ComputerUseError.accessibilityPermissionMissing
    }
    guard let requestedWindowID = CGWindowID(exactly: windowID) else {
      throw ComputerUseError.windowNotFound(windowID)
    }
    guard let window = try findWindows(query: nil).first(where: { $0.id == requestedWindowID }) else {
      throw ComputerUseError.windowNotFound(windowID)
    }
    guard let root = accessibilityWindow(for: window) else {
      throw ComputerUseError.accessibilityFailure(
        "Could not match \(window.app) window \(window.title.debugDescription) to an AX window.")
    }

    var elements: [String: AXUIElement] = [:]
    let (allNodes, treeTruncated) = buildOutline(
      root: root, elements: &elements, maximumDepth: options.maximumDepth)
    let pageURL = normalizedURLString(copyAttribute(root, kAXDocumentAttribute as CFString))
    return try await storeObservation(
      window: window,
      pageURL: pageURL,
      elements: elements,
      nodes: allNodes,
      treeTruncated: treeTruncated,
      includeImage: includeImage,
      options: options,
      offset: offset)
  }

  func continueObservation(
    stateID: String,
    includeImage: Bool,
    options: UIObservationOptions,
    offset: Int
  ) async throws -> ObserveUIResult {
    guard let observation = observations[stateID] else { throw ComputerUseError.stateNotFound(stateID) }
    return try await result(
      stateID: stateID,
      observation: observation,
      includeImage: includeImage,
      options: options,
      offset: offset)
  }

  private func storeObservation(
    window: WindowRecord,
    pageURL: String,
    elements: [String: AXUIElement],
    nodes: [UIOutlineNode],
    treeTruncated: Bool,
    includeImage: Bool,
    options: UIObservationOptions,
    offset: Int
  ) async throws -> ObserveUIResult {
    let stateID = UUID().uuidString
    let observation = Observation(
      window: window, pageURL: pageURL, elements: elements, nodes: nodes, treeTruncated: treeTruncated)
    observations[stateID] = observation
    observationOrder.append(stateID)
    while observationOrder.count > 16 {
      observations.removeValue(forKey: observationOrder.removeFirst())
    }
    return try await result(
      stateID: stateID,
      observation: observation,
      includeImage: includeImage,
      options: options,
      offset: offset)
  }

  private func result(
    stateID: String,
    observation: Observation,
    includeImage: Bool,
    options: UIObservationOptions,
    offset: Int
  ) async throws -> ObserveUIResult {
    let window = observation.window
    let page = observationPage(
      nodes: observation.nodes, options: options, windowFrame: window.frame, offset: offset)
    let image = includeImage ? try await capture(windowID: window.id) : nil
    return ObserveUIResult(
      stateID: stateID,
      app: window.app,
      title: window.title,
      pageURL: observation.pageURL,
      windowID: Int(window.id),
      outline: render(page.nodes, windowFrame: window.frame),
      nodeCount: page.nodes.count,
      matchedNodeCount: page.matchedNodeCount,
      nextOffset: page.nextOffset,
      treeTruncated: observation.treeTruncated,
      image: image)
  }

  func act(stateID: String, ref: String, action: String, text: String?) throws -> ActUIResult {
    guard accessibilityTrusted(prompt: true) else {
      throw ComputerUseError.accessibilityPermissionMissing
    }
    guard let observation = observations[stateID] else { throw ComputerUseError.stateNotFound(stateID) }
    guard let element = observation.elements[ref] else { throw ComputerUseError.elementNotFound(ref) }

    let status: AXError
    switch action {
    case "press", "confirm", "show_menu", "scroll_to_visible", "increment", "decrement", "scroll_down",
      "scroll_up":
      guard let actionName = semanticAccessibilityActionName(for: action) else {
        throw ComputerUseError.unsupportedAction(action)
      }
      status = AXUIElementPerformAction(element, actionName as CFString)
    case "focus":
      status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    case "set_text":
      guard let text else {
        throw ComputerUseError.accessibilityFailure("set_text requires the text argument.")
      }
      status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
    default:
      throw ComputerUseError.unsupportedAction(action)
    }
    guard status == .success else {
      throw ComputerUseError.accessibilityFailure("\(action) on \(ref) returned AXError \(status.rawValue).")
    }
    return ActUIResult(
      ok: true, stateID: stateID, ref: ref, action: action,
      message: "Performed \(action) on \(ref) in \(observation.window.app). Observe again to inspect the resulting UI.")
  }

  private func accessibilityWindow(for window: WindowRecord) -> AXUIElement? {
    let app = AXUIElementCreateApplication(window.pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    guard let windows = copyAttribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
      return nil
    }
    var matches: [(element: AXUIElement, score: Double)] = []
    for candidate in windows {
      let title = stringAttribute(candidate, kAXTitleAttribute as CFString) ?? ""
      let exactTitleMatch = !window.title.isEmpty && title == window.title

      var frameScore = 0.0
      var closeFrameMatch = false
      if let frame = frameAttribute(candidate) {
        let positionDelta = abs(frame.minX - window.frame.minX) + abs(frame.minY - window.frame.minY)
        let sizeDelta = abs(frame.width - window.frame.width) + abs(frame.height - window.frame.height)
        frameScore = max(0, 50 - positionDelta) + max(0, 50 - sizeDelta)
        closeFrameMatch = positionDelta <= 20 && sizeDelta <= 20
      }

      // Never fall back to the first AX window. Acting on a weak or ambiguous
      // match is worse than asking the caller to observe again.
      guard exactTitleMatch || closeFrameMatch else { continue }
      matches.append((candidate, (exactTitleMatch ? 100 : 0) + frameScore))
    }

    let ranked = matches.sorted { $0.score > $1.score }
    guard let best = ranked.first else { return nil }
    if ranked.count > 1, abs(best.score - ranked[1].score) < 0.001 {
      return nil
    }
    return best.element
  }

  private func buildOutline(
    root: AXUIElement,
    elements: inout [String: AXUIElement],
    maximumDepth: Int
  ) -> ([UIOutlineNode], Bool) {
    // Keep depth-first preorder so indentation represents the real AX hierarchy,
    // while retaining the larger, configurable bounds used by filtered observations.
    let traversalLimit = 5_000
    let traversal = depthFirstPreorder(
      root: root, maxDepth: maximumDepth, maxCount: traversalLimit, maxChildren: 500,
      children: { element in
        self.copyAttribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
      })
    let output = traversal.enumerated().map { index, item in
      let element = item.element
      let ref = "@e\(index + 1)"
      elements[ref] = element
      return UIOutlineNode(
        ref: ref,
        role: stringAttribute(element, kAXRoleAttribute as CFString) ?? "unknown",
        title: stringAttribute(element, kAXTitleAttribute as CFString) ?? "",
        value: displayString(copyAttribute(element, kAXValueAttribute as CFString)),
        nodeDescription: stringAttribute(element, kAXDescriptionAttribute as CFString) ?? "",
        url: normalizedURLString(copyAttribute(element, kAXURLAttribute as CFString)),
        frame: frameAttribute(element),
        actions: actionNames(element),
        depth: item.depth,
        hidden: boolAttribute(element, kAXHiddenAttribute as CFString) ?? false,
        enabled: boolAttribute(element, kAXEnabledAttribute as CFString) ?? true,
        focused: boolAttribute(element, kAXFocusedAttribute as CFString) ?? false,
        selected: boolAttribute(element, kAXSelectedAttribute as CFString) ?? false)
    }
    return (output, traversal.count == traversalLimit)
  }

  private func render(_ nodes: [UIOutlineNode], windowFrame: CGRect) -> String {
    nodes.map { node in
      var fields = [node.ref, normalizeRole(node.role)]
      if !node.title.isEmpty { fields.append("title=\(quoted(node.title))") }
      if !node.value.isEmpty { fields.append("value=\(quoted(node.value))") }
      if !node.nodeDescription.isEmpty && node.nodeDescription != node.title {
        fields.append("description=\(quoted(node.nodeDescription))")
      }
      if !node.url.isEmpty { fields.append("url=\(quoted(node.url))") }
      if !node.actions.isEmpty {
        fields.append("actions=[\(node.actions.map(normalizeAction).joined(separator: ","))]")
      }
      if node.hidden { fields.append("hidden=true") }
      if !node.enabled { fields.append("disabled=true") }
      if node.focused { fields.append("focused=true") }
      if node.selected { fields.append("selected=true") }
      if let frame = node.frame {
        if !frame.intersects(windowFrame) {
          fields.append("offscreen=true")
        } else if !windowFrame.contains(frame) {
          fields.append("clipped=true")
        }
        fields.append("rect=(\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)))")
      }
      return String(repeating: "  ", count: node.depth) + fields.joined(separator: " ")
    }.joined(separator: "\n")
  }

  private func normalizeRole(_ role: String) -> String {
    role.hasPrefix("AX") ? String(role.dropFirst(2)).lowercased() : role.lowercased()
  }

  private func normalizeAction(_ action: String) -> String {
    action.hasPrefix("AX") ? String(action.dropFirst(2)) : action
  }

  private func quoted(_ string: String) -> String {
    let compact = string.replacingOccurrences(of: "\n", with: "\\n")
    return String(reflecting: String(compact.prefix(500)))
  }

  private func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
    copyAttribute(element, attribute) as? String
  }

  private func boolAttribute(_ element: AXUIElement, _ attribute: CFString) -> Bool? {
    (copyAttribute(element, attribute) as? NSNumber)?.boolValue
  }

  private func displayString(_ value: AnyObject?) -> String {
    guard let value else { return "" }
    if CFGetTypeID(value) == AXUIElementGetTypeID() { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
  }

  private func actionNames(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
    return names as? [String] ?? []
  }

  private func frameAttribute(_ element: AXUIElement) -> CGRect? {
    guard let position = copyAttribute(element, kAXPositionAttribute as CFString),
      let size = copyAttribute(element, kAXSizeAttribute as CFString),
      CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
    else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
      AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    else { return nil }
    return CGRect(origin: point, size: dimensions)
  }

  private func capture(windowID: CGWindowID) async throws -> CapturedImage {
    guard CGPreflightScreenCaptureAccess() else {
      _ = CGRequestScreenCaptureAccess()
      throw ComputerUseError.screenRecordingPermissionMissing
    }
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
      throw ComputerUseError.windowNotFound(Int(windowID))
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = max(1, Int(window.frame.width * 2))
    configuration.height = max(1, Int(window.frame.height * 2))
    configuration.showsCursor = false
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter, configuration: configuration)
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
      throw ComputerUseError.captureFailure("Could not encode the captured window as JPEG.")
    }
    return CapturedImage(base64: data.base64EncodedString(), width: image.width, height: image.height)
  }
}

struct CapturedImage: Sendable {
  let base64: String
  let width: Int
  let height: Int
}

public struct FindWindowsResult: Encodable, Sendable {
  public struct Window: Encodable, Sendable {
    let windowID: Int
    let pid: Int32
    let app: String
    let title: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let onscreen: Bool
  }
  let ok = true
  let windows: [Window]
}

public struct ObserveUIResult: Encodable, AttachableToolResult, Sendable {
  let ok = true
  let stateID: String
  let app: String
  let title: String
  let pageURL: String
  let windowID: Int
  let outline: String
  let nodeCount: Int
  let matchedNodeCount: Int
  let nextOffset: Int?
  let treeTruncated: Bool
  let image: CapturedImage?

  public var toolAttachments: [ToolAttachment] {
    guard let image else { return [] }
    return [ToolAttachment(mimeType: "image/jpeg", base64: image.base64)]
  }

  public var attachmentToolResultText: String? {
    let location = pageURL.isEmpty ? "" : " — \(pageURL)"
    return
      "Observed \(app) — \(title)\(location) (window \(windowID), stateId \(stateID), \(nodeCount) of \(matchedNodeCount) matching nodes).\n\(outline)"
  }

  enum CodingKeys: String, CodingKey {
    case ok, app, title, outline
    case pageURL = "page_url"
    case stateID = "state_id"
    case windowID = "window_id"
    case nodeCount = "node_count"
    case matchedNodeCount = "matched_node_count"
    case nextOffset = "next_offset"
    case treeTruncated = "tree_truncated"
  }
}

public struct ActUIResult: Encodable, Sendable {
  let ok: Bool
  let stateID: String
  let ref: String
  let action: String
  let message: String

  enum CodingKeys: String, CodingKey {
    case ok, ref, action, message
    case stateID = "state_id"
  }
}

public struct FindWindowsTool: ScribeTool {
  public static let name = "find_windows"
  public static let description = "Find visible macOS app windows using native WindowServer and Accessibility APIs."
  public static let parameters = [
    ScribeToolParameter(
      name: "query", type: .string,
      description: "Optional case-insensitive app-name or window-title filter.", required: false)
  ]
  public static let promptHint: String? =
    "For macOS computer use, call find_windows, then observe_ui with a returned window_id. Use only refs from that observation with its state_id. Prefer semantic act_ui actions over shell-driven UI automation."
  private let session: ComputerUseSession

  public init(session: ComputerUseSession) { self.session = session }

  public func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    let arguments = try parseArguments(arguments)
    let records = try await session.findWindows(query: arguments["query"] as? String)
    return FindWindowsResult(
      windows: records.map {
        .init(
          windowID: Int($0.id), pid: $0.pid, app: $0.app, title: $0.title,
          x: Int($0.frame.minX), y: Int($0.frame.minY), width: Int($0.frame.width),
          height: Int($0.frame.height), onscreen: $0.onscreen)
      })
  }
}

public struct ObserveUITool: ScribeTool {
  public static let name = "observe_ui"
  public static let description =
    "Observe and search one macOS window through Accessibility, with deterministic pagination and an optional ScreenCaptureKit image. Returns a state_id and element refs for act_ui."
  public static let parameters = [
    ScribeToolParameter(
      name: "window_id", type: .integer,
      description: "Window id returned by find_windows; required for a new observation.", required: false),
    ScribeToolParameter(
      name: "state_id", type: .string,
      description: "Prior observation state to paginate without rebuilding the Accessibility tree.",
      required: false),
    ScribeToolParameter(
      name: "include_image", type: .boolean, description: "Attach a window screenshot; defaults to false.",
      required: false),
    ScribeToolParameter(
      name: "visible_only", type: .boolean,
      description: "Only include non-hidden nodes intersecting the window.", required: false),
    ScribeToolParameter(
      name: "viewport_only", type: .boolean,
      description: "Only include nodes whose frames intersect the observed window.", required: false),
    ScribeToolParameter(
      name: "interactive_only", type: .boolean,
      description: "Only include enabled actionable controls and links.", required: false),
    ScribeToolParameter(
      name: "roles", type: .array,
      description: "Optional role names such as link, button, or textfield (case-insensitive).",
      required: false),
    ScribeToolParameter(
      name: "query", type: .string,
      description: "Case-insensitive search across title, value, and description.", required: false),
    ScribeToolParameter(
      name: "max_depth", type: .integer,
      description: "Maximum Accessibility-tree depth; defaults to 12, maximum 30.", required: false),
    ScribeToolParameter(
      name: "max_nodes", type: .integer,
      description: "Maximum matching nodes returned; defaults to 200, maximum 500.", required: false),
    ScribeToolParameter(
      name: "offset", type: .integer,
      description: "Matching-node offset returned as next_offset by a prior observation.", required: false),
  ]
  public static let promptHint: String? = nil
  private let session: ComputerUseSession

  public init(session: ComputerUseSession) { self.session = session }

  public func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    let arguments = try parseArguments(arguments)
    let roles = (arguments["roles"] as? [String] ?? []).map {
      $0.hasPrefix("AX") ? String($0.dropFirst(2)).lowercased() : $0.lowercased()
    }
    let options = UIObservationOptions(
      visibleOnly: arguments["visible_only"] as? Bool ?? false,
      viewportOnly: arguments["viewport_only"] as? Bool ?? false,
      interactiveOnly: arguments["interactive_only"] as? Bool ?? false,
      roles: Set(roles),
      query: arguments["query"] as? String,
      maximumDepth: min(30, max(0, integer(arguments["max_depth"]) ?? 12)),
      maximumNodeCount: min(500, max(1, integer(arguments["max_nodes"]) ?? 200)))
    let offset = max(0, integer(arguments["offset"]) ?? 0)
    let includeImage = arguments["include_image"] as? Bool ?? false
    if let stateID = arguments["state_id"] as? String {
      return try await session.continueObservation(
        stateID: stateID,
        includeImage: includeImage,
        options: options,
        offset: offset)
    }
    guard let id = integer(arguments["window_id"]) else {
      throw ComputerUseError.accessibilityFailure(
        "observe_ui requires window_id for a new observation or state_id for continuation.")
    }
    return try await session.observe(
      windowID: id,
      includeImage: includeImage,
      options: options,
      offset: offset)
  }
}

public struct ActUITool: ScribeTool {
  public static let name = "act_ui"
  public static let description =
    "Perform a native semantic Accessibility action on an element from observe_ui. Supported actions: press, confirm, show_menu, scroll_to_visible, focus, set_text, increment, decrement, scroll_down, scroll_up. Use an action advertised on the element when possible."
  public static let parameters = [
    ScribeToolParameter(name: "state_id", type: .string, description: "State id returned by observe_ui."),
    ScribeToolParameter(name: "ref", type: .string, description: "Element ref such as @e12 from the same observation."),
    ScribeToolParameter(
      name: "action", type: .string,
      description:
        "press, confirm, show_menu, scroll_to_visible, focus, set_text, increment, decrement, scroll_down, or scroll_up. Prefer an action listed by observe_ui."
    ),
    ScribeToolParameter(
      name: "text", type: .string, description: "Text for set_text; omit for other actions.", required: false),
  ]
  public static let promptHint: String? = nil
  private let session: ComputerUseSession

  public init(session: ComputerUseSession) { self.session = session }

  public func run(arguments: String, workingDirectory: FilePath, logger: Logger) async throws -> Encodable {
    let arguments = try parseArguments(arguments)
    guard let stateID = arguments["state_id"] as? String,
      let ref = arguments["ref"] as? String,
      let action = arguments["action"] as? String
    else { throw ComputerUseError.accessibilityFailure("act_ui requires state_id, ref, and action.") }
    return try await session.act(
      stateID: stateID, ref: ref, action: action, text: arguments["text"] as? String)
  }
}

private func accessibilityTrusted(prompt: Bool) -> Bool {
  guard prompt else { return AXIsProcessTrusted() }
  return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
}

private func parseArguments(_ arguments: String) throws -> [String: Any] {
  let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return [:] }
  guard let object = try JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
    throw ComputerUseError.accessibilityFailure("Tool arguments must be a JSON object.")
  }
  return object
}

private func integer(_ value: Any?) -> Int? {
  if let value = value as? Int { return value }
  if let value = value as? NSNumber { return value.intValue }
  return nil
}

public enum ComputerUseTools {
  // TODO: Is this needed? Can we put the tools in there own files.
  public static func make() -> [any ScribeTool] {
    let session = ComputerUseSession()
    return [FindWindowsTool(session: session), ObserveUITool(session: session), ActUITool(session: session)]
  }
}
#else
import ScribeCore

public enum ComputerUseTools {
  public static func make() -> [any ScribeTool] { [] }
}
#endif
