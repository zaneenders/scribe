import Foundation
import Logging
import ScribeCore
import Synchronization
import Testing

@testable import ScribeCLI

// MARK: - ScribeLogLevel tests

@Suite
struct ScribeLogLevelTests {
  @Test
  func parsingValidLevels() {
    #expect(ScribeLogLevel(parsingConfig: "trace") == .trace)
    #expect(ScribeLogLevel(parsingConfig: "debug") == .debug)
    #expect(ScribeLogLevel(parsingConfig: "info") == .info)
    #expect(ScribeLogLevel(parsingConfig: "notice") == .notice)
    #expect(ScribeLogLevel(parsingConfig: "warning") == .warning)
    #expect(ScribeLogLevel(parsingConfig: "error") == .error)
  }

  @Test
  func parsingCaseInsensitive() {
    #expect(ScribeLogLevel(parsingConfig: "TRACE") == .trace)
    #expect(ScribeLogLevel(parsingConfig: "Debug") == .debug)
    #expect(ScribeLogLevel(parsingConfig: "INFO") == .info)
  }

  @Test
  func parsingTrimsWhitespace() {
    #expect(ScribeLogLevel(parsingConfig: "  info  ") == .info)
    #expect(ScribeLogLevel(parsingConfig: "\ttrace\t") == .trace)
  }

  @Test
  func parsingEmptyStringReturnsNil() {
    #expect(ScribeLogLevel(parsingConfig: "") == nil)
    #expect(ScribeLogLevel(parsingConfig: "   ") == nil)
  }

  @Test
  func parsingInvalidLevelReturnsNil() {
    #expect(ScribeLogLevel(parsingConfig: "verbose") == nil)
    #expect(ScribeLogLevel(parsingConfig: "critical") == nil)
    #expect(ScribeLogLevel(parsingConfig: "garbage") == nil)
  }

  @Test
  func priorityOrder() {
    #expect(ScribeLogLevel.trace.priority == 0)
    #expect(ScribeLogLevel.debug.priority == 1)
    #expect(ScribeLogLevel.info.priority == 2)
    #expect(ScribeLogLevel.notice.priority == 3)
    #expect(ScribeLogLevel.warning.priority == 4)
    #expect(ScribeLogLevel.error.priority == 5)
  }

  @Test
  func prioritiesAreMonotonicallyIncreasing() {
    let levels = ScribeLogLevel.allCases
    for i in 1..<levels.count {
      #expect(levels[i].priority > levels[i - 1].priority)
    }
  }

  @Test
  func swiftLogLevelMapping() {
    #expect(ScribeLogLevel.trace.swiftLogLevel == .trace)
    #expect(ScribeLogLevel.debug.swiftLogLevel == .debug)
    #expect(ScribeLogLevel.info.swiftLogLevel == .info)
    #expect(ScribeLogLevel.notice.swiftLogLevel == .notice)
    #expect(ScribeLogLevel.warning.swiftLogLevel == .warning)
    #expect(ScribeLogLevel.error.swiftLogLevel == .error)
  }

  @Test
  func allCasesContainsAllLevels() {
    let all = Set(ScribeLogLevel.allCases)
    #expect(all.count == 6)
    #expect(all.contains(.trace))
    #expect(all.contains(.debug))
    #expect(all.contains(.info))
    #expect(all.contains(.notice))
    #expect(all.contains(.warning))
    #expect(all.contains(.error))
  }
}

// MARK: - LockedDataWriter tests

@Suite
struct LockedDataWriterTests {
  @Test
  func writesDataToHandler() async {
    let written = Mutex<[Data]>([])
    let writer = LockedDataWriter { data in
      written.withLock { $0.append(data) }
    }
    writer.write(Data("hello".utf8))
    writer.write(Data(" world".utf8))

    let all = written.withLock { $0 }
    #expect(all.count == 2)
    #expect(String(data: all[0], encoding: .utf8) == "hello")
    #expect(String(data: all[1], encoding: .utf8) == " world")
  }

  @Test
  func concurrentWritesDontLoseData() async {
    let written = Mutex<[Data]>([])
    let writer = LockedDataWriter { data in
      written.withLock { $0.append(data) }
    }
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<100 {
        group.addTask {
          writer.write(Data("msg-\(i)".utf8))
        }
      }
    }
    let all = written.withLock { $0 }
    #expect(all.count == 100)
  }
}

// MARK: - ScribeLineLogHandler tests

@Suite
struct ScribeLineLogHandlerTests {
  @Test
  func formatsLogLineWithTimestamp() throws {
    let captured = Mutex<Data>(Data())
    let writer = LockedDataWriter { data in captured.withLock { $0.append(data) } }

    let handler = ScribeLineLogHandler(minimumLevel: .info, dataWriter: writer)
    let event = LogEvent(
      level: .info, message: Logger.Message(stringLiteral: "hello world"),
      error: nil, metadata: nil, source: "", file: "", function: "", line: 0)
    handler.log(event: event)

    let line = try #require(String(data: captured.withLock { $0 }, encoding: .utf8))
    #expect(line.contains("[info]"))
    #expect(line.contains("hello world"))
    #expect(line.hasSuffix("\n"))
    // Should have ISO8601 timestamp prefix.
    #expect(line.contains("T"))
  }

  @Test
  func formatsLogLineWithMetadata() throws {
    let captured = Mutex<Data>(Data())
    let writer = LockedDataWriter { data in captured.withLock { $0.append(data) } }

    let handler = ScribeLineLogHandler(minimumLevel: .debug, dataWriter: writer)
    let event = LogEvent(
      level: .debug, message: Logger.Message(stringLiteral: "test event"),
      error: nil,
      metadata: ["key1": "value1", "key2": "value2"],
      source: "", file: "", function: "", line: 0)
    handler.log(event: event)

    let line = try #require(String(data: captured.withLock { $0 }, encoding: .utf8))
    #expect(line.contains("[debug]"))
    #expect(line.contains("test event"))
    #expect(line.contains("key1=value1"))
    #expect(line.contains("key2=value2"))
  }

  @Test
  func formatsLogLineWithError() throws {
    let captured = Mutex<Data>(Data())
    let writer = LockedDataWriter { data in captured.withLock { $0.append(data) } }

    let handler = ScribeLineLogHandler(minimumLevel: .error, dataWriter: writer)
    let event = LogEvent(
      level: .error, message: Logger.Message(stringLiteral: "boom"),
      error: ScribeError.generic("something went wrong"),
      metadata: nil, source: "", file: "", function: "", line: 0)
    handler.log(event: event)

    let line = try #require(String(data: captured.withLock { $0 }, encoding: .utf8))
    #expect(line.contains("[error]"))
    #expect(line.contains("boom"))
    #expect(line.contains("something went wrong"))
  }

  @Test
  func metadataGetter() {
    let captured = Mutex<Data>(Data())
    let writer = LockedDataWriter { data in captured.withLock { $0.append(data) } }
    var handler = ScribeLineLogHandler(minimumLevel: .info, dataWriter: writer)
    handler.metadata["session_id"] = "123"
    #expect(handler.metadata["session_id"] == "123")
  }

  @Test
  func respectsMinimumLevel() {
    let captured = Mutex<Data>(Data())
    let writer = LockedDataWriter { data in captured.withLock { $0.append(data) } }
    let handler = ScribeLineLogHandler(minimumLevel: .warning, dataWriter: writer)
    #expect(handler.logLevel == .warning)
    _ = captured  // silence unused warning
  }
}

// MARK: - LoadedConfig.makeClient tests

@Suite
struct LoadedConfigMakeClientTests {
  @Test
  func validURLReturnsClient() throws {
    let config = LoadedConfig(
      scribeConfig: ScribeConfig(
        agentModel: "test", contextWindow: 4096, contextWindowThreshold: 0.8,
        serverURL: "http://127.0.0.1:11434", apiKey: nil, tools: [],
        workingDirectory: "/tmp"),
      apiBaseURL: "http://127.0.0.1:11434",
      apiKey: nil,
      logLevel: .info,
      logDirectoryPath: "/tmp/logs",
      chatSessionsDirectoryPath: "/tmp/sessions",
      resolvedConfigurationPath: "/tmp/config.json",
      paths: ScribePaths(dataHome: "/tmp/.scribe")
    )
    let client = try config.makeClient()
    _ = client
    #expect(Bool(true))
  }

  @Test
  func invalidURLThrows() {
    let config = LoadedConfig(
      scribeConfig: ScribeConfig(
        agentModel: "test", contextWindow: 4096, contextWindowThreshold: 0.8,
        serverURL: "", apiKey: nil, tools: [],
        workingDirectory: "/tmp"),
      apiBaseURL: "",
      apiKey: nil,
      logLevel: .info,
      logDirectoryPath: "/tmp/logs",
      chatSessionsDirectoryPath: "/tmp/sessions",
      resolvedConfigurationPath: "/tmp/config.json",
      paths: ScribePaths(dataHome: "/tmp/.scribe")
    )
    #expect(throws: ScribeError.self) {
      _ = try config.makeClient()
    }
  }
}

// MARK: - LoadedConfig.makeSessionLogger tests

@Suite
struct LoadedConfigMakeSessionLoggerTests {
  @Test
  func createsLogFile() throws {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-log-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let config = LoadedConfig(
      scribeConfig: ScribeConfig(
        agentModel: "test", contextWindow: 4096, contextWindowThreshold: 0.8,
        serverURL: "http://127.0.0.1:11434", apiKey: nil, tools: [],
        workingDirectory: "/tmp"),
      apiBaseURL: "http://127.0.0.1:11434",
      apiKey: nil,
      logLevel: .info,
      logDirectoryPath: tmpDir.path,
      chatSessionsDirectoryPath: "/tmp/sessions",
      resolvedConfigurationPath: "/tmp/config.json",
      paths: ScribePaths(dataHome: "/tmp/.scribe")
    )

    let sessionId = UUID()
    let logger = config.makeSessionLogger(sessionId: sessionId)

    // The log file should exist.
    let logFile = tmpDir.appendingPathComponent("scribe-\(sessionId.uuidString).log")
    #expect(FileManager.default.fileExists(atPath: logFile.path))

    // Writing a log message should not crash.
    logger.info("test message")
  }
}

// MARK: - ConfigLoader integration tests

// These tests set SCRIBE_CONFIG_PATH which is process-wide, so they must run serially.
@Suite(.serialized)
struct ConfigLoaderIntegrationTests {
  /// Helper to create a temp config file and return its path.
  private func makeTempConfig(_ content: String) throws -> String {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("scribe-config-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("scribe-config.json")
    try content.write(to: file, atomically: true, encoding: .utf8)
    return file.path
  }

  @Test
  func loadsValidConfig() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "test-model", "contextWindow": 4096, "contextWindowThreshold": 0.8 },
        "logging": { "level": "info" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    let loaded = try await ConfigLoader.load()

    #expect(loaded.apiBaseURL == "http://127.0.0.1:11434")
    #expect(loaded.apiKey == nil)
    #expect(loaded.logLevel == .info)
    #expect(loaded.scribeConfig.agentModel == "test-model")
    #expect(loaded.scribeConfig.contextWindow == 4096)
    #expect(loaded.scribeConfig.contextWindowThreshold == 0.8)
    // Resolved path should be the config file.
    #expect(loaded.resolvedConfigurationPath == configPath)
  }

  @Test
  func loadsConfigWithAPIKey() async throws {
    let json = """
      {
        "api": { "baseUrl": "https://api.openai.com", "apiKey": "sk-secret" },
        "agent": { "model": "gpt-4", "contextWindow": 128000, "contextWindowThreshold": 0.9 },
        "logging": { "level": "debug" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    let loaded = try await ConfigLoader.load()

    #expect(loaded.apiBaseURL == "https://api.openai.com")
    #expect(loaded.apiKey == "sk-secret")
    #expect(loaded.scribeConfig.apiKey == "sk-secret")
    #expect(loaded.logLevel == .debug)
  }

  @Test
  func emptyAPIKeyBecomesNil() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0.5 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    let loaded = try await ConfigLoader.load()
    #expect(loaded.apiKey == nil)
    #expect(loaded.scribeConfig.apiKey == nil)
  }

  @Test
  func whitespaceOnlyAPIKeyBecomesNil() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "   " },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0.5 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    let loaded = try await ConfigLoader.load()
    #expect(loaded.apiKey == nil)
  }

  @Test
  func throwsWhenMissingAPIBaseURL() async throws {
    let json = """
      {
        "api": { "baseUrl": "", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0.5 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenMissingModel() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "", "contextWindow": 4096, "contextWindowThreshold": 0.5 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenContextWindowIsZero() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": 0, "contextWindowThreshold": 0.5 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenContextWindowIsNegative() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": -1, "contextWindowThreshold": 0.5 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenContextWindowThresholdIsZero() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenContextWindowThresholdIsNegative() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": -0.1 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenMissingAPIKey() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434" },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0.5 },
        "logging": { "level": "trace" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenInvalidLogLevel() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0.5 },
        "logging": { "level": "verbose" }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func throwsWhenConfigFileNotFound() async throws {
    let nonexistent = "/tmp/scribe-nonexistent-config-\(UUID().uuidString).json"
    setenv("SCRIBE_CONFIG_PATH", nonexistent, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: ScribeError.self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func allLogLevelsParseCorrectly() async throws {
    for level in ["trace", "debug", "info", "notice", "warning", "error"] {
      let json = """
        {
          "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
          "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0.5 },
          "logging": { "level": "\(level)" }
        }
        """
      let configPath = try makeTempConfig(json)
      setenv("SCRIBE_CONFIG_PATH", configPath, 1)

      let loaded = try await ConfigLoader.load()
      #expect(loaded.logLevel.rawValue == level, "Expected log level \(level)")

      unsetenv("SCRIBE_CONFIG_PATH")
    }
  }

  @Test
  func emptyConfigFileThrows() async throws {
    let configPath = try makeTempConfig("")
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: (any Error).self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func invalidJSONThrows() async throws {
    let json = "{ not valid json at all ["
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: (any Error).self) {
      _ = try await ConfigLoader.load()
    }
  }

  @Test
  func missingLoggingSectionThrows() async throws {
    let json = """
      {
        "api": { "baseUrl": "http://127.0.0.1:11434", "apiKey": "" },
        "agent": { "model": "m", "contextWindow": 4096, "contextWindowThreshold": 0.5 }
      }
      """
    let configPath = try makeTempConfig(json)
    setenv("SCRIBE_CONFIG_PATH", configPath, 1)
    defer { unsetenv("SCRIBE_CONFIG_PATH") }

    await #expect(throws: (any Error).self) {
      _ = try await ConfigLoader.load()
    }
  }
}
