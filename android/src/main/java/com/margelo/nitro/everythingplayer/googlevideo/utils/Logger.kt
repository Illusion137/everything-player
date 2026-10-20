package com.margelo.nitro.everythingplayer.googlevideo.utils

import android.util.Log

enum class LogLevel(val rawValue: Int) {
  NONE(0),
  ERROR(1),
  WARN(2),
  INFO(3),
  DEBUG(4),
  ALL(99);

  val label: String
    get() = when (this) {
      NONE -> "NONE"
      ERROR -> "ERROR"
      WARN -> "WARN"
      INFO -> "INFO"
      DEBUG -> "DEBUG"
      ALL -> "ALL"
    }
}

class Logger private constructor() {
  private val lock = Any()
  private var currentLogLevels: Set<LogLevel> = setOf(LogLevel.ERROR, LogLevel.WARN)

  fun setLogLevels(vararg levels: LogLevel) {
    synchronized(lock) {
      currentLogLevels = when {
        levels.isEmpty() || levels.contains(LogLevel.NONE) -> emptySet()
        levels.contains(LogLevel.ALL) -> setOf(LogLevel.ERROR, LogLevel.WARN, LogLevel.INFO, LogLevel.DEBUG)
        else -> levels.filter { it != LogLevel.NONE && it != LogLevel.ALL }.toSet()
      }
    }
  }

  fun getLogLevels(): Set<LogLevel> = synchronized(lock) { currentLogLevels }

  private fun log(level: LogLevel, tag: String, messages: Array<out Any?>) {
    if (level != LogLevel.NONE && getLogLevels().contains(level)) {
      val prefix = "[${level.label}] [$tag]"
      val line = (listOf(prefix) + messages.map { it.toString() }).joinToString(" ")
      val priority = when (level) {
        LogLevel.ERROR -> Log.ERROR
        LogLevel.WARN -> Log.WARN
        LogLevel.INFO -> Log.INFO
        else -> Log.DEBUG
      }
      Log.println(priority, "GoogleVideo", line)
    }
  }

  fun error(tag: String, vararg messages: Any?) = log(LogLevel.ERROR, tag, messages)

  fun warn(tag: String, vararg messages: Any?) = log(LogLevel.WARN, tag, messages)

  fun info(tag: String, vararg messages: Any?) = log(LogLevel.INFO, tag, messages)

  fun debug(tag: String, vararg messages: Any?) = log(LogLevel.DEBUG, tag, messages)

  companion object {
    private val instance = Logger()

    fun getInstance(): Logger = instance
  }
}
