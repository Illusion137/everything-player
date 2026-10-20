package com.margelo.nitro.everythingplayer.engine

import android.content.Context
import android.graphics.SurfaceTexture
import android.graphics.drawable.Drawable
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface
import android.view.TextureView
import java.nio.Buffer
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.CountDownLatch

object EPVideoHub {
  private class Output(val view: EPVideoSurfaceView, val eglSurface: EGLSurface, var width: Int, var height: Int)

  private val thread = HandlerThread("everythingplayer-video").apply { start() }
  private val handler = Handler(thread.looper)
  private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
  private var context: EGLContext = EGL14.EGL_NO_CONTEXT
  private var config: EGLConfig? = null
  private var pbuffer: EGLSurface = EGL14.EGL_NO_SURFACE
  private var program = 0
  private var texture = 0
  private var surfaceTexture: SurfaceTexture? = null
  private var hasFrame = false
  private val outputs = mutableListOf<Output>()
  private val transform = FloatArray(16)
  private var videoWidth = 0
  private var videoHeight = 0

  @Volatile
  private var input: Surface? = null

  private val quad: FloatBuffer = ByteBuffer.allocateDirect(16 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply {
    put(floatArrayOf(-1f, -1f, 0f, 0f, 1f, -1f, 1f, 0f, -1f, 1f, 0f, 1f, 1f, 1f, 1f, 1f))
    (this as Buffer).position(0)
  }

  private const val VERTEX = """
    attribute vec4 aPos;
    attribute vec4 aTex;
    uniform mat4 uTex;
    varying vec2 vTex;
    void main() {
      gl_Position = vec4(aPos.xy, 0.0, 1.0);
      vTex = (uTex * vec4(aTex.xy, 0.0, 1.0)).xy;
    }
  """

  private const val FRAGMENT = """
    #extension GL_OES_EGL_image_external : require
    precision mediump float;
    varying vec2 vTex;
    uniform samplerExternalOES sTex;
    void main() { gl_FragColor = texture2D(sTex, vTex); }
  """

  val inputSurface: Surface
    get() {
      input?.let { return it }
      runSync { setupIfNeeded() }
      return input!!
    }

  private fun runSync(block: () -> Unit) {
    if (Thread.currentThread() == thread) {
      block()
      return
    }
    val latch = CountDownLatch(1)
    handler.post {
      try { block() } finally { latch.countDown() }
    }
    latch.await()
  }

  private fun setupIfNeeded() {
    if (input != null) return
    display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
    val version = IntArray(2)
    EGL14.eglInitialize(display, version, 0, version, 1)
    val attribs = intArrayOf(
      EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
      EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
      EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
      EGL14.EGL_NONE,
    )
    val configs = arrayOfNulls<EGLConfig>(1)
    val count = IntArray(1)
    EGL14.eglChooseConfig(display, attribs, 0, configs, 0, 1, count, 0)
    config = configs[0]
    context = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
    pbuffer = EGL14.eglCreatePbufferSurface(display, config, intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
    EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)

    program = buildProgram()
    val tex = IntArray(1)
    GLES20.glGenTextures(1, tex, 0)
    texture = tex[0]
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
    GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

    val st = SurfaceTexture(texture)
    st.setOnFrameAvailableListener({ onFrame() }, handler)
    surfaceTexture = st
    input = Surface(st)
  }

  private fun buildProgram(): Int {
    fun compile(type: Int, src: String): Int {
      val shader = GLES20.glCreateShader(type)
      GLES20.glShaderSource(shader, src)
      GLES20.glCompileShader(shader)
      return shader
    }
    val p = GLES20.glCreateProgram()
    GLES20.glAttachShader(p, compile(GLES20.GL_VERTEX_SHADER, VERTEX))
    GLES20.glAttachShader(p, compile(GLES20.GL_FRAGMENT_SHADER, FRAGMENT))
    GLES20.glLinkProgram(p)
    return p
  }

  fun setVideoSize(width: Int, height: Int) {
    handler.post {
      videoWidth = width
      videoHeight = height
      drawAll()
    }
  }

  fun clear() {
    handler.post {
      hasFrame = false
      outputs.forEach { clearOutput(it) }
    }
  }

  private var dbgFrames = 0
  private var dbgDraws = 0
  private var dbgDrawNs = 0L
  private var dbgSince = System.nanoTime()

  private fun onFrame() {
    val st = surfaceTexture ?: return
    dbgFrames++
    val now = System.nanoTime()
    if (now - dbgSince > 1_000_000_000L) {
      android.util.Log.d("EPDBG", "video frames=$dbgFrames draws=$dbgDraws avgDrawMs=${if (dbgDraws > 0) dbgDrawNs / dbgDraws / 1_000_000.0 else 0.0} outputs=${outputs.size} shown=${outputs.count { it.view.isShown }}")
      dbgFrames = 0; dbgDraws = 0; dbgDrawNs = 0; dbgSince = now
    }
    EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
    st.updateTexImage()
    st.getTransformMatrix(transform)
    hasFrame = true
    drawAll()
  }

  private fun drawAll() {
    if (!hasFrame) return
    outputs.forEach { if (it.view.isShown) draw(it) }
  }

  private fun clearOutput(out: Output) {
    if (!EGL14.eglMakeCurrent(display, out.eglSurface, out.eglSurface, context)) return
    GLES20.glViewport(0, 0, out.width, out.height)
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
    EGL14.eglSwapBuffers(display, out.eglSurface)
  }

  private fun draw(out: Output) {
    val t0 = System.nanoTime()
    try { drawImpl(out) } finally { dbgDraws++; dbgDrawNs += System.nanoTime() - t0 }
  }

  private fun drawImpl(out: Output) {
    if (!EGL14.eglMakeCurrent(display, out.eglSurface, out.eglSurface, context)) return
    GLES20.glViewport(0, 0, out.width, out.height)
    GLES20.glClearColor(0f, 0f, 0f, 1f)
    GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

    var vw = out.width
    var vh = out.height
    var vx = 0
    var vy = 0
    if (videoWidth > 0 && videoHeight > 0 && out.view.resizeMode != "stretch") {
      val videoAspect = videoWidth.toFloat() / videoHeight
      val viewAspect = out.width.toFloat() / out.height
      val fitHeight = if (out.view.resizeMode == "cover") videoAspect > viewAspect else videoAspect < viewAspect
      if (fitHeight) {
        vh = out.height
        vw = (out.height * videoAspect).toInt()
      } else {
        vw = out.width
        vh = (out.width / videoAspect).toInt()
      }
      vx = (out.width - vw) / 2
      vy = (out.height - vh) / 2
    }
    GLES20.glViewport(vx, vy, vw, vh)

    GLES20.glUseProgram(program)
    val aPos = GLES20.glGetAttribLocation(program, "aPos")
    val aTex = GLES20.glGetAttribLocation(program, "aTex")
    (quad as Buffer).position(0)
    GLES20.glVertexAttribPointer(aPos, 2, GLES20.GL_FLOAT, false, 16, quad)
    GLES20.glEnableVertexAttribArray(aPos)
    (quad as Buffer).position(2)
    GLES20.glVertexAttribPointer(aTex, 2, GLES20.GL_FLOAT, false, 16, quad)
    GLES20.glEnableVertexAttribArray(aTex)
    GLES20.glUniformMatrix4fv(GLES20.glGetUniformLocation(program, "uTex"), 1, false, transform, 0)
    GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
    GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, texture)
    GLES20.glUniform1i(GLES20.glGetUniformLocation(program, "sTex"), 0)
    GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)
    EGL14.eglSwapBuffers(display, out.eglSurface)
  }

  fun addOutput(view: EPVideoSurfaceView, target: SurfaceTexture, width: Int, height: Int) {
    runSync {
      setupIfNeeded()
      val surface = EGL14.eglCreateWindowSurface(display, config, Surface(target), intArrayOf(EGL14.EGL_NONE), 0)
      val out = Output(view, surface, width, height)
      outputs.add(out)
      if (hasFrame) draw(out) else clearOutput(out)
    }
  }

  fun resizeOutput(view: EPVideoSurfaceView, width: Int, height: Int) {
    handler.post {
      outputs.firstOrNull { it.view === view }?.let {
        it.width = width
        it.height = height
        if (hasFrame) draw(it)
      }
    }
  }

  fun redraw(view: EPVideoSurfaceView) {
    handler.post { outputs.firstOrNull { it.view === view }?.let { if (hasFrame) draw(it) } }
  }

  fun removeOutput(view: EPVideoSurfaceView) {
    runSync {
      val out = outputs.firstOrNull { it.view === view } ?: return@runSync
      outputs.remove(out)
      EGL14.eglMakeCurrent(display, pbuffer, pbuffer, context)
      EGL14.eglDestroySurface(display, out.eglSurface)
    }
  }
}

class EPVideoSurfaceView(context: Context) : TextureView(context), TextureView.SurfaceTextureListener {
  var resizeMode: String = "contain"
    set(value) {
      field = value
      EPVideoHub.redraw(this)
    }

  init {
    surfaceTextureListener = this
    isOpaque = true
  }

  @Deprecated("TextureView cannot display a background drawable")
  override fun setBackgroundDrawable(background: Drawable?) {}

  override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int) {
    EPVideoHub.addOutput(this, surface, width, height)
  }

  override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) {
    EPVideoHub.resizeOutput(this, width, height)
  }

  override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean {
    EPVideoHub.removeOutput(this)
    return true
  }

  override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
}
