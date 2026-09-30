import Testing

@testable import ScribeCore

@Test
func responsesToolCallIdentifiersRoundTrip() {
  let identifiers = ResponsesToolCallIdentifiers(callID: "call_abc123", itemID: "fc_def456")

  #expect(identifiers.encoded == "call_abc123|fc_def456")
  #expect(ResponsesToolCallIdentifiers(encoded: identifiers.encoded) == identifiers)
}

@Test
func responsesToolCallIdentifiersSupportLegacyUnencodedIDs() {
  let identifiers = ResponsesToolCallIdentifiers(encoded: "call_abc123")

  #expect(identifiers.callID == "call_abc123")
  #expect(identifiers.itemID == "fc_call_abc123")
}

@Test
func responsesToolCallIdentifiersSanitizeForeignProviderIDs() {
  let identifiers = ResponsesToolCallIdentifiers(encoded: "tool_3AXlpi3mBRnQCMzIr7HgDba0")

  #expect(identifiers.callID == "call_tool_3AXlpi3mBRnQCMzIr7HgDba0")
  #expect(identifiers.itemID == "fc_tool_3AXlpi3mBRnQCMzIr7HgDba0")
}

@Test
func responsesToolCallIdentifiersSanitizeEmptyIDsDeterministically() {
  let first = ResponsesToolCallIdentifiers(encoded: "")
  let second = ResponsesToolCallIdentifiers(encoded: "")

  #expect(first == second)
  #expect(first.callID.hasPrefix("call_"))
  #expect(first.itemID.hasPrefix("fc_"))
}

@Test
func responsesAssistantTurnPreservesResponseItemID() {
  var turn = ResponsesAssistantTurn()
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
