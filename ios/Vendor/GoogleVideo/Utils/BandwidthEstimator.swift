import Foundation

struct BandwidthEstimatorOptions {
    var halfLifeFastSec: Double?
    var halfLifeSlowSec: Double?
    var safetyFactor: Double?
    var maxSampleDurationSec: Double?
    var seedMinDurationSec: Double?
}

final class BandwidthEstimator {
    private let halfLifeFastSec: Double
    private let halfLifeSlowSec: Double
    private let safetyFactor: Double
    private let maxSampleDurationSec: Double
    private let seedMinDurationSec: Double

    private var fast = 0.0
    private var slow = 0.0
    private var hasValue = false
    private var pendingBytes = 0.0
    private var pendingSec = 0.0

    init(_ options: BandwidthEstimatorOptions = BandwidthEstimatorOptions()) {
        halfLifeFastSec = options.halfLifeFastSec ?? 1.0
        halfLifeSlowSec = options.halfLifeSlowSec ?? 5.0
        safetyFactor = options.safetyFactor ?? 0.9
        maxSampleDurationSec = options.maxSampleDurationSec ?? 5.0
        seedMinDurationSec = options.seedMinDurationSec ?? 0.1
    }

    func reset() {
        fast = 0
        slow = 0
        hasValue = false
        pendingBytes = 0
        pendingSec = 0
    }

    /// Bytes received, and the seconds the network made us wait for them.
    func add(_ bytes: Int, _ seconds: Double) {
        guard bytes > 0, seconds > 0, seconds <= maxSampleDurationSec else { return }

        if !hasValue {
            pendingBytes += Double(bytes)
            pendingSec += seconds
            if pendingSec >= seedMinDurationSec {
                fast = pendingBytes / pendingSec
                slow = fast
                hasValue = true
                pendingBytes = 0
                pendingSec = 0
            }
            return
        }

        let rate = Double(bytes) / seconds
        let aFast = 1 - exp(-seconds / halfLifeFastSec)
        let aSlow = 1 - exp(-seconds / halfLifeSlowSec)
        fast += aFast * (rate - fast)
        slow += aSlow * (rate - slow)
    }

    /// Returns bytes/sec; 0 until there's data.
    func get() -> Double {
        guard hasValue else { return 0 }
        return min(fast, slow) * safetyFactor
    }
}
