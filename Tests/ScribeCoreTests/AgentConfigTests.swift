import Foundation
import ScribeCore
import Testing

/// Tests for `AgentConfig`, focusing on the `maxContextMessages` field
/// introduced for rope-driven viewport windowing.
@Suite
struct AgentConfigTests {

  // MARK: - maxContextMessages default

  @Test func defaultMaxContextMessagesIs400() {
    let config = AgentConfig(agentModel: "test-model")
    #expect(config.maxContextMessages == 400)
  }

  @Test func customMaxContextMessagesIsStored() {
    let config = AgentConfig(
      agentModel: "test-model",
      maxContextMessages: 100
    )
    #expect(config.maxContextMessages == 100)
  }

  @Test func nilMaxContextMessagesMeansNoLimit() {
    let config = AgentConfig(
      agentModel: "test-model",
      maxContextMessages: nil
    )
    #expect(config.maxContextMessages == nil)
  }

  // MARK: - Full initializer smoke

  @Test func allFieldsPersistThroughInit() {
    let config = AgentConfig(
      agentModel: "llama3.2",
      contextWindow: 8192,
      contextWindowThreshold: 0.75,
      maxContextMessages: 50,
      serverURL: "http://localhost:11434",
      bearerToken: "sk-test"
    )
    #expect(config.agentModel == "llama3.2")
    #expect(config.contextWindow == 8192)
    #expect(config.contextWindowThreshold == 0.75)
    #expect(config.maxContextMessages == 50)
    #expect(config.serverURL == "http://localhost:11434")
    #expect(config.bearerToken == "sk-test")
  }

  // MARK: - Sendable conformance

  @Test func agentConfigIsSendable() {
    let config = AgentConfig(agentModel: "m")
    let taskVal = { () -> AgentConfig in config }
    _ = taskVal  // compiles only if Sendable
  }
}
