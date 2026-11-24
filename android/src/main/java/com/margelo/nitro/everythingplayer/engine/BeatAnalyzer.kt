package com.margelo.nitro.everythingplayer.engine

import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.log2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

data class EPBeatGrid(val period: Double, val anchor: Double, val confidence: Double) {
  fun downbeatAtOrAfter(time: Double): Double = anchor + ceil((time - anchor) / (4 * period) - 1e-6) * 4 * period
  fun downbeatAtOrBefore(time: Double): Double = anchor + floor((time - anchor) / (4 * period) + 1e-6) * 4 * period
}

class EPBeatAnalyzer {
  private val full = HashMap<Int, Float>()
  private val bass = HashMap<Int, Float>()
  private var latest = 0
  private var expected = -1.0
  private var sampleRate = 0.0
  private var accFull = 0f
  private var accBass = 0f
  private var accCount = 0
  private var accStart = 0.0
  private var low = 0f
  private var alpha = 0f

  @Synchronized
  fun push(interleaved: FloatArray, channels: Int, frames: Int, rate: Double, at: Double) {
    if (channels <= 0 || frames <= 0 || rate <= 0 || !at.isFinite()) return
    if (rate != sampleRate || abs(at - expected) > 0.02) {
      sampleRate = rate
      alpha = (1 - exp(-2 * PI * 150 / rate)).toFloat()
      accFull = 0f
      accBass = 0f
      accCount = 0
      accStart = at
      low = 0f
    }
    val per = max(1, (rate * HOP).toInt())
    val scale = 1f / channels
    for (f in 0 until frames) {
      var x = 0f
      for (c in 0 until channels) x += interleaved[f * channels + c]
      x *= scale
      low += alpha * (x - low)
      accFull += x * x
      accBass += low * low
      accCount++
      if (accCount == per) {
        val key = (accStart / HOP).roundToInt()
        full[key] = accFull / per
        bass[key] = accBass / per
        latest = max(latest, key)
        accStart += per / rate
        accFull = 0f
        accBass = 0f
        accCount = 0
      }
    }
    expected = accStart + accCount / rate
    if (full.size > 120_000) {
      val floor = latest - 60_000
      full.keys.removeAll { it < floor }
      bass.keys.removeAll { it < floor }
    }
  }

  @Synchronized
  fun covered(from: Double, to: Double): Boolean {
    val a = (from / HOP).roundToInt()
    val b = (to / HOP).roundToInt()
    if (b <= a) return false
    var present = 0
    for (i in a until b) if (full.containsKey(i)) present++
    return present >= 0.9 * (b - a)
  }

  fun grid(from: Double, to: Double): EPBeatGrid? {
    val a = (from / HOP).roundToInt()
    val n = ((to - from) / HOP).roundToInt()
    if (n < 2000) return null
    val fullLog = DoubleArray(n)
    val bassLog = DoubleArray(n)
    var present = 0
    synchronized(this) {
      var lastFull = 0f
      var lastBass = 0f
      for (i in 0 until n) {
        full[a + i]?.let {
          lastFull = it
          lastBass = bass[a + i] ?: 0f
          present++
        }
        fullLog[i] = ln(1e-7 + lastFull)
        bassLog[i] = ln(1e-7 + lastBass)
      }
    }
    if (present < 2000) return null
    return estimate(fullLog, bassLog, a * HOP)
  }

  private fun estimate(full: DoubleArray, bass: DoubleArray, origin: Double): EPBeatGrid? {
    val n = full.size
    val onset = DoubleArray(n)
    val bassOnset = DoubleArray(n)
    for (i in 2 until n) {
      val b = max(0.0, bass[i] - bass[i - 2])
      bassOnset[i] = b
      onset[i] = b + 0.5 * max(0.0, full[i] - full[i - 2])
    }
    val prefix = DoubleArray(n + 1)
    for (i in 0 until n) prefix[i + 1] = prefix[i] + onset[i]
    val radius = 50
    val env = DoubleArray(n)
    var total = 0.0
    for (i in 0 until n) {
      val lo = max(0, i - radius)
      val hi = min(n, i + radius + 1)
      env[i] = max(0.0, onset[i] - (prefix[hi] - prefix[lo]) / (hi - lo))
      total += env[i]
    }
    if (total <= 0) return null

    val minLag = floor(60.0 / 180.0 / HOP).toInt()
    val maxLag = ceil(60.0 / 70.0 / HOP).toInt()
    if (n <= maxLag * 4) return null
    var bestLag = 0
    var bestScore = Double.NEGATIVE_INFINITY
    for (lag in minLag..maxLag) {
      var sum = 0.0
      for (i in 0 until n - lag) sum += env[i] * env[i + lag]
      val bpm = 60.0 / (lag * HOP)
      val prior = exp(-0.5 * (log2(bpm / 120.0) / 0.8).pow(2))
      val score = sum / (n - lag) * prior
      if (score > bestScore) {
        bestScore = score
        bestLag = lag
      }
    }
    if (bestLag == 0) return null

    fun comb(period: Double): Pair<Double, Double> {
      val w = 2 * PI * HOP / period
      val cr = cos(w)
      val ci = sin(w)
      var zr = 1.0
      var zi = 0.0
      var re = 0.0
      var im = 0.0
      for (i in 0 until n) {
        re += env[i] * zr
        im += env[i] * zi
        val nr = zr * cr - zi * ci
        zi = zr * ci + zi * cr
        zr = nr
      }
      return Pair(sqrt(re * re + im * im) / total, atan2(im, re))
    }

    var period = bestLag * HOP
    var best = comb(period)
    for ((span, step) in listOf(0.04 to 0.0005, 0.0006 to 0.00002)) {
      val center = period
      var k = -span
      while (k <= span) {
        val p = center * (1 + k)
        val r = comb(p)
        if (r.first > best.first) {
          best = r
          period = p
        }
        k += step
      }
    }

    var phase = (best.second / (2 * PI) * period) % period
    if (phase < 0) phase += period

    var bestBar = 0
    var barScore = -1.0
    for (k in 0 until 4) {
      var sum = 0.0
      var t = phase + k * period
      while (t < n * HOP) {
        val c = (t / HOP).roundToInt()
        var peak = 0.0
        for (j in max(0, c - 2)..min(n - 1, c + 2)) peak = max(peak, bassOnset[j])
        sum += peak
        t += 4 * period
      }
      if (sum > barScore) {
        barScore = sum
        bestBar = k
      }
    }
    return EPBeatGrid(period, origin + phase + bestBar * period, best.first)
  }

  companion object {
    const val HOP = 0.005
  }
}

@OptIn(UnstableApi::class)
class EPAnalyzingAudioSink(sink: AudioSink, private val beats: EPBeatAnalyzer) : ForwardingAudioSink(sink) {
  private var encoding = C.ENCODING_INVALID
  private var channels = 0
  private var sampleRate = 0
  private var lastBuffer: ByteBuffer? = null
  private var lastPts = Long.MIN_VALUE

  override fun configure(inputFormat: Format, specifiedBufferSize: Int, outputChannels: IntArray?) {
    encoding = inputFormat.pcmEncoding
    channels = inputFormat.channelCount
    sampleRate = inputFormat.sampleRate
    super.configure(inputFormat, specifiedBufferSize, outputChannels)
  }

  override fun handleBuffer(buffer: ByteBuffer, presentationTimeUs: Long, encodedAccessUnitCount: Int): Boolean {
    if (buffer !== lastBuffer || presentationTimeUs != lastPts) {
      lastBuffer = buffer
      lastPts = presentationTimeUs
      analyze(buffer, presentationTimeUs)
    }
    return super.handleBuffer(buffer, presentationTimeUs, encodedAccessUnitCount)
  }

  private fun analyze(buffer: ByteBuffer, presentationTimeUs: Long) {
    if (channels <= 0 || sampleRate <= 0) return
    val view = buffer.duplicate().order(ByteOrder.nativeOrder())
    val samples = when (encoding) {
      C.ENCODING_PCM_16BIT -> {
        val shorts = view.asShortBuffer()
        FloatArray(shorts.remaining()) { shorts.get(it) / 32768f }
      }
      C.ENCODING_PCM_FLOAT -> {
        val floats = view.asFloatBuffer()
        FloatArray(floats.remaining()) { floats.get(it) }
      }
      else -> return
    }
    beats.push(samples, channels, samples.size / channels, sampleRate.toDouble(), presentationTimeUs / 1_000_000.0)
  }

  override fun flush() {
    lastBuffer = null
    lastPts = Long.MIN_VALUE
    super.flush()
  }
}

@OptIn(UnstableApi::class)
class EPBassShelfProcessor : BaseAudioProcessor() {
  @Volatile var cut = 0f
  private var appliedCut = -1f
  private var sampleRate = 44100
  private var channels = 2
  private val coeffs = DoubleArray(5)
  private var state = DoubleArray(0)

  override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) return AudioProcessor.AudioFormat.NOT_SET
    sampleRate = inputAudioFormat.sampleRate
    channels = inputAudioFormat.channelCount
    return inputAudioFormat
  }

  override fun onFlush() {
    state = DoubleArray(channels * 4)
    appliedCut = -1f
  }

  override fun queueInput(inputBuffer: ByteBuffer) {
    val size = inputBuffer.remaining()
    if (size == 0) return
    val output = replaceOutputBuffer(size)
    val amount = cut
    if (amount <= 0.001f) {
      output.put(inputBuffer)
      output.flip()
      return
    }
    if (amount != appliedCut) updateCoefficients(amount)
    if (state.size != channels * 4) state = DoubleArray(channels * 4)
    val input = inputBuffer.order(ByteOrder.nativeOrder())
    var channel = 0
    while (input.remaining() >= 2) {
      val x = input.short / 32768.0
      val s = channel * 4
      val y = coeffs[0] * x + coeffs[1] * state[s] + coeffs[2] * state[s + 1] - coeffs[3] * state[s + 2] - coeffs[4] * state[s + 3]
      state[s + 1] = state[s]
      state[s] = x
      state[s + 3] = state[s + 2]
      state[s + 2] = y
      output.putShort((y.coerceIn(-1.0, 1.0) * 32767).toInt().toShort())
      channel = (channel + 1) % channels
    }
    output.flip()
  }

  private fun updateCoefficients(amount: Float) {
    appliedCut = amount
    val a = 10.0.pow(BASS_CUT_GAIN * amount / 40.0)
    val w = 2 * PI * BASS_FREQUENCY / sampleRate
    val cw = cos(w)
    val beta = 2 * sqrt(a) * sin(w) / 2 * sqrt(2.0)
    val a0 = (a + 1) + (a - 1) * cw + beta
    coeffs[0] = a * ((a + 1) - (a - 1) * cw + beta) / a0
    coeffs[1] = 2 * a * ((a - 1) - (a + 1) * cw) / a0
    coeffs[2] = a * ((a + 1) - (a - 1) * cw - beta) / a0
    coeffs[3] = -2 * ((a - 1) + (a + 1) * cw) / a0
    coeffs[4] = ((a + 1) + (a - 1) * cw - beta) / a0
  }

  companion object {
    private const val BASS_FREQUENCY = 180.0
    private const val BASS_CUT_GAIN = -24.0
  }
}
