package com.margelo.nitro.everythingplayer.googlevideo.utils

import com.margelo.nitro.everythingplayer.googlevideo.protos.video_streaming.MediaHeader
import kotlin.math.ceil
import kotlin.math.floor

fun ticksToMs(ticks: Long, timescale: Long, round: (Double) -> Double): Long =
  round((ticks.toDouble() / timescale.toDouble()) * 1000).toLong()

fun getDurationMs(mediaHeader: MediaHeader): Long {
  val durationMsFromHeader = if (mediaHeader.hasDurationMs()) mediaHeader.durationMs else 0L

  if (durationMsFromHeader > 0) {
    return durationMsFromHeader
  }

  val durationTicks = if (mediaHeader.timeRange.hasDurationTicks()) mediaHeader.timeRange.durationTicks else 0L
  val timescale = if (mediaHeader.timeRange.hasTimescale()) mediaHeader.timeRange.timescale.toLong() else 0L

  if (durationTicks > 0 && timescale > 0) {
    return ticksToMs(durationTicks, timescale, ::ceil)
  }

  return 0
}

fun getStartMs(mediaHeader: MediaHeader): Long {
  val startMsFromHeader = if (mediaHeader.hasStartMs()) mediaHeader.startMs else 0L

  if (startMsFromHeader > 0) {
    return startMsFromHeader
  }

  val startTicks = if (mediaHeader.timeRange.hasStartTicks()) mediaHeader.timeRange.startTicks else 0L
  val timescale = if (mediaHeader.timeRange.hasTimescale()) mediaHeader.timeRange.timescale.toLong() else 0L

  if (startTicks > 0 && timescale > 0) {
    return ticksToMs(startTicks, timescale, ::floor)
  }

  return 0
}
