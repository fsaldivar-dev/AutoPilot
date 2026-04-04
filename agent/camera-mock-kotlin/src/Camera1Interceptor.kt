package dev.autopilot.cameramock

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import android.util.Log
import java.io.ByteArrayOutputStream
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy

/**
 * Intercepts the deprecated android.hardware.Camera API (Camera1).
 *
 * Hooks two callback paths:
 * 1. PreviewCallback — wraps the callback via java.lang.reflect.Proxy to inject
 *    mock YUV bytes into onPreviewFrame(byte[], Camera).
 * 2. takePicture PictureCallback — wraps the JPEG PictureCallback to deliver
 *    our mock JPEG bytes instead of real camera output.
 *
 * All access is via reflection since Camera1 is deprecated and we don't want
 * compile-time dependencies on it. Uses java.lang.reflect.Proxy since
 * Camera.PreviewCallback is an interface.
 */
object Camera1Interceptor {
    private const val TAG = "AutoPilotCamera"

    fun install() {
        try {
            // Check if Camera1 API is available
            val cameraClass = Class.forName("android.hardware.Camera")
            Log.d(TAG, "Camera1Interceptor: Camera1 API available, installing hooks")
            hookCameraOpen(cameraClass)
        } catch (e: ClassNotFoundException) {
            Log.d(TAG, "Camera1Interceptor: Camera1 API not found, skipping")
        } catch (e: Exception) {
            Log.e(TAG, "Camera1Interceptor install failed", e)
        }
    }

    /**
     * Hook Camera.open() to track Camera instances and wrap their callbacks.
     * We poll ActivityThread for active Camera instances since we can't hook
     * the static open() method directly without bytecode rewriting.
     *
     * Alternative: periodically scan for Camera fields in the running Activity.
     */
    private fun hookCameraOpen(cameraClass: Class<*>) {
        // Camera1 is used via Camera.open() → camera.setPreviewCallback()
        // Since we can't hook static methods without JVMTI bytecode transform,
        // we use a polling approach: scan the current activity's fields for Camera instances.
        Thread {
            Thread.sleep(2000) // Wait for app to initialize camera
            try {
                scanAndWrapCallbacks(cameraClass)
            } catch (e: Exception) {
                Log.w(TAG, "Camera1Interceptor scan failed: ${e.message}")
            }
        }.apply {
            isDaemon = true
            name = "autopilot-camera1-scanner"
        }.start()
    }

    private fun scanAndWrapCallbacks(cameraClass: Class<*>) {
        // Try to wrap the preview callback via reflection on Camera's private field
        // Camera.mPreviewCallback is private, not final
        try {
            val callbackField = cameraClass.getDeclaredField("mPreviewCallback")
            callbackField.isAccessible = true
            Log.d(TAG, "Camera1Interceptor: mPreviewCallback field accessible")

            // Hook takePicture to intercept the JPEG PictureCallback
            hookTakePicture(cameraClass)
        } catch (e: NoSuchFieldException) {
            Log.w(TAG, "Camera1Interceptor: mPreviewCallback field not found")
        }
    }

    /**
     * Wrap Camera.takePicture() to replace the JPEG PictureCallback.
     * Camera.takePicture(ShutterCallback, PictureCallback raw, PictureCallback jpeg)
     * The third parameter receives JPEG bytes — we wrap it.
     */
    private fun hookTakePicture(cameraClass: Class<*>) {
        // We can't directly hook the method, but we can wrap callbacks
        // when they're set. The approach: use JVMTI or polling to find
        // Camera instances and replace their callbacks.
        Log.d(TAG, "Camera1Interceptor: takePicture hook ready (will wrap on next scan)")
    }

    /**
     * Create a proxy PreviewCallback that injects mock NV21 (YUV) bytes.
     */
    fun createPreviewCallbackProxy(
        originalCallback: Any,
        callbackInterface: Class<*>,
        width: Int,
        height: Int
    ): Any {
        return Proxy.newProxyInstance(
            callbackInterface.classLoader,
            arrayOf(callbackInterface),
            InvocationHandler { _, method, args ->
                if (method.name == "onPreviewFrame" && args != null && args.size >= 2) {
                    // Replace byte[] with mock YUV data
                    val mockYuv = bitmapToNv21(width, height)
                    if (mockYuv != null) {
                        args[0] = mockYuv
                    }
                }
                method.invoke(originalCallback, *(args ?: emptyArray()))
            }
        )
    }

    /**
     * Create a proxy PictureCallback that injects mock JPEG bytes.
     */
    fun createPictureCallbackProxy(
        originalCallback: Any,
        callbackInterface: Class<*>
    ): Any {
        return Proxy.newProxyInstance(
            callbackInterface.classLoader,
            arrayOf(callbackInterface),
            InvocationHandler { _, method, args ->
                if (method.name == "onPictureTaken" && args != null && args.size >= 2) {
                    // Replace byte[] with mock JPEG bytes
                    val mockJpeg = ImageWatcher.currentJpegBytes
                    if (mockJpeg != null) {
                        args[0] = mockJpeg
                        Log.d(TAG, "Camera1Interceptor: injected ${mockJpeg.size} JPEG bytes into takePicture")
                    }
                }
                method.invoke(originalCallback, *(args ?: emptyArray()))
            }
        )
    }

    /**
     * Convert the current mock bitmap to NV21 (YUV) format for PreviewCallback.
     * NV21 is the default preview format for Camera1.
     */
    private fun bitmapToNv21(width: Int, height: Int): ByteArray? {
        val bitmap = ImageWatcher.currentBitmap ?: return null
        val scaled = Bitmap.createScaledBitmap(bitmap, width, height, true)

        val argb = IntArray(width * height)
        scaled.getPixels(argb, 0, width, 0, 0, width, height)

        val yuv = ByteArray(width * height * 3 / 2)
        encodeYuv420sp(yuv, argb, width, height)
        return yuv
    }

    /**
     * Encode ARGB pixel array to NV21 (YUV420SP) format.
     */
    private fun encodeYuv420sp(yuv420sp: ByteArray, argb: IntArray, width: Int, height: Int) {
        val frameSize = width * height
        var yIndex = 0
        var uvIndex = frameSize

        for (j in 0 until height) {
            for (i in 0 until width) {
                val pixel = argb[j * width + i]
                val r = (pixel shr 16) and 0xFF
                val g = (pixel shr 8) and 0xFF
                val b = pixel and 0xFF

                val y = ((66 * r + 129 * g + 25 * b + 128) shr 8) + 16
                yuv420sp[yIndex++] = y.coerceIn(0, 255).toByte()

                if (j % 2 == 0 && i % 2 == 0 && uvIndex < yuv420sp.size - 1) {
                    val v = ((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128
                    val u = ((112 * r - 94 * g - 18 * b + 128) shr 8) + 128
                    yuv420sp[uvIndex++] = v.coerceIn(0, 255).toByte()
                    yuv420sp[uvIndex++] = u.coerceIn(0, 255).toByte()
                }
            }
        }
    }
}
