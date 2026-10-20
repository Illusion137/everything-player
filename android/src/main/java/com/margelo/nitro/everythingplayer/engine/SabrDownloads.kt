package com.margelo.nitro.everythingplayer.engine

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.margelo.nitro.everythingplayer.googlevideo.core.SabrStream
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatSelector
import com.margelo.nitro.everythingplayer.googlevideo.types.ReloadResponse
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrPlaybackOptions
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamCallbacks
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamConfig
import com.margelo.nitro.everythingplayer.googlevideo.utils.EnabledTrackTypes
import com.margelo.nitro.everythingplayer.googlevideo.utils.ReadableStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.coroutineContext

object EPSabrDownloads {
  private class Entry(
    var record: EPDownloadRecord,
    val includeVideo: Boolean,
    val range: EPVideoQualityRange,
    var audioName: String? = null,
    var videoName: String? = null,
    var audioIsOpus: Boolean? = null,
  )

  private const val PREFS = "everythingplayer.sabr.downloads"
  private val main = Handler(Looper.getMainLooper())
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
  private val lock = Any()
  private val entries = LinkedHashMap<String, Entry>()
  private val jobs = HashMap<String, Job>()
  private var loaded = false

  private fun directory(context: Context): File = File(context.filesDir, "everythingplayer-sabr").apply { mkdirs() }

  private fun fileName(trackId: String, suffix: String): String =
    trackId.map { if (it.isLetterOrDigit() || it == '-' || it == '_') it else '_' }.joinToString("") + suffix

  fun has(context: Context, trackId: String): Boolean {
    ensureLoaded(context)
    return synchronized(lock) { entries.containsKey(trackId) }
  }

  fun get(context: Context, trackId: String): EPDownloadRecord? {
    ensureLoaded(context)
    return synchronized(lock) { entries[trackId]?.let { snapshot(context, it) } }
  }

  fun all(context: Context): List<EPDownloadRecord> {
    ensureLoaded(context)
    return synchronized(lock) { entries.values.map { snapshot(context, it) } }
  }

  fun isCompleted(context: Context, trackId: String): Boolean = get(context, trackId)?.state == "completed"

  fun localMedia(context: Context, track: EPTrack): EPLocalSabrMedia? {
    if (track.sabr == null) return null
    ensureLoaded(context)
    val entry = synchronized(lock) { entries[track.id] } ?: return null
    if (entry.record.state != "completed") return null
    val audio = entry.audioName?.let { File(directory(context), it) }?.takeIf { it.exists() } ?: return null
    val video = entry.videoName?.let { File(directory(context), it) }?.takeIf { it.exists() }
    return EPLocalSabrMedia(audio, entry.audioIsOpus ?: true, video)
  }

  fun download(context: Context, track: EPTrack, includeVideo: Boolean, range: EPVideoQualityRange): EPDownloadRecord {
    ensureLoaded(context)
    synchronized(lock) {
      entries[track.id]?.let {
        if (it.record.state == "completed" || it.record.state == "downloading" || it.record.state == "queued") return snapshot(context, it)
      }
      entries[track.id] = Entry(EPDownloadRecord(track.id, track, "queued", 0.0, 0, null, null, null), includeVideo, range)
    }
    persist(context)
    emit(context, track.id)
    start(context, track.id)
    return get(context, track.id)!!
  }

  fun pause(context: Context, trackId: String) {
    val job = synchronized(lock) { jobs.remove(trackId) }
    job?.cancel()
    mutate(context, trackId) { if (it.state == "queued" || it.state == "downloading") it.copy(state = "paused") else it }
  }

  fun resume(context: Context, trackId: String) {
    val state = get(context, trackId)?.state ?: return
    if (state == "paused" || state == "failed" || state == "cancelled") start(context, trackId)
  }

  fun cancel(context: Context, trackId: String) {
    val job = synchronized(lock) { jobs.remove(trackId) }
    job?.cancel()
    mutate(context, trackId) { if (it.state != "completed") it.copy(state = "cancelled") else it }
  }

  fun remove(context: Context, trackId: String) {
    cancel(context, trackId)
    val entry = synchronized(lock) { entries.remove(trackId) }
    if (entry != null) {
      val dir = directory(context)
      listOfNotNull(entry.audioName, entry.videoName).forEach { File(dir, it).delete() }
      dir.listFiles()?.filter { it.name.startsWith(fileName(trackId, ".")) && it.name.endsWith(".part") }?.forEach { it.delete() }
    }
    persist(context)
  }

  fun removeAll(context: Context) {
    all(context).forEach { remove(context, it.trackId) }
  }

  private fun start(context: Context, trackId: String) {
    val entry = synchronized(lock) { entries[trackId] } ?: return
    val track = entry.record.track
    val sabr = track.sabr ?: return
    val app = context.applicationContext
    mutate(app, trackId) { it.copy(state = "downloading", errorCode = null, errorMessage = null) }
    val job = scope.launch {
      try {
        run(app, track, sabr, entry.includeVideo, entry.range)
      } catch (e: CancellationException) {
      } catch (e: Throwable) {
        val error = EPError.from(e, EPErrorCode.SOURCE_ERROR)
        mutate(app, trackId) { it.copy(state = "failed", errorCode = error.errorCode.code, errorMessage = error.message) }
      } finally {
        synchronized(lock) { if (jobs[trackId] === coroutineContext[Job]) jobs.remove(trackId) }
      }
    }
    synchronized(lock) { jobs[trackId] = job }
  }

  private suspend fun run(context: Context, track: EPTrack, sabr: EPSabrInfo, includeVideo: Boolean, range: EPVideoQualityRange) {
    val audio = EPSabr.pickAudio(sabr.formats)
      ?: throw EPError(EPErrorCode.SABR_STREAM_FAILED, "No downloadable audio format")
    val video = if (includeVideo) EPSabr.pickVideo(sabr.formats, range) else null
    val id = track.id
    val provider = EPPlayerEngine.sabrCallbacks
    val timeoutMs = EPPlayerEngine.setupOptions.sabrCallbackTimeoutMs
    var callbackFailure: EPError? = null
    val callbacks = SabrStreamCallbacks(
      onReloadPlayerResponse = { context ->
        if (provider == null) throw EPError(EPErrorCode.SABR_CALLBACK_FAILED, "No SABR callback provider")
        try {
          val r = epWithTimeout(timeoutMs, "onReloadPlayerResponse") {
            provider.reloadPlayerResponse(id, context?.reloadPlaybackParams?.token)
          }
          ReloadResponse(serverAbrStreamingUrl = r.first, videoPlaybackUstreamerConfig = r.second)
        } catch (error: Throwable) {
          callbackFailure = EPError(EPErrorCode.SABR_CALLBACK_FAILED, error.message ?: error.toString())
          throw error
        }
      },
      onMintPoToken = {
        if (provider == null) throw EPError(EPErrorCode.SABR_CALLBACK_FAILED, "No SABR callback provider")
        try {
          epWithTimeout(timeoutMs, "onMintPoToken") { provider.mintPoToken(id) }
        } catch (error: Throwable) {
          callbackFailure = EPError(EPErrorCode.SABR_CALLBACK_FAILED, error.message ?: error.toString())
          throw error
        }
      },
    )
    val stream = SabrStream(
      SabrStreamConfig(
        videoId = sabr.videoId,
        fetchFunction = EPSabr.fetchFunction(track.requestHeaders),
        serverAbrStreamingUrl = sabr.serverAbrStreamingUrl,
        videoPlaybackUstreamerConfig = sabr.videoPlaybackUstreamerConfig,
        poToken = sabr.poToken,
        clientInfo = EPSabr.clientInfo(sabr),
        formats = sabr.formats.map(EPSabr::googleFormat),
        callbacks = callbacks,
        stripDuplicateInit = true,
      ),
    )
    val result = stream.start(
      SabrPlaybackOptions(
        videoFormat = video?.let { FormatSelector.Itag(it.itag) },
        audioFormat = FormatSelector.Itag(audio.itag),
        enabledTrackTypes = if (video == null) EnabledTrackTypes.AUDIO_ONLY else EnabledTrackTypes.VIDEO_AND_AUDIO,
        startTimeMs = 0,
        isPostLiveDvr = false,
      ),
    )

    val isOpus = EPSabr.isOpus(audio)
    val dir = directory(context)
    val audioName = fileName(id, if (isOpus) ".webm" else ".m4a")
    val videoName = video?.let { fileName(id, ".video.mp4") }
    val audioPart = File(dir, "$audioName.part")
    val videoPart = videoName?.let { File(dir, "$it.part") }
    val expected = (audio.contentLength ?: 0) + (video?.contentLength ?: 0)
    val counter = AtomicLong(0)

    try {
      coroutineScope {
        launch { drain(result.audioStream, audioPart, counter) { reportProgress(context, id, it, expected) } }
        if (videoPart != null) {
          launch { drain(result.videoStream, videoPart, counter) { reportProgress(context, id, it, expected) } }
        }
      }
      stream.abort()
    } catch (e: CancellationException) {
      stream.abort()
      throw e
    } catch (e: Throwable) {
      stream.abort()
      throw callbackFailure ?: e
    }
    coroutineContext.ensureActive()

    val audioDest = File(dir, audioName)
    audioDest.delete()
    if (!audioPart.renameTo(audioDest)) throw EPError(EPErrorCode.SOURCE_ERROR, "Could not finalize $audioName")
    if (videoPart != null) {
      val videoDest = File(dir, videoPart.name.removeSuffix(".part"))
      videoDest.delete()
      if (!videoPart.renameTo(videoDest)) throw EPError(EPErrorCode.SOURCE_ERROR, "Could not finalize ${videoDest.name}")
    }
    val total = counter.get()
    synchronized(lock) {
      entries[id]?.let {
        it.audioName = audioName
        it.videoName = videoName
        it.audioIsOpus = isOpus
      }
    }
    mutate(context, id) { it.copy(bytesDownloaded = total, totalBytes = total, state = "completed", progress = 1.0) }
  }

  private fun reportProgress(context: Context, id: String, total: Long, expected: Long) {
    mutate(context, id) {
      it.copy(
        bytesDownloaded = total,
        totalBytes = if (expected > 0) expected else null,
        progress = if (expected > 0) minOf(0.99, total.toDouble() / expected) else 0.0,
      )
    }
  }

  private suspend fun drain(stream: ReadableStream<ByteArray>, file: File, counter: AtomicLong, progress: (Long) -> Unit) {
    val reader = stream.getReader()
    var lastReport = 0L
    FileOutputStream(file).use { out ->
      while (true) {
        val (done, chunk) = reader.read()
        if (done || chunk == null) break
        coroutineContext.ensureActive()
        out.write(chunk)
        val total = counter.addAndGet(chunk.size.toLong())
        val now = System.currentTimeMillis()
        if (now - lastReport > 500) {
          lastReport = now
          progress(total)
        }
      }
    }
  }

  private fun snapshot(context: Context, entry: Entry): EPDownloadRecord {
    if (entry.record.state != "completed") return entry.record
    val dir = directory(context)
    return entry.record.copy(
      audioPath = entry.audioName?.let { File(dir, it).absolutePath },
      videoPath = entry.videoName?.let { File(dir, it).absolutePath },
    )
  }

  private fun mutate(context: Context, trackId: String, change: (EPDownloadRecord) -> EPDownloadRecord) {
    val changed = synchronized(lock) {
      val entry = entries[trackId] ?: return
      val next = change(entry.record)
      if (next == entry.record) return
      entry.record = next
      true
    }
    if (changed) {
      persist(context)
      emit(context, trackId)
    }
  }

  private fun emit(context: Context, trackId: String) {
    val record = get(context, trackId) ?: return
    main.post { EPDownloads.onChanged?.invoke(record) }
  }

  private fun ensureLoaded(context: Context) {
    synchronized(lock) {
      if (loaded) return
      loaded = true
      val raw = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString("records", null) ?: return
      val array = runCatching { JSONArray(raw) }.getOrNull() ?: return
      for (i in 0 until array.length()) {
        val o = array.optJSONObject(i) ?: continue
        val track = decodeTrack(o.getJSONObject("track"))
        val state = o.optString("state").let { if (it == "downloading" || it == "queued") "paused" else it }
        val range = o.optJSONObject("range")?.let {
          EPVideoQualityRange(it.optIntOrNull("minHeight"), it.optIntOrNull("maxHeight"), it.optIntOrNull("maxBitrate"))
        } ?: EPVideoQualityRange()
        entries[track.id] = Entry(
          EPDownloadRecord(
            track.id, track, state, o.optDouble("progress", 0.0), o.optLong("bytesDownloaded", 0),
            o.optLongOrNull("totalBytes"), o.optStringOrNull("errorCode"), o.optStringOrNull("errorMessage"),
          ),
          o.optBoolean("includeVideo", false),
          range,
          o.optStringOrNull("audioName"),
          o.optStringOrNull("videoName"),
          if (o.has("audioIsOpus")) o.optBoolean("audioIsOpus") else null,
        )
      }
    }
  }

  private fun persist(context: Context) {
    val json = synchronized(lock) {
      JSONArray().apply {
        for (entry in entries.values) {
          val r = entry.record
          put(
            JSONObject().apply {
              put("track", encodeTrack(r.track))
              put("state", r.state)
              put("progress", r.progress)
              put("bytesDownloaded", r.bytesDownloaded)
              r.totalBytes?.let { put("totalBytes", it) }
              r.errorCode?.let { put("errorCode", it) }
              r.errorMessage?.let { put("errorMessage", it) }
              put("includeVideo", entry.includeVideo)
              put(
                "range",
                JSONObject().apply {
                  entry.range.minHeight?.let { put("minHeight", it) }
                  entry.range.maxHeight?.let { put("maxHeight", it) }
                  entry.range.maxBitrate?.let { put("maxBitrate", it) }
                },
              )
              entry.audioName?.let { put("audioName", it) }
              entry.videoName?.let { put("videoName", it) }
              entry.audioIsOpus?.let { put("audioIsOpus", it) }
            },
          )
        }
      }.toString()
    }
    context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString("records", json).apply()
  }

  private fun JSONObject.optStringOrNull(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null
  private fun JSONObject.optIntOrNull(key: String): Int? = if (has(key) && !isNull(key)) getInt(key) else null
  private fun JSONObject.optLongOrNull(key: String): Long? = if (has(key) && !isNull(key)) getLong(key) else null
  private fun JSONObject.optDoubleOrNull(key: String): Double? = if (has(key) && !isNull(key)) getDouble(key) else null
  private fun JSONObject.optBooleanOrNull(key: String): Boolean? = if (has(key) && !isNull(key)) getBoolean(key) else null

  private fun encodeTrack(track: EPTrack): JSONObject = JSONObject().apply {
    put("id", track.id)
    put("title", track.title)
    put("artist", track.artist)
    track.album?.let { put("album", it) }
    track.artwork?.let { put("artwork", it) }
    track.duration?.let { put("duration", it) }
    track.startTime?.let { put("startTime", it) }
    track.endTime?.let { put("endTime", it) }
    track.url?.let { put("url", it) }
    track.userAgent?.let { put("userAgent", it) }
    track.contentType?.let { put("contentType", it) }
    put("headers", JSONObject(track.headers))
    track.sabr?.let { sabr ->
      put(
        "sabr",
        JSONObject().apply {
          put("videoId", sabr.videoId)
          put("serverAbrStreamingUrl", sabr.serverAbrStreamingUrl)
          put("videoPlaybackUstreamerConfig", sabr.videoPlaybackUstreamerConfig)
          put("poToken", sabr.poToken)
          put("clientName", sabr.clientName)
          put("clientVersion", sabr.clientVersion)
          sabr.cookie?.let { put("cookie", it) }
          put("duration", sabr.duration)
          put("formats", JSONArray(sabr.formats.map(::encodeFormat)))
        },
      )
    }
  }

  private fun encodeFormat(f: EPSabrFormat): JSONObject = JSONObject().apply {
    put("itag", f.itag)
    put("lastModified", f.lastModified)
    f.xtags?.let { put("xtags", it) }
    f.mimeType?.let { put("mimeType", it) }
    put("bitrate", f.bitrate)
    f.averageBitrate?.let { put("averageBitrate", it) }
    put("approxDurationMs", f.approxDurationMs)
    f.contentLength?.let { put("contentLength", it) }
    f.width?.let { put("width", it) }
    f.height?.let { put("height", it) }
    f.fps?.let { put("fps", it) }
    f.quality?.let { put("quality", it) }
    f.qualityLabel?.let { put("qualityLabel", it) }
    f.audioQuality?.let { put("audioQuality", it) }
    f.audioSampleRate?.let { put("audioSampleRate", it) }
    f.audioChannels?.let { put("audioChannels", it) }
    f.audioTrackId?.let { put("audioTrackId", it) }
    f.language?.let { put("language", it) }
    f.isDrc?.let { put("isDrc", it) }
    f.isVb?.let { put("isVb", it) }
    f.isSr?.let { put("isSr", it) }
    f.isHdr?.let { put("isHdr", it) }
    f.isDubbed?.let { put("isDubbed", it) }
    f.isAutoDubbed?.let { put("isAutoDubbed", it) }
    f.isDescriptive?.let { put("isDescriptive", it) }
    f.isSecondary?.let { put("isSecondary", it) }
    f.isOriginal?.let { put("isOriginal", it) }
  }

  private fun decodeFormat(o: JSONObject): EPSabrFormat = EPSabrFormat(
    itag = o.getInt("itag"),
    lastModified = o.getString("lastModified"),
    xtags = o.optStringOrNull("xtags"),
    mimeType = o.optStringOrNull("mimeType"),
    bitrate = o.getInt("bitrate"),
    averageBitrate = o.optIntOrNull("averageBitrate"),
    approxDurationMs = o.optLong("approxDurationMs", 0),
    contentLength = o.optLongOrNull("contentLength"),
    width = o.optIntOrNull("width"),
    height = o.optIntOrNull("height"),
    fps = o.optIntOrNull("fps"),
    quality = o.optStringOrNull("quality"),
    qualityLabel = o.optStringOrNull("qualityLabel"),
    audioQuality = o.optStringOrNull("audioQuality"),
    audioSampleRate = o.optIntOrNull("audioSampleRate"),
    audioChannels = o.optIntOrNull("audioChannels"),
    audioTrackId = o.optStringOrNull("audioTrackId"),
    language = o.optStringOrNull("language"),
    isDrc = o.optBooleanOrNull("isDrc"),
    isVb = o.optBooleanOrNull("isVb"),
    isSr = o.optBooleanOrNull("isSr"),
    isHdr = o.optBooleanOrNull("isHdr"),
    isDubbed = o.optBooleanOrNull("isDubbed"),
    isAutoDubbed = o.optBooleanOrNull("isAutoDubbed"),
    isDescriptive = o.optBooleanOrNull("isDescriptive"),
    isSecondary = o.optBooleanOrNull("isSecondary"),
    isOriginal = o.optBooleanOrNull("isOriginal"),
  )

  private fun decodeTrack(o: JSONObject): EPTrack {
    val headers = o.optJSONObject("headers")?.let { h -> h.keys().asSequence().associateWith { h.getString(it) } } ?: emptyMap()
    val sabr = o.optJSONObject("sabr")?.let { s ->
      val formats = s.getJSONArray("formats")
      EPSabrInfo(
        videoId = s.getString("videoId"),
        serverAbrStreamingUrl = s.getString("serverAbrStreamingUrl"),
        videoPlaybackUstreamerConfig = s.getString("videoPlaybackUstreamerConfig"),
        formats = (0 until formats.length()).map { decodeFormat(formats.getJSONObject(it)) },
        poToken = s.getString("poToken"),
        clientName = s.getInt("clientName"),
        clientVersion = s.getString("clientVersion"),
        cookie = s.optStringOrNull("cookie"),
        duration = s.optDouble("duration", 0.0),
      )
    }
    return EPTrack(
      id = o.getString("id"),
      title = o.optString("title"),
      artist = o.optString("artist"),
      album = o.optStringOrNull("album"),
      artwork = o.optStringOrNull("artwork"),
      duration = o.optDoubleOrNull("duration"),
      startTime = o.optDoubleOrNull("startTime"),
      endTime = o.optDoubleOrNull("endTime"),
      url = o.optStringOrNull("url"),
      sabr = sabr,
      userAgent = o.optStringOrNull("userAgent"),
      contentType = o.optStringOrNull("contentType"),
      headers = headers,
    )
  }
}
