package com.margelo.nitro.everythingplayer.engine

import android.media.audiofx.Equalizer
import kotlin.math.ln

object EPEqualizerSettings {
  private val listeners = mutableSetOf<EPEqualizerController>()

  @Volatile
  var gains: FloatArray = FloatArray(EPEqualizerBands.frequencies.size)
    private set

  @Synchronized
  fun set(newGains: FloatArray) {
    gains = FloatArray(EPEqualizerBands.frequencies.size) { i ->
      (newGains.getOrNull(i) ?: 0f).coerceIn(EPEqualizerBands.MIN_GAIN, EPEqualizerBands.MAX_GAIN)
    }
    listeners.forEach { it.apply(gains) }
  }

  @Synchronized
  fun register(controller: EPEqualizerController) {
    listeners.add(controller)
    controller.apply(gains)
  }

  @Synchronized
  fun unregister(controller: EPEqualizerController) {
    listeners.remove(controller)
  }

  fun gainAt(frequencyHz: Float, gains: FloatArray): Float {
    val f = EPEqualizerBands.frequencies
    if (frequencyHz <= f.first()) return gains.first()
    if (frequencyHz >= f.last()) return gains.last()
    val x = ln(frequencyHz.toDouble())
    for (i in 0 until f.size - 1) {
      val x0 = ln(f[i].toDouble())
      val x1 = ln(f[i + 1].toDouble())
      if (x in x0..x1) {
        val t = ((x - x0) / (x1 - x0)).toFloat()
        return gains[i] + (gains[i + 1] - gains[i]) * t
      }
    }
    return 0f
  }
}

class EPEqualizerController(audioSessionId: Int) {
  private val equalizer: Equalizer? = runCatching {
    Equalizer(0, audioSessionId).apply { enabled = true }
  }.getOrNull()

  init {
    EPEqualizerSettings.register(this)
  }

  fun apply(gains: FloatArray) {
    val eq = equalizer ?: return
    runCatching {
      val range = eq.bandLevelRange
      val flat = gains.all { kotlin.math.abs(it) < 0.01f }
      eq.enabled = !flat
      for (band in 0 until eq.numberOfBands) {
        val centerHz = eq.getCenterFreq(band.toShort()) / 1000f
        val millibels = (EPEqualizerSettings.gainAt(centerHz, gains) * 100).toInt()
        eq.setBandLevel(band.toShort(), millibels.coerceIn(range[0].toInt(), range[1].toInt()).toShort())
      }
    }
  }

  fun release() {
    EPEqualizerSettings.unregister(this)
    runCatching { equalizer?.release() }
  }
}
