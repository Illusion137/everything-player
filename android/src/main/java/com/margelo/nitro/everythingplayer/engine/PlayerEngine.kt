package com.margelo.nitro.everythingplayer.engine

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import androidx.core.content.ContextCompat
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

@OptIn(UnstableApi::class)
object EPPlayerEngine : EPPipelineDelegate {
  var onStateChange: ((EPState, EPError?) -> Unit)? = null
  var onActiveTrackChanged: ((EPActiveTrackChange) -> Unit)? = null
  var onProgress: ((EPProgress, Int?, String?) -> Unit)? = null
  var onError: ((EPError) -> Unit)? = null
  var onQueueEnded: ((Int?, String?, Double) -> Unit)? = null
  var onRemote: ((EPRemoteEvent) -> Unit)? = null
  var onVideoQualityChanged: ((EPVideoQualityState, String?) -> Unit)? = null
  var sabrCallbacks: EPSabrCallbackProvider? = null
  var downloadedResolver: ((EPTrack) -> Boolean)? = null
  var localSabrResolver: ((EPTrack) -> EPLocalSabrMedia?)? = null

  private val main = Handler(Looper.getMainLooper())
  private val sabrPool = EPSabrWarmPool()
  private var sabrTicks = 0
  private val lock = Any()
  private lateinit var appContext: Context

  @Volatile var isSetup = false
    private set
  @Volatile var setupOptions = EPSetupOptions()
    private set
  @Volatile var updateOptions = EPUpdateOptions()
    private set

  private var queue = mutableListOf<EPTrack>()
  private var activeIndex: Int? = null
  private var state = EPState.NONE
  private var lastError: EPError? = null
  private var repeatMode = EPRepeatMode.OFF
  private var crossfadeSeconds = 0.0
  private var volume = 1f
  private var rate = 1f
  private var playWhenReady = false
  private var hasPlayed = false
  private var pendingSeek: Double? = null
  @Volatile private var qualityRange = EPVideoQualityRange()
  @Volatile private var activePipeline: EPPipeline? = null

  private var primary: EPPipeline? = null
  private var secondary: EPPipeline? = null
  private var fading = false
  private var resumeAfterFocusGain = false
  @Volatile private var snapshot = EPProgress(0.0, 0.0, 0.0)

  var session: MediaSession? = null
    private set
  private var audioFocus: EPAudioFocus? = null

  private val tick = object : Runnable {
    override fun run() {
      onTick()
      main.postDelayed(this, 100)
    }
  }

  private val progressTick = object : Runnable {
    override fun run() {
      val interval = updateOptions.progressUpdateEventInterval
      if (interval <= 0) return
      if (getState() == EPState.PLAYING) onProgress?.invoke(getProgress(), getActiveIndex(), currentTrackId())
      main.postDelayed(this, (interval * 1000).toLong())
    }
  }

  private fun onMain(block: () -> Unit) {
    if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
  }

  private inline fun <T> locked(block: () -> T): T = synchronized(lock, block)

  fun setup(context: Context, options: EPSetupOptions) {
    appContext = context.applicationContext
    setupOptions = options
    qualityRange = options.videoQualityRange
    EPMediaCache.configure(appContext, options.cacheMaxSizeMB, options.cacheMaxAgeSeconds, options.persistentCache)
    isSetup = true
    onMain {
      audioFocus = EPAudioFocus(appContext, { change -> handleFocusChange(change) }, { becomingNoisy() })
      main.removeCallbacks(tick)
      main.post(tick)
    }
  }

  fun update(options: EPUpdateOptions) {
    updateOptions = options
    onMain {
      main.removeCallbacks(progressTick)
      if (options.progressUpdateEventInterval > 0) main.postDelayed(progressTick, (options.progressUpdateEventInterval * 1000).toLong())
      refreshSessionPlayer()
    }
  }

  fun getQueue(): List<EPTrack> = locked { queue.toList() }
  fun getActiveIndex(): Int? = locked { activeIndex }
  fun getState(): EPState = locked { state }
  fun getLastError(): EPError? = locked { lastError }
  fun getRepeatMode(): EPRepeatMode = locked { repeatMode }
  fun getVolume(): Float = locked { volume }
  fun getRate(): Float = locked { rate }
  fun isPlayWhenReady(): Boolean = locked { playWhenReady }

  fun getVideoQuality(): EPVideoQualityState = activePipeline?.videoQuality ?: EPVideoQualityState()

  fun getVideoQualityRange(): EPVideoQualityRange = qualityRange

  fun setVideoQualityRange(range: EPVideoQualityRange) {
    qualityRange = range
    onMain {
      val p = primary
      val manual = p?.videoQuality?.takeIf { !it.auto }?.selectedId
      runCatching { p?.setVideoQuality(manual, range) }
      runCatching { secondary?.setVideoQuality(null, range) }
    }
  }

  fun setVideoQuality(id: String?) {
    val p = activePipeline
    if (p == null) {
      if (id != null) throw EPError(EPErrorCode.UNKNOWN, "No active track")
      return
    }
    p.setVideoQuality(id, qualityRange)
  }

  val activeTrackId: String? get() = currentTrackId()

  private fun currentTrackId(): String? = locked { activeIndex?.let { queue.getOrNull(it)?.id } }

  fun getProgress(): EPProgress {
    if (Looper.myLooper() == Looper.getMainLooper()) snapshot = computeProgress()
    val seek = locked { pendingSeek }
    val s = snapshot
    return if (seek != null) s.copy(position = seek, buffered = maxOf(s.buffered, seek)) else s
  }

  private fun computeProgress(): EPProgress {
    val (track, seek) = locked { activeIndex?.let { queue.getOrNull(it) } to pendingSeek }
    track ?: return EPProgress(0.0, 0.0, 0.0)
    val p = primary
    val duration = track.trimEnd(p?.mediaDuration) ?: 0.0
    val position = seek ?: p?.currentTime ?: track.trimStart
    val buffered = p?.bufferedTime ?: position
    val upper = if (duration > 0) duration else maxOf(position, buffered)
    return EPProgress(position.coerceIn(0.0, upper), duration, maxOf(position, buffered).coerceAtMost(upper))
  }

  fun setRepeatMode(mode: EPRepeatMode) {
    locked { repeatMode = mode }
    onMain { invalidateSecondaryIfStale() }
  }

  fun setCrossFade(seconds: Double) {
    locked { crossfadeSeconds = maxOf(0.0, seconds) }
  }

  fun setVolume(value: Float) {
    locked { volume = value }
    onMain { if (!fading) primary?.volume = value }
  }

  fun setRate(value: Float) {
    locked { rate = value }
    onMain {
      primary?.rate = value
      secondary?.rate = value
    }
  }

  fun setEqualizer(gains: FloatArray) {
    EPEqualizerSettings.set(gains)
  }

  fun add(tracks: List<EPTrack>, before: Int?) {
    if (tracks.isEmpty()) return
    val needsLoad = locked {
      val wasEmpty = queue.isEmpty()
      val at = before?.takeIf { it in 0..queue.size } ?: queue.size
      queue.addAll(at, tracks)
      activeIndex?.let { if (at <= it) activeIndex = it + tracks.size }
      if (activeIndex == null && wasEmpty) {
        activeIndex = 0
        true
      } else false
    }
    onMain {
      if (needsLoad) {
        emitActiveChange(null, null, 0.0)
        loadActive(null)
      }
      invalidateSecondaryIfStale()
      preloadUpcoming()
    }
  }

  fun remove(indexes: List<Int>) {
    var removedActive = false
    var lastIndex: Int? = null
    var lastId: String? = null
    val lastPosition = getProgress().position
    locked {
      for (index in indexes.distinct().sortedDescending()) {
        if (index !in queue.indices) continue
        val removed = queue.removeAt(index)
        val a = activeIndex ?: continue
        if (index == a) {
          removedActive = true
          lastIndex = a
          lastId = removed.id
        } else if (index < a) {
          activeIndex = a - 1
        }
      }
      if (removedActive) activeIndex = if (queue.isEmpty()) null else minOf(lastIndex ?: 0, queue.size - 1)
    }
    onMain {
      if (removedActive) {
        emitActiveChange(lastIndex, lastId, lastPosition)
        if (getActiveIndex() == null) {
          releasePipelines()
          setState(EPState.NONE)
        } else {
          loadActive(null)
        }
      }
      invalidateSecondaryIfStale()
    }
  }

  fun removeUpcoming() {
    locked {
      val a = activeIndex ?: return@locked
      while (queue.size > a + 1) queue.removeAt(queue.size - 1)
    }
    onMain { invalidateSecondaryIfStale() }
  }

  fun move(from: Int, to: Int) {
    locked {
      if (from !in queue.indices || to !in queue.indices || from == to) return@locked
      val t = queue.removeAt(from)
      queue.add(to, t)
      val a = activeIndex ?: return@locked
      activeIndex = when {
        a == from -> to
        from < a && to >= a -> a - 1
        from > a && to <= a -> a + 1
        else -> a
      }
    }
    onMain { invalidateSecondaryIfStale() }
  }

  fun setQueue(tracks: List<EPTrack>) {
    val lastPosition = getProgress().position
    var keep = false
    var lastIndex: Int? = null
    var lastId: String? = null
    locked {
      lastIndex = activeIndex
      lastId = activeIndex?.let { queue.getOrNull(it)?.id }
      queue = tracks.toMutableList()
      val newIndex = lastId?.let { id -> tracks.indexOfFirst { it.id == id }.takeIf { it >= 0 } }
      if (newIndex != null) {
        activeIndex = newIndex
        keep = true
      } else {
        activeIndex = if (tracks.isEmpty()) null else 0
      }
    }
    onMain {
      invalidateSecondaryIfStale()
      if (keep) return@onMain
      emitActiveChange(lastIndex, lastId, lastPosition)
      if (getActiveIndex() == null) {
        releasePipelines()
        setState(EPState.NONE)
      } else {
        loadActive(null)
      }
    }
  }

  fun updateMetadata(index: Int, track: EPTrack) {
    val isActive = locked {
      val t = queue.getOrNull(index) ?: return@locked false
      t.title = track.title
      t.artist = track.artist
      t.album = track.album
      t.artwork = track.artwork
      track.duration?.let { t.duration = it }
      index == activeIndex
    }
    if (isActive) onMain { refreshSessionPlayer() }
  }

  fun skip(index: Int, initialPosition: Double?) {
    if (locked { index !in queue.indices }) throw EPError(EPErrorCode.UNKNOWN, "Index $index is out of bounds")
    onMain { transition(index, initialPosition, manual = true) }
  }

  fun skipToNext(initialPosition: Double?) {
    val next = locked { nextIndex(ignoringRepeatTrack = true) } ?: throw EPError(EPErrorCode.UNKNOWN, "There is no next track")
    onMain { transition(next, initialPosition, manual = true) }
  }

  fun skipToPrevious(initialPosition: Double?) {
    val previous = locked {
      val a = activeIndex
      when {
        a == null -> null
        a > 0 -> a - 1
        repeatMode == EPRepeatMode.QUEUE && queue.isNotEmpty() -> queue.size - 1
        else -> null
      }
    }
    if (previous == null) {
      if (getActiveIndex() == null) throw EPError(EPErrorCode.UNKNOWN, "There is no previous track")
      seekTo(initialPosition ?: 0.0)
      return
    }
    onMain { transition(previous, initialPosition, manual = true) }
  }

  private fun nextIndex(ignoringRepeatTrack: Boolean): Int? {
    val a = activeIndex ?: return null
    if (queue.isEmpty()) return null
    if (!ignoringRepeatTrack && repeatMode == EPRepeatMode.TRACK) return a
    if (a + 1 < queue.size) return a + 1
    return if (repeatMode == EPRepeatMode.QUEUE) 0 else null
  }

  fun play() {
    locked { playWhenReady = true }
    onMain {
      audioFocus?.request()
      startService()
      val st = getState()
      val p = primary
      if (st == EPState.ENDED || st == EPState.STOPPED || p == null) {
        if (getActiveIndex() == null) return@onMain
        loadActive(if (st == EPState.ENDED) null else locked { pendingSeek })
        return@onMain
      }
      if (p.status is EPPipelineStatus.Failed) {
        retry()
        return@onMain
      }
      p.play()
      if (fading) secondary?.play()
      syncState()
    }
  }

  fun pause() {
    locked { playWhenReady = false }
    onMain {
      primary?.pause()
      secondary?.pause()
      syncState()
    }
  }

  fun stop() {
    locked {
      playWhenReady = false
      pendingSeek = null
    }
    onMain {
      releasePipelines()
      sabrPool.clear()
      setState(EPState.STOPPED)
      audioFocus?.abandon()
    }
  }

  fun reset() {
    locked {
      playWhenReady = false
      pendingSeek = null
      queue.clear()
      activeIndex = null
      hasPlayed = false
    }
    onMain {
      releasePipelines()
      sabrPool.clear()
      setState(EPState.NONE)
      audioFocus?.abandon()
    }
  }

  fun retry() {
    onMain {
      if (getActiveIndex() == null) return@onMain
      loadActive(primary?.currentTime)
    }
  }

  fun seekTo(seconds: Double) {
    val target = locked {
      val track = activeIndex?.let { queue.getOrNull(it) } ?: return@locked null
      val upper = track.trimEnd(primary?.mediaDuration) ?: maxOf(seconds, track.trimStart)
      seconds.coerceIn(track.trimStart, maxOf(track.trimStart, upper)).also { pendingSeek = it }
    } ?: return
    onProgress?.invoke(getProgress(), getActiveIndex(), currentTrackId())
    onMain {
      cancelFade()
      val p = primary
      if (p != null && getState() != EPState.ENDED) p.seek(target) else loadActive(target)
    }
  }

  fun seekBy(offset: Double) {
    val base = locked { pendingSeek } ?: getProgress().position
    seekTo(base + offset)
  }

  private fun makePipeline(track: EPTrack): EPPipeline {
    val sabr = track.sabr
    val pipeline: EPPipeline = if (sabr != null) {
      val local = localSabrResolver?.invoke(track)
      EPSabrPipeline(appContext, track, sabr, setupOptions, sabrCallbacks, local, if (local == null) sabrPool else null, qualityRange)
    } else {
      EPExoPipeline(appContext, track, setupOptions, downloadedResolver?.invoke(track) == true, qualityRange)
    }
    pipeline.delegate = this
    pipeline.rate = locked { rate }
    return pipeline
  }

  private fun loadActive(position: Double?) {
    if (!::appContext.isInitialized) return
    cancelFade()
    releasePipelines()
    val (track, autoplay) = locked { activeIndex?.let { queue.getOrNull(it) } to playWhenReady }
    track ?: return
    val start = position ?: track.trimStart
    locked {
      pendingSeek = if (start > track.trimStart) start else null
      lastError = null
    }
    val pipeline = makePipeline(track)
    pipeline.volume = locked { volume }
    primary = pipeline
    activePipeline = pipeline
    setState(EPState.LOADING)
    pipeline.load(start)
    pipeline.attachVideo()
    refreshSessionPlayer()
    if (autoplay) {
      audioFocus?.request()
      pipeline.play()
    }
    preloadUpcoming()
  }

  private fun releasePipelines() {
    val p = primary
    val s = secondary
    primary = null
    activePipeline = null
    secondary = null
    fading = false
    p?.delegate = null
    s?.delegate = null
    p?.teardown()
    s?.teardown()
    EPVideoHub.clear()
  }

  private fun transition(index: Int, initialPosition: Double?, manual: Boolean) {
    val lastPosition = getProgress().position
    val lastIndex = getActiveIndex()
    val lastId = currentTrackId()
    val targetId = locked { queue.getOrNull(index)?.id }
    val s = secondary
    if (s != null && s.track.id == targetId && initialPosition == null && !(manual && fading)) {
      promoteSecondary(lastIndex, lastId, lastPosition, index)
      return
    }
    locked { activeIndex = index }
    emitActiveChange(lastIndex, lastId, lastPosition)
    loadActive(initialPosition)
  }

  private fun promoteSecondary(lastIndex: Int?, lastId: String?, lastPosition: Double, newIndex: Int) {
    val next = secondary ?: return
    val old = primary
    primary = next
    activePipeline = next
    secondary = null
    fading = false
    locked {
      activeIndex = newIndex
      pendingSeek = null
    }
    old?.delegate = null
    old?.teardown()
    next.volume = locked { volume }
    next.attachVideo()
    if (isPlayWhenReady()) next.play()
    emitActiveChange(lastIndex, lastId, lastPosition)
    refreshSessionPlayer()
    syncState()
    preloadUpcoming()
    onVideoQualityChanged?.invoke(next.videoQuality, next.track.id)
  }

  private fun cancelFade() {
    if (!fading) return
    fading = false
    val s = secondary
    secondary = null
    s?.delegate = null
    s?.teardown()
    primary?.volume = locked { volume }
  }

  private fun invalidateSecondaryIfStale() {
    val s = secondary ?: return
    val nextId = locked { nextIndex(false)?.let { queue.getOrNull(it)?.id } }
    if (s.track.id != nextId || getRepeatMode() == EPRepeatMode.TRACK) {
      if (fading) {
        cancelFade()
      } else {
        secondary = null
        s.delegate = null
        s.teardown()
      }
    }
  }

  override fun onPipelineStatus(pipeline: EPPipeline, status: EPPipelineStatus) {
    if (pipeline === secondary) {
      if (status == EPPipelineStatus.Ended && fading) finishFade()
      return
    }
    if (pipeline !== primary) return
    when (status) {
      EPPipelineStatus.Ready, EPPipelineStatus.Playing -> locked { pendingSeek = null }
      EPPipelineStatus.Ended -> {
        handleTrackEnded()
        return
      }
      else -> Unit
    }
    syncState()
  }

  override fun onPipelineError(pipeline: EPPipeline, error: EPError) {
    if (pipeline === secondary) {
      if (fading) {
        cancelFade()
      } else {
        secondary = null
        pipeline.delegate = null
        pipeline.teardown()
      }
      return
    }
    if (pipeline !== primary) return
    locked {
      lastError = error
      pendingSeek = null
    }
    setState(EPState.ERROR, error)
    onError?.invoke(error)
  }

  override fun onPipelineDuration(pipeline: EPPipeline) {}

  override fun onPipelineVideoQuality(pipeline: EPPipeline) {
    if (pipeline === primary) onVideoQualityChanged?.invoke(pipeline.videoQuality, pipeline.track.id)
  }

  private fun syncState() {
    val p = primary ?: return
    val (pwr, played) = locked { playWhenReady to hasPlayed }
    val newState = when (p.status) {
      EPPipelineStatus.Idle, EPPipelineStatus.Loading -> EPState.LOADING
      EPPipelineStatus.Buffering -> EPState.BUFFERING
      EPPipelineStatus.Ready -> if (pwr) EPState.BUFFERING else if (played) EPState.PAUSED else EPState.READY
      EPPipelineStatus.Playing -> {
        locked { hasPlayed = true }
        if (pwr) EPState.PLAYING else EPState.PAUSED
      }
      EPPipelineStatus.Ended -> EPState.ENDED
      is EPPipelineStatus.Failed -> return
    }
    setState(newState)
  }

  private fun setState(newState: EPState, error: EPError? = null) {
    val changed = locked {
      if (state == newState) return@locked false
      state = newState
      if (newState != EPState.ERROR) lastError = null
      true
    }
    if (changed) onStateChange?.invoke(newState, error)
  }

  private fun emitActiveChange(lastIndex: Int?, lastTrackId: String?, lastPosition: Double) {
    onActiveTrackChanged?.invoke(EPActiveTrackChange(lastIndex, lastTrackId, lastPosition, getActiveIndex(), currentTrackId()))
  }

  private fun handleTrackEnded() {
    val (mode, active) = locked { repeatMode to activeIndex }
    if (mode == EPRepeatMode.TRACK && active != null) {
      val start = locked { queue[active].trimStart }
      locked { pendingSeek = null }
      primary?.seek(start)
      if (isPlayWhenReady()) primary?.play()
      return
    }
    if (fading && secondary != null) {
      finishFade()
      return
    }
    val next = locked { nextIndex(ignoringRepeatTrack = true) }
    if (next == null) {
      val position = getProgress().position
      setState(EPState.ENDED)
      onQueueEnded?.invoke(active, currentTrackId(), position)
      return
    }
    transition(next, null, manual = false)
  }

  private fun finishFade() {
    val next = locked { nextIndex(ignoringRepeatTrack = true) }
    if (next == null || secondary == null) {
      cancelFade()
      return
    }
    promoteSecondary(getActiveIndex(), currentTrackId(), getProgress().position, next)
  }

  private fun onTick() {
    snapshot = computeProgress()
    sabrTicks += 1
    if (sabrTicks % 300 == 0) warmUpcomingSabr()
    val p = primary ?: return
    if (!::appContext.isInitialized) return
    if (!isPlayWhenReady()) return
    val track = p.track
    val fadeLength = locked { crossfadeSeconds }
    val mode = getRepeatMode()
    val vol = getVolume()
    val end = track.trimEnd(p.mediaDuration) ?: return
    val remaining = end - p.currentTime
    val nextIdx = locked { nextIndex(false) }
    val canFade = fadeLength > 0 && mode != EPRepeatMode.TRACK && (end - track.trimStart) >= 2 * fadeLength

    if (secondary == null && nextIdx != null && mode != EPRepeatMode.TRACK && remaining <= fadeLength + 8 && remaining > 0.25) {
      val nextTrack = locked { queue[nextIdx] }
      val pipeline = makePipeline(nextTrack)
      pipeline.volume = if (canFade) 0f else vol
      secondary = pipeline
      pipeline.load(nextTrack.trimStart)
    }

    val s = secondary ?: return
    if (!canFade || getState() != EPState.PLAYING) return
    if (!fading && remaining <= fadeLength && (s.status == EPPipelineStatus.Ready || s.status == EPPipelineStatus.Playing)) {
      fading = true
      s.volume = 0f
      s.play()
    }
    if (!fading) return
    val progress = (1 - remaining / fadeLength).coerceIn(0.0, 1.0)
    p.volume = vol * cos(progress * PI / 2).toFloat()
    s.volume = vol * sin(progress * PI / 2).toFloat()
    if (remaining <= 0.05) finishFade()
  }

  private fun warmUpcomingSabr() {
    val (tracks, options) = locked {
      val a = activeIndex
      if (a == null || a >= queue.size) return@locked emptyList<EPTrack>() to setupOptions
      val out = mutableListOf<EPTrack>()
      var i: Int = a
      var remaining = maxOf(0, minOf(setupOptions.sabrPoolAhead, queue.size - 1))
      while (remaining-- > 0) {
        i += 1
        if (i >= queue.size) {
          if (repeatMode != EPRepeatMode.QUEUE) break
          i = 0
        }
        out.add(queue[i])
      }
      out to setupOptions
    }
    val candidates = tracks.filter { it.sabr != null && localSabrResolver?.invoke(it) == null }
    sabrPool.warm(candidates, options, sabrCallbacks)
  }

  private fun preloadUpcoming() {
    warmUpcomingSabr()
    val upcoming = locked {
      val a = activeIndex ?: return@locked emptyList()
      queue.drop(a + 1).take(maxOf(0, setupOptions.preloadNext))
    }
    for (track in upcoming) {
      if (track.sourceType != EPSourceType.RAW || downloadedResolver?.invoke(track) == true) continue
      val url = track.url ?: continue
      val uri = Uri.parse(url)
      if (uri.scheme != "http" && uri.scheme != "https") continue
      EPMediaCache.prefetch(appContext, uri, track.requestHeaders, 512L * 1024)
    }
  }

  fun handleRemote(event: EPRemoteEvent) {
    onRemote?.invoke(event)
    if (!setupOptions.autoHandleRemoteEvents) return
    when (event) {
      EPRemoteEvent.Play -> play()
      EPRemoteEvent.Pause -> pause()
      EPRemoteEvent.Stop -> stop()
      EPRemoteEvent.Next -> runCatching { skipToNext(null) }
      EPRemoteEvent.Previous -> runCatching { skipToPrevious(null) }
      is EPRemoteEvent.Seek -> seekTo(event.position)
      is EPRemoteEvent.JumpForward -> seekBy(event.interval)
      is EPRemoteEvent.JumpBackward -> seekBy(-event.interval)
      else -> Unit
    }
  }

  private fun handleFocusChange(change: Int) {
    val auto = setupOptions.autoHandleInterruptions
    when (change) {
      AudioManager.AUDIOFOCUS_LOSS -> {
        resumeAfterFocusGain = false
        if (auto) pause()
        onRemote?.invoke(EPRemoteEvent.Duck(paused = true, permanent = true))
      }
      AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
        resumeAfterFocusGain = getState() == EPState.PLAYING || getState() == EPState.BUFFERING
        if (auto) pause()
        onRemote?.invoke(EPRemoteEvent.Duck(paused = true, permanent = false))
      }
      AudioManager.AUDIOFOCUS_GAIN -> {
        val resume = resumeAfterFocusGain
        resumeAfterFocusGain = false
        if (resume && auto) play()
        onRemote?.invoke(EPRemoteEvent.Duck(paused = !resume, permanent = false))
      }
    }
  }

  fun becomingNoisy() {
    if (setupOptions.autoHandleInterruptions) pause()
  }

  private fun refreshSessionPlayer() {
    val exo = primary?.exoPlayer ?: return
    val player = EPSessionPlayer(exo, this)
    val s = session
    if (s == null) {
      session = MediaSession.Builder(appContext, player).setId("everythingplayer").build()
      PlaybackService.instance?.attach(session!!)
    } else {
      s.player = player
    }
  }

  private fun startService() {
    if (PlaybackService.instance != null) return
    runCatching { appContext.startService(Intent(appContext, PlaybackService::class.java)) }
  }

  fun onTaskRemoved() {
    when (updateOptions.appKilledBehavior) {
      EPAppKilledBehavior.CONTINUE -> Unit
      EPAppKilledBehavior.PAUSE -> pause()
      EPAppKilledBehavior.STOP_AND_REMOVE -> {
        stop()
        onMain {
          session?.release()
          session = null
          PlaybackService.instance?.stopSelf()
        }
      }
    }
  }
}

class EPAudioFocus(
  private val context: Context,
  private val listener: (Int) -> Unit,
  private val onNoisy: () -> Unit,
) {
  private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  private val callback = AudioManager.OnAudioFocusChangeListener {
    if (it == AudioManager.AUDIOFOCUS_LOSS) {
      held = false
      unregisterNoisy()
    }
    listener(it)
  }
  private val noisyReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) onNoisy()
    }
  }
  private var noisyRegistered = false

  private fun registerNoisy() {
    if (noisyRegistered) return
    noisyRegistered = true
    ContextCompat.registerReceiver(context, noisyReceiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY), ContextCompat.RECEIVER_NOT_EXPORTED)
  }

  private fun unregisterNoisy() {
    if (!noisyRegistered) return
    noisyRegistered = false
    runCatching { context.unregisterReceiver(noisyReceiver) }
  }
  private var request: AudioFocusRequest? = null
  private var held = false

  fun request() {
    registerNoisy()
    if (held) return
    held = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val r = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(
          PlatformAudioAttributes.Builder()
            .setUsage(PlatformAudioAttributes.USAGE_MEDIA)
            .setContentType(PlatformAudioAttributes.CONTENT_TYPE_MUSIC)
            .build(),
        )
        .setOnAudioFocusChangeListener(callback)
        .setWillPauseWhenDucked(true)
        .build()
      request = r
      audioManager.requestAudioFocus(r) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    } else {
      @Suppress("DEPRECATION")
      audioManager.requestAudioFocus(callback, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }
  }

  fun abandon() {
    unregisterNoisy()
    if (!held) return
    held = false
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      request?.let { audioManager.abandonAudioFocusRequest(it) }
    } else {
      @Suppress("DEPRECATION")
      audioManager.abandonAudioFocus(callback)
    }
  }
}
