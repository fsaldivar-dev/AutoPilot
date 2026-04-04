package dev.autopilot.cameramock

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy

/**
 * Intercepts the deprecated android.hardware.Camera API (Camera1).
 *
 * Strategy:
 * 1. On each onActivityResumed, scan Activity fields for Camera instances.
 * 2. For each Camera found, start a polling thread that monitors mJpegCallback.
 * 3. When mJpegCallback transitions from null → non-null (app called takePicture),
 *    replace it with a proxy that injects mock JPEG bytes.
 *
 * All access is via reflection since Camera1 is deprecated.
 * Uses java.lang.reflect.Proxy since Camera.PictureCallback is an interface.
 */
object Camera1Interceptor {
    private const val TAG = "AutoPilotCamera"

    // Track which Camera instances we've hooked (by identity hash)
    private val hookedCameras = mutableSetOf<Int>()

    // Camera class reference (loaded lazily)
    private var cameraClass: Class<*>? = null

    fun install() {
        try {
            cameraClass = Class.forName("android.hardware.Camera")
            Log.d(TAG, "Camera1Interceptor: Camera1 API available, ready to hook")
        } catch (_: ClassNotFoundException) {
            Log.d(TAG, "Camera1Interceptor: Camera1 API not found, skipping")
        } catch (e: Exception) {
            Log.e(TAG, "Camera1Interceptor install failed", e)
        }
    }

    /**
     * Called from CameraHooks when an activity resumes.
     * Scans the activity's fields for Camera instances and hooks them.
     */
    fun onActivityResumed(activity: Activity) {
        val camClass = cameraClass ?: return

        val cameras = findCameraInstances(activity, camClass)
        for (camera in cameras) {
            val id = System.identityHashCode(camera)
            if (hookedCameras.contains(id)) continue
            hookedCameras.add(id)
            hookCamera(camera, camClass)
            Log.d(TAG, "Camera1Interceptor: hooked Camera instance #$id")
        }
    }

    /**
     * Hook a Camera instance by polling its mJpegCallback field.
     * When takePicture() is called, mJpegCallback is set; we replace it
     * with our proxy before the hardware delivers the image (~100-500ms window).
     */
    private fun hookCamera(camera: Any, camClass: Class<*>) {
        val callbackField = findCallbackField(camClass) ?: run {
            Log.w(TAG, "Camera1Interceptor: JPEG callback field not found")
            return
        }
        callbackField.isAccessible = true

        val pictureCallbackClass = try {
            Class.forName("android.hardware.Camera\$PictureCallback")
        } catch (_: Exception) {
            Log.w(TAG, "Camera1Interceptor: PictureCallback class not found")
            return
        }

        Thread {
            var lastWrappedId: Int? = null
            while (true) {
                try {
                    Thread.sleep(50)
                    val callback = callbackField.get(camera) ?: continue
                    val callbackId = System.identityHashCode(callback)

                    if (callbackId == lastWrappedId) continue
                    if (Proxy.isProxyClass(callback.javaClass)) continue

                    val wrapper = createPictureCallbackProxy(callback, pictureCallbackClass)
                    callbackField.set(camera, wrapper)
                    lastWrappedId = System.identityHashCode(wrapper)
                    Log.d(TAG, "Camera1Interceptor: wrapped JPEG callback")
                } catch (_: IllegalAccessException) {
                    Log.d(TAG, "Camera1Interceptor: Camera released, stopping poll")
                    break
                } catch (_: InterruptedException) {
                    break
                } catch (e: Exception) {
                    if (e.message?.contains("released") == true ||
                        e.message?.contains("dead") == true) break
                }
            }
            hookedCameras.remove(System.identityHashCode(camera))
        }.apply {
            isDaemon = true
            name = "autopilot-camera1-poll-${System.identityHashCode(camera)}"
        }.start()
    }

    /**
     * Find the JPEG callback field on Camera class hierarchy.
     * Tries known field names, then falls back to finding any PictureCallback
     * field with "jpeg" in its name.
     */
    private fun findCallbackField(camClass: Class<*>): java.lang.reflect.Field? {
        val knownNames = arrayOf("mJpegCallback", "mJpegPictureCallback")

        var c: Class<*>? = camClass
        while (c != null && c != Any::class.java) {
            for (name in knownNames) {
                try { return c.getDeclaredField(name) } catch (_: NoSuchFieldException) {}
            }

            // Fallback: any field of type PictureCallback with "jpeg" in name
            try {
                val pcClass = Class.forName("android.hardware.Camera\$PictureCallback")
                for (field in c.declaredFields) {
                    if (pcClass.isAssignableFrom(field.type) &&
                        field.name.lowercase().contains("jpeg")) {
                        return field
                    }
                }
            } catch (_: Exception) {}

            c = c.superclass
        }
        return null
    }

    /**
     * Create a proxy PictureCallback that replaces the byte[] data with mock JPEG.
     */
    private fun createPictureCallbackProxy(
        originalCallback: Any,
        callbackInterface: Class<*>
    ): Any {
        return Proxy.newProxyInstance(
            callbackInterface.classLoader,
            arrayOf(callbackInterface),
            InvocationHandler { _, method, args ->
                if (method.name == "onPictureTaken" && args != null && args.size >= 2) {
                    val mockJpeg = ImageWatcher.currentJpegBytes
                    if (mockJpeg != null) {
                        args[0] = mockJpeg
                        Log.d(TAG, "Camera1Interceptor: injected ${mockJpeg.size} JPEG bytes")
                    }
                }
                method.invoke(originalCallback, *(args ?: emptyArray()))
            }
        )
    }

    /**
     * Find Camera instances in an Activity's field hierarchy (max 3 levels deep).
     */
    private fun findCameraInstances(activity: Activity, cameraClass: Class<*>): List<Any> {
        val results = mutableListOf<Any>()
        val visited = mutableSetOf<Int>()
        scanForType(activity, cameraClass, 3, results, visited)
        return results
    }

    private fun scanForType(
        obj: Any, targetClass: Class<*>, maxDepth: Int,
        results: MutableList<Any>, visited: MutableSet<Int>
    ) {
        if (maxDepth <= 0 || visited.size > 500) return
        val id = System.identityHashCode(obj)
        if (visited.contains(id)) return
        visited.add(id)

        if (targetClass.isInstance(obj)) {
            results.add(obj)
            return
        }

        try {
            var clazz: Class<*>? = obj.javaClass
            while (clazz != null && clazz != Any::class.java) {
                for (field in clazz.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    try {
                        field.isAccessible = true
                        val value = field.get(obj) ?: continue
                        if (!field.type.isPrimitive && !field.type.isEnum) {
                            val tn = value.javaClass.name
                            // Skip UI/framework types — Camera won't be inside a View
                            if (tn.startsWith("java.lang.")) continue
                            if (tn.startsWith("android.view.")) continue
                            if (tn.startsWith("android.widget.")) continue
                            if (tn.startsWith("androidx.compose.")) continue
                            scanForType(value, targetClass, maxDepth - 1, results, visited)
                        }
                    } catch (_: Exception) {}
                }
                clazz = clazz.superclass
            }
        } catch (_: Exception) {}
    }

    /**
     * Convert the current mock bitmap to NV21 (YUV) format for PreviewCallback.
     * Kept for potential future use with preview interception.
     */
    @Suppress("unused")
    private fun bitmapToNv21(width: Int, height: Int): ByteArray? {
        val bitmap = ImageWatcher.currentBitmap ?: return null
        val scaled = Bitmap.createScaledBitmap(bitmap, width, height, true)

        val argb = IntArray(width * height)
        scaled.getPixels(argb, 0, width, 0, 0, width, height)

        val yuv = ByteArray(width * height * 3 / 2)
        encodeYuv420sp(yuv, argb, width, height)
        return yuv
    }

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
