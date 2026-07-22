import Testing

@testable import ScribeCore

@Test
func codexToolCallIdentifiersRoundTrip() {
  let identifiers = CodexToolCallIdentifiers(callID: "call_abc123", itemID: "fc_def456")

  #expect(identifiers.encoded == "call_abc123|fc_def456")
  #expect(CodexToolCallIdentifiers(encoded: identifiers.encoded) == identifiers)
}

@Test
func codexToolCallIdentifiersSupportLegacyUnencodedIDs() {
  let identifiers = CodexToolCallIdentifiers(encoded: "call_abc123")

  #expect(identifiers.callID == "call_abc123")
  #expect(identifiers.itemID == "fc_call_abc123")
}

@Test
func codexToolCallIdentifiersSanitizeForeignProviderIDs() {
  // Mid-session model switch left this non-Codex ID in the history; the ChatGPT
  // backend rejected it with: Expected an ID that begins with 'fc'.
  let identifiers = CodexToolCallIdentifiers(encoded: "tool_3AXlpi3mBRnQCMzIr7HgDba0")

  #expect(identifiers.callID == "call_tool_3AXlpi3mBRnQCMzIr7HgDba0")
  #expect(identifiers.itemID == "fc_tool_3AXlpi3mBRnQCMzIr7HgDba0")
}

@Test
func codexToolCallIdentifiersSanitizeEmptyIDsDeterministically() {
  let first = CodexToolCallIdentifiers(encoded: "")
  let second = CodexToolCallIdentifiers(encoded: "")

  #expect(first == second)
  #expect(first.callID.hasPrefix("call_"))
  #expect(first.itemID.hasPrefix("fc_"))
}

@Test
func codexAssistantTurnPreservesResponseItemID() {
  var turn = CodexAssistantTurn()
  turn.finalizeToolCall(
    outputIndex: 0,
    callID: "call_abc123",
    itemID: "fc_def456",
    name: "shell",
    arguments: #"{"command":"pwd"}"#)

  let invocation = turn.resolvedToolCalls().first

  #expect(invocation?.id == "call_abc123|fc_def456")
  #expect(invocation?.name == "shell")
}
