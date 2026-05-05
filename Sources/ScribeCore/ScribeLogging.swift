// Logging infrastructure (ScribeLogLevel, LockedDataWriter, FileSink,
// ScribeLineLogHandler, and AgentConfig.makeSessionLogger) has moved to
// ScribeCLI/ConfigLoader.swift.  Core targets consume `swift-log` Logger
// directly — callers provide their own Logger instances.
