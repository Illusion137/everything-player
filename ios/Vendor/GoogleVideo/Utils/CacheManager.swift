import Foundation

struct CacheEntry {
    var data: Data
    var timestamp: Double
    var size: Int
}

private let TAG = "CacheManager"

final class CacheManager: @unchecked Sendable {
    private var initSegmentCache: [String: CacheEntry] = [:]
    private var segmentCache: [String: CacheEntry] = [:]
    private var currentSize = 0
    private var timer: Timer?
    private let lock = NSRecursiveLock()
    private let maxCacheSize: Int
    private let maxAge: Double
    private let logger = Logger.getInstance()

    init(_ maxSizeMB: Int = 50, _ maxAgeSeconds: Int = 600) {
        self.maxCacheSize = maxSizeMB * 1024 * 1024
        self.maxAge = Double(maxAgeSeconds) * 1000
        startGarbageCollection()
    }

    func getCacheEntries() -> (initSegmentCache: [String: CacheEntry], segmentCache: [String: CacheEntry]) {
        lock.lock()
        defer { lock.unlock() }
        return (initSegmentCache, segmentCache)
    }

    func setInitSegment(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let entry = CacheEntry(data: data, timestamp: nowMs(), size: data.count)

        if initSegmentCache[key] == nil {
            currentSize += entry.size
            enforceStorageLimit()
        }

        initSegmentCache[key] = entry
    }

    func setSegment(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        let entry = CacheEntry(data: data, timestamp: nowMs(), size: data.count)

        currentSize += entry.size
        enforceStorageLimit()
        segmentCache[key] = entry
    }

    func getInitSegment(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let entry = initSegmentCache[key]

        if var entry, !isExpired(entry) {
            logger.debug(TAG, "Cache hit for init segment: \(key)")
            entry.timestamp = nowMs()
            initSegmentCache[key] = entry
            return entry.data
        }

        if let entry {
            initSegmentCache.removeValue(forKey: key)
            currentSize -= entry.size
        }

        return nil
    }

    func getSegment(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let entry = segmentCache[key]

        if let entry, !isExpired(entry) {
            logger.debug(TAG, "Cache hit for segment: \(key)")
            segmentCache.removeValue(forKey: key)
            currentSize -= entry.size
            return entry.data
        }

        if let entry {
            segmentCache.removeValue(forKey: key)
            currentSize -= entry.size
        }

        return nil
    }

    private func isExpired(_ entry: CacheEntry) -> Bool {
        return nowMs() - entry.timestamp > maxAge
    }

    private func enforceStorageLimit() {
        if currentSize <= maxCacheSize { return }

        clearExpiredEntries()

        if currentSize > maxCacheSize {
            removeOldestEntries()
        }
    }

    private func clearExpiredEntries() {
        lock.lock()
        defer { lock.unlock() }

        let now = nowMs()

        for (key, entry) in segmentCache {
            if now - entry.timestamp > maxAge {
                logger.debug(TAG, "Removing expired segment from cache: \(key)")
                segmentCache.removeValue(forKey: key)
                currentSize -= entry.size
            }
        }

        for (key, entry) in initSegmentCache {
            if now - entry.timestamp > maxAge {
                logger.debug(TAG, "Removing expired init segment from cache: \(key)")
                initSegmentCache.removeValue(forKey: key)
                currentSize -= entry.size
            }
        }
    }

    private func removeOldestEntries() {
        var allEntries = (Array(segmentCache) + Array(initSegmentCache))
            .sorted { $0.value.timestamp < $1.value.timestamp }

        while currentSize > maxCacheSize && !allEntries.isEmpty {
            let (key, entry) = allEntries.removeFirst()
            segmentCache.removeValue(forKey: key)
            initSegmentCache.removeValue(forKey: key)
            currentSize -= entry.size
        }
    }

    private func startGarbageCollection() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.clearExpiredEntries()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func dispose() {
        lock.lock()
        defer { lock.unlock() }

        initSegmentCache.removeAll()
        segmentCache.removeAll()
        currentSize = 0

        if let timer {
            timer.invalidate()
            self.timer = nil
        }

        logger.debug(TAG, "Disposed")
    }
}
