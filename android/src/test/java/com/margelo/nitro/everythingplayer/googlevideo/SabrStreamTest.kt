package com.margelo.nitro.everythingplayer.googlevideo

import com.margelo.nitro.everythingplayer.googlevideo.core.GoogleVideoError
import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.StreamProtectionStatus
import com.margelo.nitro.everythingplayer.googlevideo.types.FormatSelector
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrPlaybackOptions
import com.margelo.nitro.everythingplayer.googlevideo.types.SabrStreamEvent
import com.margelo.nitro.everythingplayer.googlevideo.utils.EnabledTrackTypes
import com.margelo.nitro.everythingplayer.googlevideo.utils.LogLevel
import com.margelo.nitro.everythingplayer.googlevideo.utils.Logger
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

private fun <T> blocking(block: suspend () -> T): T = runBlocking { withTimeout(120_000) { block() } }

class SabrStreamTest {
  @Before
  fun setUp() {
    Logger.getInstance().setLogLevels(LogLevel.NONE)
  }

  @Test
  fun shouldDownloadAVodStreamVideoAndAudio() = blocking {
    val server = MockSabrServer()

    val formatInitializations = AtomicInteger(0)
    val streamProtectionStatuses = mutableListOf<StreamProtectionStatus>()
    val finishes = AtomicInteger(0)

    val stream = createSabrStream(server)

    stream.on(SabrStreamEvent.formatInitialization) { formatInitializations.incrementAndGet() }
    stream.on(SabrStreamEvent.streamProtectionStatusUpdate) { synchronized(streamProtectionStatuses) { streamProtectionStatuses.add(it) } }
    stream.on(SabrStreamEvent.finish) { finishes.incrementAndGet() }

    val result = stream.start(
      SabrPlaybackOptions(
        videoFormat = FormatSelector.Format(VIDEO_FORMAT),
        audioFormat = FormatSelector.Format(AUDIO_FORMAT),
        isPostLiveDvr = false,
      ),
    )

    val (videoChunks, audioChunks) = coroutineScope {
      val video = async { collectStreamChunks(result.videoStream) }
      val audio = async { collectStreamChunks(result.audioStream) }
      video.await() to audio.await()
    }

    assertEquals(AUDIO_FORMAT, result.selectedFormats.audioFormat)
    assertEquals(VIDEO_FORMAT, result.selectedFormats.videoFormat)
    assertEquals(1, finishes.get())
    assertEquals(2, formatInitializations.get())
    assertTrue(streamProtectionStatuses.contains(StreamProtectionStatus.newBuilder().setStatus(1).setMaxRetries(0).build()))
    assertEquals(VIDEO_FORMAT.contentLength, totalLength(videoChunks))
    assertEquals(AUDIO_FORMAT.contentLength, totalLength(audioChunks))

    assertEquals(TOTAL_SEGMENTS, server.calls.get())
  }

  @Test
  fun shouldDownloadAnAudioOnlyStream() = blocking {
    val server = MockSabrServer()

    val stream = createSabrStream(server)

    val result = stream.start(
      SabrPlaybackOptions(
        videoFormat = FormatSelector.Format(VIDEO_FORMAT),
        audioFormat = FormatSelector.Format(AUDIO_FORMAT),
        enabledTrackTypes = EnabledTrackTypes.AUDIO_ONLY,
        isPostLiveDvr = false,
      ),
    )

    val audioChunks = collectStreamChunks(result.audioStream)

    assertEquals(AUDIO_FORMAT.contentLength, totalLength(audioChunks))
    assertEquals(TOTAL_SEGMENTS, server.calls.get())
  }

  @Test
  fun shouldNotBeReusableAfterItHasBeenStarted() = blocking {
    val server = MockSabrServer()

    val stream = createSabrStream(server)

    val options = SabrPlaybackOptions(
      videoFormat = FormatSelector.Format(VIDEO_FORMAT),
      audioFormat = FormatSelector.Format(AUDIO_FORMAT),
      isPostLiveDvr = false,
    )

    val result = stream.start(options)

    coroutineScope {
      val video = async { collectStreamChunks(result.videoStream) }
      val audio = async { collectStreamChunks(result.audioStream) }
      video.await()
      audio.await()
    }

    assertEquals(TOTAL_SEGMENTS, server.calls.get())

    val error = assertThrows(GoogleVideoError::class.java) { stream.start(options) }
    assertEquals("This stream instance has already been started and cannot be reused", error.message)
  }

  @Test
  fun shouldAbortTheStreamWhenAbortIsCalled() = blocking {
    val server = MockSabrServer()

    val stream = createSabrStream(server)

    val aborts = AtomicInteger(0)
    stream.on(SabrStreamEvent.abort) { aborts.incrementAndGet() }

    val result = stream.start(
      SabrPlaybackOptions(
        videoFormat = FormatSelector.Format(VIDEO_FORMAT),
        audioFormat = FormatSelector.Format(AUDIO_FORMAT),
        isPostLiveDvr = false,
      ),
    )

    stream.abort()

    assertEquals("Stream aborted", runCatching { result.videoStream.getReader().read() }.exceptionOrNull()?.message)
    assertEquals("Stream aborted", runCatching { result.audioStream.getReader().read() }.exceptionOrNull()?.message)
    assertEquals(1, aborts.get())
  }

  @Test
  fun shouldFailAfterExhaustingAllRetryAttemptsWhenServerReturnsAnError() = blocking {
    val server = MockSabrServer(responseStatus = 500)

    val stream = createSabrStream(server)

    val result = stream.start(
      SabrPlaybackOptions(
        videoFormat = FormatSelector.Format(VIDEO_FORMAT),
        audioFormat = FormatSelector.Format(AUDIO_FORMAT),
        isPostLiveDvr = false,
        maxRetries = 1,
      ),
    )

    assertEquals("Server returned 500", runCatching { collectStreamChunks(result.audioStream) }.exceptionOrNull()?.message)
    assertEquals(2, server.calls.get())
  }

  @Test
  fun shouldFailAfterExhaustingAllRetryAttemptsWhenASabrErrorIsReceived() = blocking {
    val server = MockSabrServer(simulateSabrError = true)

    val stream = createSabrStream(server)

    val result = stream.start(
      SabrPlaybackOptions(
        videoFormat = FormatSelector.Format(VIDEO_FORMAT),
        audioFormat = FormatSelector.Format(AUDIO_FORMAT),
        isPostLiveDvr = false,
        maxRetries = 1,
      ),
    )

    assertEquals("SABR Error: whatthehell - 123", runCatching { collectStreamChunks(result.audioStream) }.exceptionOrNull()?.message)
    assertEquals(2, server.calls.get())
  }

  @Test
  fun shouldFailAfterExhaustingAllRetryAttemptsWhenStreamProtectionAttestationIsRejected() = blocking {
    val server = MockSabrServer(streamProtectionStatus = 3, streamProtectionMaxRetries = 2)

    val stream = createSabrStream(server)

    val result = stream.start(
      SabrPlaybackOptions(
        videoFormat = FormatSelector.Format(VIDEO_FORMAT),
        audioFormat = FormatSelector.Format(AUDIO_FORMAT),
        isPostLiveDvr = false,
        maxRetries = 1,
      ),
    )

    assertEquals(
      "Stream protection attestation rejected after 2 attempts",
      runCatching { collectStreamChunks(result.audioStream) }.exceptionOrNull()?.message,
    )
    assertEquals(4, server.calls.get())
  }

  @Test
  fun shouldRestreamFromTheSeekPositionAfterFinishing() = blocking {
    val server = MockSabrServer()

    val stream = createSabrStream(server)
    val finishes = AtomicInteger(0)
    stream.on(SabrStreamEvent.finish) { finishes.incrementAndGet() }

    val first = stream.start(
      SabrPlaybackOptions(
        audioFormat = FormatSelector.Itag(AUDIO_FORMAT.itag),
        enabledTrackTypes = EnabledTrackTypes.AUDIO_ONLY,
        isPostLiveDvr = false,
      ),
    )

    assertEquals(AUDIO_FORMAT.contentLength, totalLength(collectStreamChunks(first.audioStream)))
    assertEquals(1, finishes.get())

    val second = stream.seek(toMs = 0)
    assertNotNull(second)
    assertEquals(AUDIO_FORMAT.contentLength, totalLength(collectStreamChunks(second!!.audioStream)))
    assertEquals(2, finishes.get())
    assertEquals(TOTAL_SEGMENTS * 2, server.calls.get())
    assertEquals(0L, server.requests[TOTAL_SEGMENTS].clientAbrState.playerTimeMs)
  }

  @Test
  fun shouldParkAWarmedStreamUntilSeek() = blocking {
    val server = MockSabrServer()

    val stream = createSabrStream(server)

    stream.warm(
      SabrPlaybackOptions(
        audioFormat = FormatSelector.Itag(AUDIO_FORMAT.itag),
        enabledTrackTypes = EnabledTrackTypes.AUDIO_ONLY,
        isPostLiveDvr = false,
      ),
    )

    while (server.calls.get() < 1 || stream.isBusy) delay(10)
    delay(200)
    assertEquals(1, server.calls.get())

    val result = stream.seek(toMs = 0)
    assertNotNull(result)
    assertEquals(AUDIO_FORMAT.contentLength, totalLength(collectStreamChunks(result!!.audioStream)))
    assertEquals(1 + TOTAL_SEGMENTS, server.calls.get())
  }
}
