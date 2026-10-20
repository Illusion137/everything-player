package com.margelo.nitro.everythingplayer

import android.view.View
import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.facebook.react.uimanager.ThemedReactContext
import com.margelo.nitro.everythingplayer.engine.EPVideoSurfaceView

@DoNotStrip
@Keep
class HybridVideoSurface(context: ThemedReactContext) : HybridVideoSurfaceSpec() {
  private val surface = EPVideoSurfaceView(context)

  override val view: View = surface

  override var resizeMode: NativeResizeMode? = null
    set(value) {
      field = value
      surface.resizeMode = when (value) {
        NativeResizeMode.COVER -> "cover"
        NativeResizeMode.STRETCH -> "stretch"
        else -> "contain"
      }
    }
}
