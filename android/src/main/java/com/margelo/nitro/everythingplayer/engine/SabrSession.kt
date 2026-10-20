package com.margelo.nitro.everythingplayer.engine

import com.margelo.nitro.everythingplayer.googlevideo.core.SabrStream
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatSelector
import com.margelo.nitro.everythingplayer.googlevideo.types.ReloadResponse
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrPlaybackOptions
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamCallbacks
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamConfig
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamEvent
import com.margelo.nitro.everythingplayer.googlevideo.types.StreamStartResult
import com.margelo.nitro.everythingplayer.googlevideo.utils.EnabledTrackTypes
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.Executors

private val sabrScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

interface EPSabrSessionOwner {
  fun onSessionReload(session: EPSabrSession, serverAbrStreamingUrl: String, config: String)
  fun onSessionMint(session: EPSabrSession, token: ByteArray)
  fun onSessionCallbackFailed(session: EPSabrSession, error: EPError)
  fun onSessionStreamFailed(session: EPSabrSession, error: Throwable)
}

class EPSabrSession(
  track: EPTrack,
  info: EPSabrInfo,
  poToken: String,
  options: EPSetupOptions,
  provider: EPSabrCallbackProvider?,
  val audioItag: Int,
  val videoItag: Int?,
) {
  val trackId: String = track.id
  private val created = System.nanoTime()
  val stream: SabrStream
  @Volatile var owner: EPSabrSessionOwner? = null
  @Volatile private var failed = false

  init {
    val trackId = track.id
    val timeout = options.sabrCallbackTimeoutMs
    val callbacks = SabrStreamCallbacks(
      onReloadPlayerResponse = { context ->
        if (provider == null) throw EPError(EPErrorCode.SABR_CALLBACK_FAILED, "No SABR callback provider")
        try {
          val token = context?.reloadPlaybackParams?.token
          val response = epWithTimeout(timeout, "onReloadPlayerResponse") {
            provider.reloadPlayerResponse(trackId, token)
          }
          owner?.onSessionReload(this, response.first, response.second)
          ReloadResponse(serverAbrStreamingUrl = response.first, videoPlaybackUstreamerConfig = response.second)
        } catch (error: Throwable) {
          callbackFailed(error)
          throw error
        }
      },
      onMintPoToken = {
        if (provider == null) throw EPError(EPErrorCode.SABR_CALLBACK_FAILED, "No SABR callback provider")
        try {
          val token = epWithTimeout(timeout, "onMintPoToken") {
            provider.mintPoToken(trackId)
          }
          owner?.onSessionMint(this, token)
          token
        } catch (error: Throwable) {
          callbackFailed(error)
          throw error
        }
      },
    )
    stream = SabrStream(
      SabrStreamConfig(
        videoId = info.videoId,
        fetchFunction = EPSabr.fetchFunction(track.requestHeaders),
        serverAbrStreamingUrl = info.serverAbrStreamingUrl,
        videoPlaybackUstreamerConfig = info.videoPlaybackUstreamerConfig,
        poToken = poToken,
        clientInfo = EPSabr.clientInfo(info),
        formats = info.formats.map(EPSabr::googleFormat),
        callbacks = callbacks,
        stripDuplicateInit = true,
        videoHighWaterMark = maxOf(1 shl 20, options.maxBufferBytes),
        audioHighWaterMark = maxOf(512 shl 10, minOf(3 shl 20, options.maxBufferBytes / 4)),
      ),
    )
    com.margelo.nitro.everythingplayer.googlevideo.utils.Logger.getInstance().setLogLevels(com.margelo.nitro.everythingplayer.googlevideo.utils.LogLevel.ALL)
    stream.on(SabrStreamEvent.error) { error ->
      failed = true
      owner?.onSessionStreamFailed(this, error)
    }
  }

  val isUsable: Boolean
    get() = !failed && !stream.isAborted && !stream.isErrored

  val age: Double
    get() = (System.nanoTime() - created) / 1e9

  fun start(seconds: Double): StreamStartResult = stream.start(playbackOptions(seconds))

  fun warm(seconds: Double) {
    stream.warm(playbackOptions(seconds))
  }

  fun abort() {
    val s = stream
    sabrScope.launch { s.abort() }
  }

  private fun playbackOptions(seconds: Double): SabrPlaybackOptions = SabrPlaybackOptions(
    videoFormat = videoItag?.let { FormatSelector.Itag(it) },
    audioFormat = FormatSelector.Itag(audioItag),
    enabledTrackTypes = if (videoItag == null) EnabledTrackTypes.AUDIO_ONLY else EnabledTrackTypes.VIDEO_AND_AUDIO,
    startTimeMs = (seconds * 1000).toLong(),
    isPostLiveDvr = false,
  )

  private fun callbackFailed(error: Throwable) {
    failed = true
    val message = (error as? EPError)?.message ?: error.message ?: error.toString()
    owner?.onSessionCallbackFailed(this, EPError(EPErrorCode.SABR_CALLBACK_FAILED, message))
  }
}

class EPSabrWarmPool {
  private val lock = Any()
  private val queue = Executors.newSingleThreadExecutor { Thread(it, "everythingplayer.sabr.warm").apply { isDaemon = true } }
  private val entries = HashMap<String, EPSabrSession>()

  fun warm(tracks: List<EPTrack>, options: EPSetupOptions, provider: EPSabrCallbackProvider?) {
    queue.execute { warmNow(tracks, options, provider) }
  }

  private fun warmNow(tracks: List<EPTrack>, options: EPSetupOptions, provider: EPSabrCallbackProvider?) {
    val stale = mutableListOf<EPSabrSession>()
    val keep = HashSet<String>()
    for (track in tracks) {
      val info = track.sabr ?: continue
      val (audio, video) = itags(info, options) ?: continue
      keep.add(track.id)
      val existing = synchronized(lock) { entries[track.id] }
      if (existing != null && existing.isUsable && existing.age < MAX_AGE &&
        existing.audioItag == audio && existing.videoItag == video
      ) {
        continue
      }
      val session = EPSabrSession(track, info, info.poToken, options, provider, audio, video)
      if (runCatching { session.warm(track.trimStart) }.isFailure) continue
      synchronized(lock) { entries[track.id] = session }
      if (existing != null) stale.add(existing)
    }
    synchronized(lock) {
      val iterator = entries.entries.iterator()
      while (iterator.hasNext()) {
        val (id, session) = iterator.next()
        if (id !in keep) {
          stale.add(session)
          iterator.remove()
        }
      }
    }
    stale.forEach { it.abort() }
  }

  fun take(trackId: String, audioItag: Int, videoItag: Int?): EPSabrSession? {
    val session = synchronized(lock) { entries.remove(trackId) } ?: return null
    if (!session.isUsable || session.age >= MAX_AGE || session.audioItag != audioItag || session.videoItag != videoItag) {
      session.abort()
      return null
    }
    return session
  }

  fun clear() {
    val all = synchronized(lock) {
      val all = entries.values.toList()
      entries.clear()
      all
    }
    all.forEach { it.abort() }
  }

  companion object {
    const val MAX_AGE = 240.0

    fun itags(info: EPSabrInfo, options: EPSetupOptions): Pair<Int, Int?>? {
      val audio = EPSabr.pickAudio(info.formats) ?: return null
      val video = if (options.enableVideo) EPSabr.pickVideo(info.formats, options.videoQualityRange)?.itag else null
      return audio.itag to video
    }
  }
}
