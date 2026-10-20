package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.types.SabrRequestMetadata

class RequestMetadataManager {
  var metadataMap: MutableMap<String, SabrRequestMetadata> = HashMap()
  private var lastCleanup: Double = nowMs()
  private val CLEANUP_INTERVAL: Double = 30000.0
  private val ENTRY_EXPIRATION_TIME: Double = 1000.0 * 60 * 3

  fun getRequestMetadata(url: String, del: Boolean = false): SabrRequestMetadata? {
    val requestNumber = url.searchParam("rn") ?: ""

    val streamingContext = metadataMap[requestNumber]

    if (streamingContext != null && nowMs() - streamingContext.timestamp > ENTRY_EXPIRATION_TIME) {
      metadataMap.remove(requestNumber)
      return null
    }

    if (del) {
      metadataMap.remove(requestNumber)
    }

    conditionalCleanUp()

    return streamingContext
  }

  fun setRequestMetadata(url: String, context: SabrRequestMetadata) {
    val requestNumber = url.searchParam("rn")
    if (!requestNumber.isNullOrEmpty()) {
      metadataMap[requestNumber] = context
      conditionalCleanUp()
    }
  }

  private fun conditionalCleanUp() {
    val now = nowMs()
    if (now - lastCleanup > CLEANUP_INTERVAL) {
      cleanUp()
      lastCleanup = now
    }
  }

  private fun cleanUp() {
    for ((key, context) in metadataMap.entries.toList()) {
      if (nowMs() - context.timestamp > ENTRY_EXPIRATION_TIME) {
        metadataMap.remove(key)
      }
    }
  }
}
