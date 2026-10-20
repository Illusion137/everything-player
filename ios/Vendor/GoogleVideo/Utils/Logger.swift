import Foundation

enum LogLevel: Int, Sendable {
    case none = 0
    case error = 1
    case warn = 2
    case info = 3
    case debug = 4
    case all = 99

    var label: String {
        switch self {
        case .none: return "NONE"
        case .error: return "ERROR"
        case .warn: return "WARN"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        case .all: return "ALL"
        }
    }
}

final class Logger: @unchecked Sendable {
    private static let instance = Logger()
    private let lock = NSLock()
    private var currentLogLevels: Set<LogLevel> = [.error, .warn]

    static func getInstance() -> Logger {
        return instance
    }

    func setLogLevels(_ levels: LogLevel...) {
        lock.lock()
        defer { lock.unlock() }

        if levels.isEmpty || levels.contains(.none) {
            currentLogLevels = []
        } else if levels.contains(.all) {
            currentLogLevels = [.error, .warn, .info, .debug]
        } else {
            currentLogLevels = Set(levels.filter { $0 != .none && $0 != .all })
        }
    }

    func getLogLevels() -> Set<LogLevel> {
        lock.lock()
        defer { lock.unlock() }
        return currentLogLevels
    }

    private func log(_ level: LogLevel, _ tag: String, _ messages: [Any]) {
        if level != .none && getLogLevels().contains(level) {
            let prefix = "[\(level.label)] [\(tag)]"
            let line = ([prefix] + messages.map { String(describing: $0) }).joined(separator: " ")
            NSLog("%@", line)
        }
    }

    func error(_ tag: String, _ messages: Any...) {
        log(.error, tag, messages)
    }

    func warn(_ tag: String, _ messages: Any...) {
        log(.warn, tag, messages)
    }

    func info(_ tag: String, _ messages: Any...) {
        log(.info, tag, messages)
    }

    func debug(_ tag: String, _ messages: Any...) {
        log(.debug, tag, messages)
    }
}
