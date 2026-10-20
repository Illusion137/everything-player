package com.margelo.nitro.everythingplayer.googlevideo.utils

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi

data class ReadResult<E>(val done: Boolean, val value: E?)

class ReadableStream<E>(
  private val highWaterMark: Int,
  private val sizeOf: (E) -> Int,
  start: ((Controller<E>) -> Unit)? = null,
  private val pull: (() -> Unit)? = null,
  private val onCancel: ((String?) -> Unit)? = null,
) {
  class Controller<E> internal constructor(private val stream: ReadableStream<E>) {
    val desiredSize: Int?
      get() = stream.desiredSize

    fun enqueue(chunk: E) {
      stream.enqueue(chunk)
    }

    fun close() {
      stream.close()
    }

    fun error(error: Throwable) {
      stream.fail(error)
    }
  }

  class Reader<E> internal constructor(private val stream: ReadableStream<E>) {
    suspend fun read(): ReadResult<E> = stream.read()

    fun cancel(reason: String? = null) {
      stream.cancel(reason)
    }

    fun releaseLock() {
      stream.releaseLock()
    }
  }

  private sealed class State {
    object Readable : State()
    object Closed : State()
    class Errored(val error: Throwable) : State()
  }

  private val lock = Any()

  private var state: State = State.Readable
  private val queue = ArrayDeque<Pair<E, Int>>()
  private var queueSize = 0
  private val waiters = ArrayDeque<CompletableDeferred<ReadResult<E>>>()
  private var isLocked = false

  val controller: Controller<E> = Controller(this)

  init {
    start?.invoke(controller)
  }

  val locked: Boolean
    get() = synchronized(lock) { isLocked }

  fun getReader(): Reader<E> {
    synchronized(lock) { isLocked = true }
    return Reader(this)
  }

  private fun releaseLock() {
    synchronized(lock) { isLocked = false }
  }

  private val desiredSize: Int?
    get() = synchronized(lock) {
      when (state) {
        is State.Errored -> null
        State.Closed -> 0
        State.Readable -> highWaterMark - queueSize
      }
    }

  private fun enqueue(chunk: E) {
    val waiter = synchronized(lock) {
      if (state !== State.Readable) return
      if (waiters.isNotEmpty()) {
        waiters.removeFirst()
      } else {
        val size = sizeOf(chunk)
        queue.addLast(chunk to size)
        queueSize += size
        null
      }
    }
    waiter?.complete(ReadResult(false, chunk))
  }

  private fun close() {
    val pending = synchronized(lock) {
      if (state !== State.Readable) return
      state = State.Closed
      val pending = waiters.toList()
      waiters.clear()
      pending
    }
    for (waiter in pending) {
      waiter.complete(ReadResult(true, null))
    }
  }

  private fun fail(error: Throwable) {
    val pending = synchronized(lock) {
      if (state !== State.Readable) return
      state = State.Errored(error)
      queue.clear()
      queueSize = 0
      val pending = waiters.toList()
      waiters.clear()
      pending
    }
    for (waiter in pending) {
      waiter.completeExceptionally(error)
    }
  }

  private fun cancel(reason: String?) {
    val pending = synchronized(lock) {
      if (state !== State.Readable) return
      state = State.Closed
      queue.clear()
      queueSize = 0
      val pending = waiters.toList()
      waiters.clear()
      pending
    }
    for (waiter in pending) {
      waiter.complete(ReadResult(true, null))
    }
    onCancel?.invoke(reason)
  }

  private fun takeImmediate(): ReadResult<E>? {
    val current = state
    if (current is State.Errored) throw current.error

    if (queue.isNotEmpty()) {
      val entry = queue.removeFirst()
      queueSize -= entry.second
      return ReadResult(false, entry.first)
    }

    if (current === State.Closed) return ReadResult(true, null)

    return null
  }

  @OptIn(ExperimentalCoroutinesApi::class)
  private suspend fun read(): ReadResult<E> {
    val immediate = synchronized(lock) { takeImmediate() }

    if (immediate != null) {
      pull?.invoke()
      return immediate
    }

    pull?.invoke()

    val waiter = synchronized(lock) {
      takeImmediate()?.let { return it }
      CompletableDeferred<ReadResult<E>>().also { waiters.addLast(it) }
    }

    try {
      return waiter.await()
    } catch (e: Throwable) {
      synchronized(lock) {
        if (!waiters.remove(waiter) && waiter.isCompleted && !waiter.isCancelled) {
          val result = runCatching { waiter.getCompleted() }.getOrNull()
          val value = result?.value
          if (result != null && !result.done && value != null) {
            val size = sizeOf(value)
            queue.addFirst(value to size)
            queueSize += size
          }
        }
      }
      throw e
    }
  }
}
