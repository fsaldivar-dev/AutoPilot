package dev.autopilot.cameramock

import android.graphics.BitmapFactory
import android.graphics.Bitmap
import android.util.Log
import java.io.File

/**
 * Watches a file on disk for changes, reloading the mock camera image
 * when it's updated. Enables hot-swap: `adb push newimage.jpg /sdcard/autopilot/camera.jpg`
 * updates the preview within ~500ms without relaunching the app.
 */
object ImageWatcher {
    private const val TAG = "AutoPilotCamera"
    private const val POLL_INTERVAL_MS = 500L

    @Volatile var currentBitmap: Bitmap? = null
        private set

    /** Raw JPEG bytes of the current mock image, for capture interceptors. */
    @Volatile var currentJpegBytes: ByteArray? = null
        private set

    private var lastModified = 0L
    private var lastSize = 0L
    @Volatile private var running = false

    fun start(imagePath: String) {
        if (running) return
        running = true

        // Load initial image immediately
        loadImage(imagePath)

        // Start polling thread for hot-swap
        Thread {
            Log.d(TAG, "ImageWatcher started, watching: $imagePath")
            while (running) {
                try {
                    val file = File(imagePath)
                    if (file.exists()) {
                        val modified = file.lastModified()
                        val size = file.length()
                        if (modified != lastModified || size != lastSize) {
                            loadImage(imagePath)
                        }
                    }
                    Thread.sleep(POLL_INTERVAL_MS)
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.w(TAG, "ImageWatcher error: ${e.message}")
                    Thread.sleep(POLL_INTERVAL_MS)
                }
            }
        }.apply {
            isDaemon = true
            name = "autopilot-image-watcher"
        }.start()
    }

    fun stop() {
        running = false
    }

    private fun loadImage(path: String) {
        try {
            val file = File(path)
            if (!file.exists()) {
                Log.d(TAG, "Image not found: $path")
                return
            }

            val opts = BitmapFactory.Options().apply {
                // Limit to reasonable size for camera mock
                inSampleSize = 1
            }
            val bitmap = BitmapFactory.decodeFile(path, opts)
            if (bitmap != null) {
                currentBitmap = bitmap
                currentJpegBytes = file.readBytes()
                lastModified = file.lastModified()
                lastSize = file.length()
                Log.d(TAG, "Image loaded: ${bitmap.width}x${bitmap.height} (${file.length()} bytes)")
            } else {
                Log.w(TAG, "Failed to decode image: $path")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to load image: $path", e)
        }
    }
}
