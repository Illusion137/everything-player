package com.margelo.nitro.everythingplayer.googlevideo.utils

class EventName<P>(val name: String)

class EventListenerToken

open class EventEmitterLike {
  private val lock = Any()
  private val listeners = HashMap<String, MutableList<Pair<EventListenerToken, (Any?) -> Unit>>>()

  fun <P> emit(type: EventName<P>, payload: P) {
    val snapshot = synchronized(lock) { listeners[type.name]?.toList() ?: emptyList() }
    for (entry in snapshot) {
      entry.second(payload)
    }
  }

  fun emit(type: EventName<Unit>) {
    emit(type, Unit)
  }

  @Suppress("UNCHECKED_CAST")
  fun <P> on(type: EventName<P>, listener: (P) -> Unit): EventListenerToken {
    val token = EventListenerToken()
    synchronized(lock) {
      listeners.getOrPut(type.name) { mutableListOf() }.add(token to { payload -> listener(payload as P) })
    }
    return token
  }

  @Suppress("UNCHECKED_CAST")
  fun <P> once(type: EventName<P>, listener: (P) -> Unit): EventListenerToken {
    val token = EventListenerToken()
    synchronized(lock) {
      listeners.getOrPut(type.name) { mutableListOf() }.add(
        token to { payload ->
          off(type, token)
          listener(payload as P)
        },
      )
    }
    return token
  }

  fun <P> off(type: EventName<P>, token: EventListenerToken) {
    synchronized(lock) {
      val entries = listeners[type.name] ?: return
      entries.removeAll { it.first === token }
      if (entries.isEmpty()) listeners.remove(type.name)
    }
  }

  fun removeAllListeners(type: EventName<*>? = null) {
    synchronized(lock) {
      if (type == null) {
        listeners.clear()
        return
      }
      listeners.remove(type.name)
    }
  }
}
