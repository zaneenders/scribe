import Foundation
import Logging
import SystemPackage

extension System {
    /// Global log level this might change based on release or not.
    private static let log_level: Logger.Level = .trace

    /// Globally configure how logging is to be recorded.
    public static func enableLogging(tracing: Bool, write_to_file: Bool) {
        LoggingSystem.bootstrap { _ in
            System.ScribeLogging(logLevel: log_level, tracing: tracing, write_to_file: write_to_file)
        }
    }

}

extension System {
    // TODO document what the various log levels are to be used for.
    public enum Log {
        static let file_path = FilePath("\(FileManager.default.currentDirectoryPath)/log.txt")
        @TaskLocal
        static var id: UInt128 = UInt128.random(in: UInt128.min..<UInt128.max)

        private static let logger = Logger(label: "scribe")

        public static func trace(_ msg: Logger.Message) {
            logger.trace(msg)
        }

        public static func debug(_ msg: Logger.Message) {
            logger.debug(msg)
        }

        public static func info(_ msg: Logger.Message) {
            logger.info(msg)
        }

        public static func notice(_ msg: Logger.Message) {
            logger.notice(msg)
        }

        public static func warning(_ msg: Logger.Message) {
            logger.warning(msg)
        }

        public static func error(_ msg: Logger.Message) {
            logger.error(msg)
        }

        public static func critical(_ msg: Logger.Message) {
            logger.critical(msg)
        }
    }

    public static func clearLog() {
        do {
            let fd = try FileDescriptor.open(
                Log.file_path, .readWrite, options: [.truncate, .create], permissions: .ownerReadWrite)
            try fd.close()
        } catch {
            System.Log.critical("Unable to create log file: \(Log.file_path.string)")
        }
    }
}
