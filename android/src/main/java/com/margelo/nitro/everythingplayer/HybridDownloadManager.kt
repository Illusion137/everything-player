package com.margelo.nitro.everythingplayer

import androidx.annotation.Keep
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.NitroModules
import com.margelo.nitro.core.Promise
import com.margelo.nitro.everythingplayer.engine.EPDownloads
import com.margelo.nitro.everythingplayer.engine.EPError
import com.margelo.nitro.everythingplayer.engine.EPErrorCode

@OptIn(UnstableApi::class)
@DoNotStrip
@Keep
class HybridDownloadManager : HybridDownloadManagerSpec() {
  private val context
    get() = NitroModules.applicationContext
      ?: throw EPError(EPErrorCode.UNKNOWN, "React context is not available yet")

  override fun download(track: NativeTrack, options: NativeDownloadOptions): Promise<NativeDownload> {
    val ctx = context
    val range = options.videoQuality?.toEngine() ?: com.margelo.nitro.everythingplayer.engine.EPPlayerEngine.getVideoQualityRange()
    return Promise.async { EPDownloads.download(ctx, track.toEngine(), options.includeVideo, range).toNative() }
  }

  override fun pause(trackId: String) = EPDownloads.pause(context, trackId)
  override fun resume(trackId: String) = EPDownloads.resume(context, trackId)
  override fun cancel(trackId: String) = EPDownloads.cancel(context, trackId)

  override fun remove(trackId: String): Promise<Unit> {
    val ctx = context
    return Promise.async { EPDownloads.remove(ctx, trackId) }
  }

  override fun removeAll(): Promise<Unit> {
    val ctx = context
    return Promise.async { EPDownloads.removeAll(ctx) }
  }

  override fun getDownload(trackId: String): NativeDownload? = EPDownloads.get(context, trackId)?.toNative()

  override fun getDownloads(): Array<NativeDownload> = EPDownloads.all(context).map { it.toNative() }.toTypedArray()

  override fun setOnDownloadChanged(callback: (download: NativeDownload) -> Unit) {
    EPDownloads.onChanged = { callback(it.toNative()) }
  }
}
