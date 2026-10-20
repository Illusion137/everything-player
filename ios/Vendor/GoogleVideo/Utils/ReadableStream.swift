import Foundation

final class ReadableStream<Element: Sendable>: @unchecked Sendable {
    final class Controller: @unchecked Sendable {
        fileprivate unowned let stream: ReadableStream<Element>

        fileprivate init(_ stream: ReadableStream<Element>) {
            self.stream = stream
        }

        var desiredSize: Int? {
            return stream.desiredSize
        }

        func enqueue(_ chunk: Element) {
            stream.enqueue(chunk)
        }

        func close() {
            stream.close()
        }

        func error(_ error: any Error) {
            stream.fail(error)
        }
    }

    final class Reader: @unchecked Sendable {
        private let stream: ReadableStream<Element>

        fileprivate init(_ stream: ReadableStream<Element>) {
            self.stream = stream
        }

        func read() async throws -> (done: Bool, value: Element?) {
            return try await stream.read()
        }

        func cancel(_ reason: String? = nil) async {
            stream.cancel(reason)
        }

        func releaseLock() {
            stream.releaseLock()
        }
    }

    private enum State {
        case readable
        case closed
        case errored(any Error)
    }

    private let lock = NSLock()
    private let highWaterMark: Int
    private let sizeOf: (Element) -> Int
    private let pull: (() -> Void)?
    private let onCancel: ((String?) -> Void)?

    private var state: State = .readable
    private var queue: [(chunk: Element, size: Int)] = []
    private var queueSize = 0
    private var waiters: [CheckedContinuation<(done: Bool, value: Element?), any Error>] = []
    private var isLocked = false
    private var controllerStorage: Controller?

    init(
        highWaterMark: Int,
        sizeOf: @escaping (Element) -> Int,
        start: ((Controller) -> Void)? = nil,
        pull: (() -> Void)? = nil,
        cancel: ((String?) -> Void)? = nil
    ) {
        self.highWaterMark = highWaterMark
        self.sizeOf = sizeOf
        self.pull = pull
        self.onCancel = cancel
        let controller = Controller(self)
        self.controllerStorage = controller
        start?(controller)
    }

    var controller: Controller {
        return controllerStorage!
    }

    var locked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isLocked
    }

    func getReader() -> Reader {
        lock.lock()
        isLocked = true
        lock.unlock()
        return Reader(self)
    }

    fileprivate func releaseLock() {
        lock.lock()
        isLocked = false
        lock.unlock()
    }

    fileprivate var desiredSize: Int? {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .errored: return nil
        case .closed: return 0
        case .readable: return highWaterMark - queueSize
        }
    }

    fileprivate func enqueue(_ chunk: Element) {
        lock.lock()

        guard case .readable = state else {
            lock.unlock()
            return
        }

        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: (false, chunk))
            return
        }

        let size = sizeOf(chunk)
        queue.append((chunk, size))
        queueSize += size
        lock.unlock()
    }

    fileprivate func close() {
        lock.lock()

        guard case .readable = state else {
            lock.unlock()
            return
        }

        state = .closed
        let pending = waiters
        waiters = []
        lock.unlock()

        for waiter in pending {
            waiter.resume(returning: (true, nil))
        }
    }

    fileprivate func fail(_ error: any Error) {
        lock.lock()

        guard case .readable = state else {
            lock.unlock()
            return
        }

        state = .errored(error)
        queue.removeAll()
        queueSize = 0
        let pending = waiters
        waiters = []
        lock.unlock()

        for waiter in pending {
            waiter.resume(throwing: error)
        }
    }

    fileprivate func cancel(_ reason: String?) {
        lock.lock()

        guard case .readable = state else {
            lock.unlock()
            return
        }

        state = .closed
        queue.removeAll()
        queueSize = 0
        let pending = waiters
        waiters = []
        lock.unlock()

        for waiter in pending {
            waiter.resume(returning: (true, nil))
        }

        onCancel?(reason)
    }

    fileprivate func read() async throws -> (done: Bool, value: Element?) {
        let immediate: (done: Bool, value: Element?)? = try {
            lock.lock()
            defer { lock.unlock() }

            if case .errored(let error) = state {
                throw error
            }

            if !queue.isEmpty {
                let entry = queue.removeFirst()
                queueSize -= entry.size
                return (false, entry.chunk)
            }

            if case .closed = state {
                return (true, nil)
            }

            return nil
        }()

        if let immediate {
            pull?()
            return immediate
        }

        pull?()

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()

            if case .errored(let error) = state {
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }

            if !queue.isEmpty {
                let entry = queue.removeFirst()
                queueSize -= entry.size
                lock.unlock()
                continuation.resume(returning: (false, entry.chunk))
                return
            }

            if case .closed = state {
                lock.unlock()
                continuation.resume(returning: (true, nil))
                return
            }

            waiters.append(continuation)
            lock.unlock()
        }
    }
}
