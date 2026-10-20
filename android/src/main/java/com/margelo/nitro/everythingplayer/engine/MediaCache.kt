package com.margelo.nitro.everythingplayer.engine

import android.content.Context
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.Cache
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.NoOpCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import java.io.File
import java.util.concurrent.Executors

@OptIn(UnstableApi::class)
object EPMediaCache {
  private var mediaCache: SimpleCache? = null
  private var downloadCache: SimpleCache? = null
  private var database: StandaloneDatabaseProvider? = null
  private val executor = Executors.newSingleThreadExecutor()
  private const val USER_AGENT = "react-native-everything-player"

  @Synchronized
  fun databaseProvider(context: Context): StandaloneDatabaseProvider =
    database ?: StandaloneDatabaseProvider(context.applicationContext).also { database = it }

  @Synchronized
  fun configure(context: Context, maxSizeMB: Double, maxAgeSeconds: Double, persistent: Boolean) {
    if (mediaCache != null) return
    val dir = if (persistent) {
      File(context.cacheDir, "everythingplayer/media")
    } else {
      File(context.cacheDir, "everythingplayer/session").also { SimpleCache.delete(it, databaseProvider(context)) }
    }
    val maxBytes = (maxOf(1.0, maxSizeMB) * 1024 * 1024).toLong()
    val cache = SimpleCache(dir, LeastRecentlyUsedCacheEvictor(maxBytes), databaseProvider(context))
    mediaCache = cache
    executor.execute { evictOlderThan(cache, maxAgeSeconds) }
  }

  @Synchronized
  fun downloads(context: Context): SimpleCache =
    downloadCache ?: SimpleCache(
      File(context.filesDir, "everythingplayer/downloads"),
      NoOpCacheEvictor(),
      databaseProvider(context),
    ).also { downloadCache = it }

  private fun evictOlderThan(cache: Cache, maxAgeSeconds: Double) {
    val cutoff = System.currentTimeMillis() - (maxAgeSeconds * 1000).toLong()
    for (key in cache.keys.toList()) {
      for (span in cache.getCachedSpans(key)) {
        if (span.lastTouchTimestamp < cutoff) runCatching { cache.removeSpan(span) }
      }
    }
  }

  fun httpFactory(headers: Map<String, String>): DefaultHttpDataSource.Factory =
    DefaultHttpDataSource.Factory()
      .setUserAgent(headers["User-Agent"] ?: USER_AGENT)
      .setDefaultRequestProperties(headers.filterKeys { it != "User-Agent" })
      .setAllowCrossProtocolRedirects(true)
      .setConnectTimeoutMs(15_000)
      .setReadTimeoutMs(20_000)

  fun playbackFactory(context: Context, headers: Map<String, String>, downloaded: Boolean): DataSource.Factory {
    val upstream = DefaultDataSource.Factory(context, httpFactory(headers))
    val cached: DataSource.Factory = mediaCache?.let {
      CacheDataSource.Factory()
        .setCache(it)
        .setUpstreamDataSourceFactory(upstream)
        .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    } ?: upstream
    if (!downloaded) return cached
    return CacheDataSource.Factory()
      .setCache(downloads(context))
      .setUpstreamDataSourceFactory(cached)
      .setCacheWriteDataSinkFactory(null)
  }

  fun prefetch(context: Context, uri: Uri, headers: Map<String, String>, bytes: Long) {
    val cache = mediaCache ?: return
    executor.execute {
      runCatching {
        val source = CacheDataSource.Factory()
          .setCache(cache)
          .setUpstreamDataSourceFactory(DefaultDataSource.Factory(context, httpFactory(headers)))
          .createDataSource()
        CacheWriter(source, DataSpec.Builder().setUri(uri).setLength(bytes).build(), null, null).cache()
      }
    }
  }
}
