package com.margelo.nitro.everythingplayer.googlevideo.utils

import java.util.Timer
import kotlin.concurrent.fixedRateTimer

data class CacheEntry(
  var data: ByteArray,
  var timestamp: Double,
  var size: Int,
)

private const val TAG = "CacheManager"

class CacheManager(maxSizeMB: Int = 50, maxAgeSeconds: Int = 600) {
  private val initSegmentCache = HashMap<String, CacheEntry>()
  private val segmentCache = HashMap<String, CacheEntry>()
  private var currentSize = 0
  private var timer: Timer? = null
  private val lock = Any()
  private val maxCacheSize: Int = maxSizeMB * 1024 * 1024
  private val maxAge: Double = maxAgeSeconds.toDouble() * 1000
  private val logger = Logger.getInstance()

  init {
    startGarbageCollection()
  }

  fun getCacheEntries(): Pair<Map<String, CacheEntry>, Map<String, CacheEntry>> = synchronized(lock) {
    HashMap(initSegmentCache) to HashMap(segmentCache)
  }

  fun setInitSegment(key: String, data: ByteArray) {
    synchronized(lock) {
      val entry = CacheEntry(data, nowMs(), data.size)

      if (initSegmentCache[key] == null) {
        currentSize += entry.size
        enforceStorageLimit()
      }

      initSegmentCache[key] = entry
    }
  }

  fun setSegment(key: String, data: ByteArray) {
    synchronized(lock) {
      val entry = CacheEntry(data, nowMs(), data.size)

      currentSize += entry.size
      enforceStorageLimit()
      segmentCache[key] = entry
    }
  }

  fun getInitSegment(key: String): ByteArray? {
    synchronized(lock) {
      val entry = initSegmentCache[key]

      if (entry != null && !isExpired(entry)) {
        logger.debug(TAG, "Cache hit for init segment: $key")
        entry.timestamp = nowMs()
        initSegmentCache[key] = entry
        return entry.data
      }

      if (entry != null) {
        initSegmentCache.remove(key)
        currentSize -= entry.size
      }

      return null
    }
  }

  fun getSegment(key: String): ByteArray? {
    synchronized(lock) {
      val entry = segmentCache[key]

      if (entry != null && !isExpired(entry)) {
        logger.debug(TAG, "Cache hit for segment: $key")
        segmentCache.remove(key)
        currentSize -= entry.size
        return entry.data
      }

      if (entry != null) {
        segmentCache.remove(key)
        currentSize -= entry.size
      }

      return null
    }
  }

  private fun isExpired(entry: CacheEntry): Boolean = nowMs() - entry.timestamp > maxAge

  private fun enforceStorageLimit() {
    if (currentSize <= maxCacheSize) return

    clearExpiredEntries()

    if (currentSize > maxCacheSize) {
      removeOldestEntries()
    }
  }

  private fun clearExpiredEntries() {
    synchronized(lock) {
      val now = nowMs()

      for ((key, entry) in segmentCache.entries.toList()) {
        if (now - entry.timestamp > maxAge) {
          logger.debug(TAG, "Removing expired segment from cache: $key")
          segmentCache.remove(key)
          currentSize -= entry.size
        }
      }

      for ((key, entry) in initSegmentCache.entries.toList()) {
        if (now - entry.timestamp > maxAge) {
          logger.debug(TAG, "Removing expired init segment from cache: $key")
          initSegmentCache.remove(key)
          currentSize -= entry.size
        }
      }
    }
  }

  private fun removeOldestEntries() {
    val allEntries = (segmentCache.entries.map { it.key to it.value } + initSegmentCache.entries.map { it.key to it.value })
      .sortedBy { it.second.timestamp }
      .toMutableList()

    while (currentSize > maxCacheSize && allEntries.isNotEmpty()) {
      val (key, entry) = allEntries.removeAt(0)
      segmentCache.remove(key)
      initSegmentCache.remove(key)
      currentSize -= entry.size
    }
  }

  private fun startGarbageCollection() {
    timer = fixedRateTimer(TAG, true, 60_000L, 60_000L) {
      clearExpiredEntries()
    }
  }

  fun dispose() {
    synchronized(lock) {
      initSegmentCache.clear()
      segmentCache.clear()
      currentSize = 0

      timer?.let {
        it.cancel()
        timer = null
      }

      logger.debug(TAG, "Disposed")
    }
  }
}
