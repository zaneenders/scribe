import Foundation
import Logging
import SystemPackage

extension System {

    struct ScribeLogging: LogHandler {

        var metadata: Logging.Logger.Metadata
        var logLevel: Logging.Logger.Level
        let dateFormatter: DateFormatter
        private let tracing: Bool
        // TODO pass in name context to logger for file path or something.
        private let write_to_file: Bool
        internal init(
            metadata: Logger.Metadata = [:], logLevel: Logger.Level = .trace, tracing: Bool, write_to_file: Bool
        ) {
            self.metadata = metadata
            self.logLevel = logLevel
            self.tracing = tracing
            self.write_to_file = write_to_file
            let df = DateFormatter()
            df.dateFormat = "mm_ss_SSSS"
            self.dateFormatter = df
        }

        subscript(metadataKey _: String) -> Logging.Logger.Metadata.Value? {
            get {
                nil
            }
            set(newValue) {
            }
        }

        func log(
            level: Logger.Level,
            message: Logger.Message,
            metadata: Logger.Metadata?,
            source: String, file: String,
            function: String, line: UInt
        ) {
            switch (tracing, write_to_file) {
            case (_, true):
                logFile(level, message, tracing)
            case (true, false):
                tracing(level, message)
            case (false, false):
                terminal(level, message)
            }
        }

        // Hacky log to file.
        private func logFile(_ level: Logger.Level, _ message: Logger.Message, _ tracing: Bool) {
            let formattedDate = dateFormatter.string(from: Date.now)
            var out = "\(formattedDate)"
            switch tracing {
            case true:
                out += "<\(Log.id)>"
            case false:
                ()
            }
            out += "[\("\(level)".uppercased())]: \(message)\n"
            do {
                let fd = try FileDescriptor.open(
                    Log.file_path, .readWrite, options: [.append], permissions: .ownerReadWrite)
                try fd.writeAll(out.utf8)
                try fd.close()
            } catch {
                fatalError("Unable to create log file: \(Log.file_path.string)")
            }
        }

        private func terminal(_ level: Logger.Level, _ message: Logger.Message) {
            let color: Chroma.Color
            switch level {
            case .trace:
                color = .default
            case .debug:
                color = .teal
            case .info:
                color = .green
            case .notice:
                color = .purple
            case .warning:
                color = .yellow
            case .error:
                color = .orange
            case .critical:
                color = .red
            }
            print(Chroma.wrap("\(message)", color, .default))
        }

        private func tracing(_ level: Logger.Level, _ message: Logger.Message) {
            print("\(System.Log.id):[\("\(level)".uppercased())]\(message)")
        }
    }
}
