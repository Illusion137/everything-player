package com.margelo.nitro.everythingplayer.googlevideo.utils

import kotlin.math.exp
import kotlin.math.min

data class BandwidthEstimatorOptions(
  val halfLifeFastSec: Double? = null,
  val halfLifeSlowSec: Double? = null,
  val safetyFactor: Double? = null,
  val maxSampleDurationSec: Double? = null,
  val seedMinDurationSec: Double? = null,
)

class BandwidthEstimator(options: BandwidthEstimatorOptions = BandwidthEstimatorOptions()) {
  private val halfLifeFastSec = options.halfLifeFastSec ?: 1.0
  private val halfLifeSlowSec = options.halfLifeSlowSec ?: 5.0
  private val safetyFactor = options.safetyFactor ?: 0.9
  private val maxSampleDurationSec = options.maxSampleDurationSec ?: 5.0
  private val seedMinDurationSec = options.seedMinDurationSec ?: 0.1

  private var fast = 0.0
  private var slow = 0.0
  private var hasValue = false
  private var pendingBytes = 0.0
  private var pendingSec = 0.0

  @Synchronized
  fun reset() {
    fast = 0.0
    slow = 0.0
    hasValue = false
    pendingBytes = 0.0
    pendingSec = 0.0
  }

  /** Bytes received, and the seconds the network made us wait for them. */
  @Synchronized
  fun add(bytes: Int, seconds: Double) {
    if (bytes <= 0 || !(seconds > 0) || seconds > maxSampleDurationSec) return

    if (!hasValue) {
      pendingBytes += bytes
      pendingSec += seconds
      if (pendingSec >= seedMinDurationSec) {
        fast = pendingBytes / pendingSec
        slow = fast
        hasValue = true
        pendingBytes = 0.0
        pendingSec = 0.0
      }
      return
    }

    val rate = bytes / seconds
    val aFast = 1 - exp(-seconds / halfLifeFastSec)
    val aSlow = 1 - exp(-seconds / halfLifeSlowSec)
    fast += aFast * (rate - fast)
    slow += aSlow * (rate - slow)
  }

  /** Returns bytes/sec; 0 until there's data. */
  @Synchronized
  fun get(): Double {
    if (!hasValue) return 0.0
    return min(fast, slow) * safetyFactor
  }
}
