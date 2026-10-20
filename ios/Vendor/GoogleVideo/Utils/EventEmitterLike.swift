import Foundation

struct EventName<Payload>: @unchecked Sendable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

final class EventListenerToken: Hashable, @unchecked Sendable {
    static func == (lhs: EventListenerToken, rhs: EventListenerToken) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

class EventEmitterLike: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var listeners: [String: [(token: EventListenerToken, listener: (Any) -> Void)]] = [:]

    init() {}

    func emit<P>(_ type: EventName<P>, _ payload: P) {
        lock.lock()
        let snapshot = listeners[type.name] ?? []
        lock.unlock()

        for entry in snapshot {
            entry.listener(payload)
        }
    }

    func emit(_ type: EventName<Void>) {
        emit(type, ())
    }

    @discardableResult
    func on<P>(_ type: EventName<P>, _ listener: @escaping (P) -> Void) -> EventListenerToken {
        let token = EventListenerToken()
        lock.lock()
        listeners[type.name, default: []].append((token, { listener($0 as! P) }))
        lock.unlock()
        return token
    }

    @discardableResult
    func on(_ type: EventName<Void>, _ listener: @escaping () -> Void) -> EventListenerToken {
        return on(type) { (_: Void) in listener() }
    }

    @discardableResult
    func once<P>(_ type: EventName<P>, _ listener: @escaping (P) -> Void) -> EventListenerToken {
        let token = EventListenerToken()
        lock.lock()
        listeners[type.name, default: []].append((token, { [weak self] payload in
            self?.off(type, token)
            listener(payload as! P)
        }))
        lock.unlock()
        return token
    }

    @discardableResult
    func once(_ type: EventName<Void>, _ listener: @escaping () -> Void) -> EventListenerToken {
        return once(type) { (_: Void) in listener() }
    }

    func off<P>(_ type: EventName<P>, _ token: EventListenerToken) {
        lock.lock()
        defer { lock.unlock() }

        guard var entries = listeners[type.name] else { return }
        entries.removeAll { $0.token == token }

        if entries.isEmpty {
            listeners.removeValue(forKey: type.name)
        } else {
            listeners[type.name] = entries
        }
    }

    func removeAllListeners<P>(_ type: EventName<P>? = nil) {
        lock.lock()
        defer { lock.unlock() }

        guard let type else {
            listeners.removeAll()
            return
        }

        listeners.removeValue(forKey: type.name)
    }
}
