package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.core.GoogleVideoError
import kotlinx.coroutines.delay

enum class MediaType(val rawValue: String) {
  AUDIO("audio"),
  VIDEO("video"),
}

suspend fun wait(ms: Long) {
  delay(maxOf(0L, ms))
}

fun nowMs(): Double = System.currentTimeMillis().toDouble()

fun assert(condition: Boolean, msg: String) {
  if (!condition) throw GoogleVideoError(msg)
}

fun <T> assertIsDefined(value: T?, msg: String? = null): T =
  value ?: throw GoogleVideoError(msg ?: "Expected value to be defined, but got nil")

fun getMediaType(mimeType: String?): MediaType =
  if (mimeType?.contains("audio") == true) MediaType.AUDIO else MediaType.VIDEO

typealias OrderedMap<K, V> = LinkedHashMap<K, V>

fun <K, V> OrderedMap<K, V>.has(key: K): Boolean = containsKey(key)

class AbortController {
  private val lock = Any()
  private var _aborted = false
  private var cancellers = mutableListOf<() -> Unit>()

  val aborted: Boolean
    get() = synchronized(lock) { _aborted }

  fun onAbort(cancel: () -> Unit) {
    val alreadyAborted = synchronized(lock) {
      if (!_aborted) cancellers.add(cancel)
      _aborted
    }
    if (alreadyAborted) cancel()
  }

  fun abort() {
    val pending = synchronized(lock) {
      if (_aborted) return
      _aborted = true
      val pending = cancellers
      cancellers = mutableListOf()
      pending
    }
    for (cancel in pending) cancel()
  }
}

fun errorMessage(error: Throwable): String = error.message ?: error.toString()
