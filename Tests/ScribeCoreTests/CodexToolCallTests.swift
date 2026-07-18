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
  #expect(identifiers.itemID == "call_abc123")
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
