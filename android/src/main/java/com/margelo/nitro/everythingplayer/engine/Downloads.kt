package com.margelo.nitro.everythingplayer.engine

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.TrackSelectionParameters
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.offline.Download
import androidx.media3.exoplayer.offline.DownloadHelper
import androidx.media3.exoplayer.offline.DownloadManager
import androidx.media3.exoplayer.offline.DownloadRequest
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

data class EPDownloadRecord(
  val trackId: String,
  val track: EPTrack,
  val state: String,
  val progress: Double,
  val bytesDownloaded: Long,
  val totalBytes: Long?,
  val errorCode: String?,
  val errorMessage: String?,
  val audioPath: String? = null,
  val videoPath: String? = null,
)

@OptIn(UnstableApi::class)
object EPDownloads : DownloadManager.Listener {
  var onChanged: ((EPDownloadRecord) -> Unit)? = null

  private const val STOP_REASON_PAUSED = 1
  private val main = Handler(Looper.getMainLooper())
  private var manager: DownloadManager? = null
  private val failures = mutableMapOf<String, EPDownloadRecord>()
  private val cancelled = mutableSetOf<String>()
  private val headersByHost = ConcurrentHashMap<String, Map<String, String>>()

  private val poll = object : Runnable {
    override fun run() {
      val m = manager ?: return
      val active = m.currentDownloads.filter { it.state == Download.STATE_DOWNLOADING }
      active.forEach { emit(it) }
      if (active.isNotEmpty()) main.postDelayed(this, 500)
    }
  }

  fun manager(context: Context): DownloadManager {
    manager?.let { return it }
    if (Looper.myLooper() != Looper.getMainLooper()) {
      val latch = java.util.concurrent.CountDownLatch(1)
      main.post {
        createManager(context)
        latch.countDown()
      }
      latch.await()
      return manager!!
    }
    return createManager(context)
  }

  @Synchronized
  private fun createManager(context: Context): DownloadManager {
    manager?.let { return it }
    val app = context.applicationContext
    val m = DownloadManager(
      app,
      EPMediaCache.databaseProvider(app),
      EPMediaCache.downloads(app),
      ResolvingDataSource.Factory(EPMediaCache.httpFactory(emptyMap())) { spec ->
        val headers = headersByHost[spec.uri.host ?: ""]
        if (headers.isNullOrEmpty()) spec else spec.withAdditionalHeaders(headers)
      },
      Executors.newFixedThreadPool(2),
    )
    m.maxParallelDownloads = 2
    m.downloadIndex.getDownloads().use { cursor ->
      while (cursor.moveToNext()) {
        val d = cursor.download
        val t = decode(d.request.id, String(d.request.data))
        if (t.requestHeaders.isNotEmpty()) headersByHost[d.request.uri.host ?: ""] = t.requestHeaders
      }
    }
    m.addListener(this)
    m.resumeDownloads()
    manager = m
    return m
  }

  fun isCompleted(context: Context, trackId: String): Boolean =
    EPSabrDownloads.isCompleted(context, trackId) ||
      manager(context).downloadIndex.getDownload(trackId)?.state == Download.STATE_COMPLETED

  fun download(context: Context, track: EPTrack, includeVideo: Boolean, range: EPVideoQualityRange): EPDownloadRecord {
    if (track.sabr != null) return EPSabrDownloads.download(context, track, includeVideo, range)
    val m = manager(context)
    val url = track.url ?: throw EPError(EPErrorCode.SOURCE_ERROR, "Track ${track.id} has no URL")
    m.downloadIndex.getDownload(track.id)?.let {
      if (it.state == Download.STATE_COMPLETED || it.state == Download.STATE_DOWNLOADING || it.state == Download.STATE_QUEUED) {
        return record(it)
      }
    }
    failures.remove(track.id)
    cancelled.remove(track.id)
    if (track.requestHeaders.isNotEmpty()) headersByHost[Uri.parse(url).host ?: ""] = track.requestHeaders
    val data = encode(track, includeVideo).toByteArray()
    if (track.sourceType == EPSourceType.HLS) {
      main.post { prepareHls(context.applicationContext, m, track, url, includeVideo, range, data) }
    } else {
      val request = DownloadRequest.Builder(track.id, Uri.parse(url)).setData(data).build()
      main.post { enqueue(m, request) }
    }
    return EPDownloadRecord(track.id, track, "queued", 0.0, 0, null, null, null)
  }

  private fun enqueue(m: DownloadManager, request: DownloadRequest) {
    m.addDownload(request, Download.STOP_REASON_NONE)
    main.removeCallbacks(poll)
    main.post(poll)
  }

  private fun prepareHls(
    context: Context,
    m: DownloadManager,
    track: EPTrack,
    url: String,
    includeVideo: Boolean,
    range: EPVideoQualityRange,
    data: ByteArray,
  ) {
    val params = TrackSelectionParameters.Builder().apply {
      setForceHighestSupportedBitrate(true)
      if (includeVideo) applyVideoRange(range) else setTrackTypeDisabled(C.TRACK_TYPE_VIDEO, true)
    }.build()
    val helper = DownloadHelper.Factory()
      .setDataSourceFactory(EPMediaCache.httpFactory(track.requestHeaders))
      .setRenderersFactory(DefaultRenderersFactory(context))
      .setTrackSelectionParameters(params)
      .create(MediaItem.Builder().setUri(url).setMimeType(MimeTypes.APPLICATION_M3U8).build())
    helper.prepare(object : DownloadHelper.Callback {
      override fun onPrepared(helper: DownloadHelper, tracksInfoAvailable: Boolean) {
        val request = helper.getDownloadRequest(track.id, data)
        helper.release()
        if (track.id !in cancelled) enqueue(m, request)
      }

      override fun onPrepareError(helper: DownloadHelper, e: IOException) {
        helper.release()
        val record = EPDownloadRecord(track.id, track, "failed", 0.0, 0, null, EPErrorCode.NETWORK_ERROR.code, e.message ?: "Could not prepare HLS download")
        failures[track.id] = record
        onChanged?.invoke(record)
      }
    })
  }

  fun pause(context: Context, trackId: String) {
    if (EPSabrDownloads.has(context, trackId)) return EPSabrDownloads.pause(context, trackId)
    main.post { manager(context).setStopReason(trackId, STOP_REASON_PAUSED) }
  }

  fun resume(context: Context, trackId: String) {
    if (EPSabrDownloads.has(context, trackId)) return EPSabrDownloads.resume(context, trackId)
    main.post {
      manager(context).setStopReason(trackId, Download.STOP_REASON_NONE)
      main.removeCallbacks(poll)
      main.post(poll)
    }
  }

  fun cancel(context: Context, trackId: String) {
    if (EPSabrDownloads.has(context, trackId)) return EPSabrDownloads.cancel(context, trackId)
    val existing = get(context, trackId) ?: return
    if (existing.state == "completed") return
    cancelled.add(trackId)
    main.post { manager(context).removeDownload(trackId) }
    onChanged?.invoke(existing.copy(state = "cancelled"))
  }

  fun remove(context: Context, trackId: String) {
    if (EPSabrDownloads.has(context, trackId)) return EPSabrDownloads.remove(context, trackId)
    failures.remove(trackId)
    main.post { manager(context).removeDownload(trackId) }
  }

  fun removeAll(context: Context) {
    EPSabrDownloads.removeAll(context)
    failures.clear()
    main.post { manager(context).removeAllDownloads() }
  }

  fun get(context: Context, trackId: String): EPDownloadRecord? {
    EPSabrDownloads.get(context, trackId)?.let { return it }
    failures[trackId]?.let { return it }
    return manager(context).downloadIndex.getDownload(trackId)?.let { record(it) }
  }

  fun all(context: Context): List<EPDownloadRecord> {
    val result = (EPSabrDownloads.all(context) + failures.values).toMutableList()
    manager(context).downloadIndex.getDownloads().use { cursor ->
      while (cursor.moveToNext()) result.add(record(cursor.download))
    }
    return result
  }

  override fun onDownloadChanged(downloadManager: DownloadManager, download: Download, finalException: Exception?) {
    emit(download, finalException)
    if (download.state == Download.STATE_DOWNLOADING) {
      main.removeCallbacks(poll)
      main.post(poll)
    }
  }

  override fun onDownloadRemoved(downloadManager: DownloadManager, download: Download) {
    cancelled.remove(download.request.id)
  }

  private fun emit(download: Download, error: Exception? = null) {
    if (download.request.id in cancelled) return
    onChanged?.invoke(record(download, error))
  }

  private fun record(download: Download, error: Exception? = null): EPDownloadRecord {
    val track = decode(download.request.id, String(download.request.data))
    val state = when (download.state) {
      Download.STATE_QUEUED -> "queued"
      Download.STATE_DOWNLOADING, Download.STATE_RESTARTING -> "downloading"
      Download.STATE_STOPPED -> "paused"
      Download.STATE_COMPLETED -> "completed"
      Download.STATE_FAILED -> "failed"
      else -> "cancelled"
    }
    val total = download.contentLength.takeIf { it > 0 }
    val progress = when {
      download.state == Download.STATE_COMPLETED -> 1.0
      download.percentDownloaded >= 0 -> download.percentDownloaded / 100.0
      else -> 0.0
    }
    return EPDownloadRecord(
      download.request.id, track, state, progress, download.bytesDownloaded, total,
      if (download.state == Download.STATE_FAILED) EPErrorCode.NETWORK_ERROR.code else null,
      if (download.state == Download.STATE_FAILED) (error?.message ?: "Download failed") else null,
    )
  }

  private fun encode(track: EPTrack, includeVideo: Boolean): String = JSONObject().apply {
    put("id", track.id)
    put("title", track.title)
    put("artist", track.artist)
    put("album", track.album)
    put("artwork", track.artwork)
    track.duration?.let { put("duration", it) }
    track.startTime?.let { put("startTime", it) }
    track.endTime?.let { put("endTime", it) }
    put("url", track.url)
    put("userAgent", track.userAgent)
    put("contentType", track.contentType)
    put("headers", JSONObject(track.headers))
    put("includeVideo", includeVideo)
  }.toString()

  private fun decode(id: String, json: String): EPTrack {
    val o = runCatching { JSONObject(json) }.getOrNull() ?: return EPTrack(id = id, title = "", artist = "")
    fun str(key: String) = if (o.isNull(key)) null else o.optString(key)
    fun dbl(key: String) = if (o.has(key) && !o.isNull(key)) o.optDouble(key) else null
    val headers = o.optJSONObject("headers")?.let { h -> h.keys().asSequence().associateWith { h.getString(it) } } ?: emptyMap()
    return EPTrack(
      id = id,
      title = str("title") ?: "",
      artist = str("artist") ?: "",
      album = str("album"),
      artwork = str("artwork"),
      duration = dbl("duration"),
      startTime = dbl("startTime"),
      endTime = dbl("endTime"),
      url = str("url"),
      userAgent = str("userAgent"),
      contentType = str("contentType"),
      headers = headers,
    )
  }
}
