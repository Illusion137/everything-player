import Foundation

enum MediaType: String, Sendable {
    case audio
    case video
}

func wait(_ ms: Int) async {
    try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
}

func nowMs() -> Double {
    return Date().timeIntervalSince1970 * 1000
}

func assert(_ condition: Bool, _ msg: String) throws {
    if !condition { throw GoogleVideoError(msg) }
}

@discardableResult
func assertIsDefined<T>(_ val: T?, _ msg: String? = nil) throws -> T {
    guard let val else {
        throw GoogleVideoError(msg ?? "Expected value to be defined, but got nil")
    }
    return val
}

func getMediaType(_ mimeType: String?) -> MediaType {
    return mimeType?.contains("audio") == true ? .audio : .video
}

struct OrderedMap<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []

    init() {}

    init(_ entries: [(Key, Value)]) {
        for (key, value) in entries {
            self[key] = value
        }
    }

    var count: Int { order.count }

    var keys: [Key] { order }

    var values: [Value] { order.map { storage[$0]! } }

    var entries: [(key: Key, value: Value)] { order.map { ($0, storage[$0]!) } }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil {
                    order.append(key)
                }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    func has(_ key: Key) -> Bool {
        return storage[key] != nil
    }

    @discardableResult
    mutating func removeValue(forKey key: Key) -> Value? {
        guard let removed = storage.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return removed
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }
}

final class AbortController: @unchecked Sendable {
    private let lock = NSLock()
    private var _aborted = false

    init() {}

    var aborted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _aborted
    }

    func onAbort(_ cancel: @escaping @Sendable () -> Void) {
        lock.lock()
        let alreadyAborted = _aborted
        if !alreadyAborted {
            cancellers.append(cancel)
        }
        lock.unlock()

        if alreadyAborted { cancel() }
    }

    private var cancellers: [@Sendable () -> Void] = []

    func abort() {
        lock.lock()
        if _aborted {
            lock.unlock()
            return
        }
        _aborted = true
        let pending = cancellers
        cancellers = []
        lock.unlock()

        for cancel in pending { cancel() }
    }
}

func errorMessage(_ error: any Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
        return description
    }
    return String(describing: error)
}
