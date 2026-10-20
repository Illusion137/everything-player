package com.margelo.nitro.everythingplayer.engine

import android.content.Intent
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.Player
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService

@OptIn(UnstableApi::class)
class EPSessionPlayer(player: Player, private val engine: EPPlayerEngine) : ForwardingPlayer(player) {
  private fun has(capability: String) = engine.updateOptions.capabilities.contains(capability)

  override fun getAvailableCommands(): Player.Commands {
    val builder = super.getAvailableCommands().buildUpon()
    fun set(command: Int, enabled: Boolean) {
      if (enabled) builder.add(command) else builder.remove(command)
    }
    set(Player.COMMAND_PLAY_PAUSE, has("play") || has("pause"))
    set(Player.COMMAND_STOP, has("stop"))
    set(Player.COMMAND_SEEK_TO_NEXT, has("skip-to-next"))
    set(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, has("skip-to-next"))
    set(Player.COMMAND_SEEK_TO_PREVIOUS, has("skip-to-previous"))
    set(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM, has("skip-to-previous"))
    set(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM, has("seek-to"))
    set(Player.COMMAND_SEEK_FORWARD, has("jump-forward"))
    set(Player.COMMAND_SEEK_BACK, has("jump-backward"))
    return builder.build()
  }

  override fun isCommandAvailable(command: Int): Boolean = availableCommands.contains(command)

  override fun getPlayWhenReady(): Boolean = engine.isPlayWhenReady()

  override fun play() = engine.handleRemote(EPRemoteEvent.Play)

  override fun pause() = engine.handleRemote(EPRemoteEvent.Pause)

  override fun setPlayWhenReady(playWhenReady: Boolean) =
    engine.handleRemote(if (playWhenReady) EPRemoteEvent.Play else EPRemoteEvent.Pause)

  override fun stop() = engine.handleRemote(EPRemoteEvent.Stop)

  override fun prepare() {}

  override fun seekToDefaultPosition() {}

  override fun hasNextMediaItem(): Boolean = has("skip-to-next")

  override fun hasPreviousMediaItem(): Boolean = has("skip-to-previous")

  override fun seekToNext() = engine.handleRemote(EPRemoteEvent.Next)

  override fun seekToNextMediaItem() = engine.handleRemote(EPRemoteEvent.Next)

  override fun seekToPrevious() = engine.handleRemote(EPRemoteEvent.Previous)

  override fun seekToPreviousMediaItem() = engine.handleRemote(EPRemoteEvent.Previous)

  override fun seekTo(positionMs: Long) = engine.handleRemote(EPRemoteEvent.Seek(positionMs / 1000.0))

  override fun seekForward() = engine.handleRemote(EPRemoteEvent.JumpForward(engine.updateOptions.forwardJumpInterval))

  override fun seekBack() = engine.handleRemote(EPRemoteEvent.JumpBackward(engine.updateOptions.backwardJumpInterval))

  override fun getSeekForwardIncrement(): Long = (engine.updateOptions.forwardJumpInterval * 1000).toLong()

  override fun getSeekBackIncrement(): Long = (engine.updateOptions.backwardJumpInterval * 1000).toLong()
}

@OptIn(UnstableApi::class)
class PlaybackService : MediaSessionService() {
  override fun onCreate() {
    super.onCreate()
    instance = this
    EPPlayerEngine.session?.let { attach(it) }
  }

  fun attach(session: MediaSession) {
    if (!isSessionAdded(session)) addSession(session)
  }

  override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = EPPlayerEngine.session

  override fun onTaskRemoved(rootIntent: Intent?) {
    EPPlayerEngine.onTaskRemoved()
    super.onTaskRemoved(rootIntent)
  }

  override fun onDestroy() {
    instance = null
    super.onDestroy()
  }

  companion object {
    @Volatile
    var instance: PlaybackService? = null
      private set
  }
}
