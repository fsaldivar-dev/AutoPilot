package dev.autopilot.cameramock

import android.app.Activity
import android.app.Application
import android.app.Instrumentation
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.provider.MediaStore
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Intercepts ACTION_IMAGE_CAPTURE intents to deliver mock camera bytes.
 *
 * When an app uses startActivityForResult(ACTION_IMAGE_CAPTURE), Android
 * normally launches the system camera. This interceptor uses
 * Instrumentation.ActivityMonitor to block the camera Activity and return
 * a mock result containing our image bytes instead.
 *
 * Covers apps that delegate photo capture to the system camera, e.g.:
 *   - Apps using ACTION_IMAGE_CAPTURE intent
 *   - Apps using ActivityResultContracts.TakePicture()
 *   - Apps using ActivityResultContracts.TakePicturePreview()
 */
object IntentInterceptor {
    private const val TAG = "AutoPilotCamera"

    fun install(app: Application) {
        try {
            val instrumentation = getInstrumentation()
            if (instrumentation == null) {
                Log.w(TAG, "IntentInterceptor: could not get Instrumentation, skipping")
                return
            }

            // Monitor ACTION_IMAGE_CAPTURE intents — return mock result, block real camera
            val filter = IntentFilter(MediaStore.ACTION_IMAGE_CAPTURE)
            val mockResult = createMockResult()
            if (mockResult != null) {
                instrumentation.addMonitor(filter, mockResult, true)
                Log.d(TAG, "IntentInterceptor installed — blocking ACTION_IMAGE_CAPTURE")
            }

            // Also monitor video capture (ACTION_VIDEO_CAPTURE) for future use
            val videoFilter = IntentFilter(MediaStore.ACTION_VIDEO_CAPTURE)
            instrumentation.addMonitor(videoFilter, mockResult, true)

            // Register lifecycle callbacks to handle EXTRA_OUTPUT URI
            app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
                override fun onActivityResumed(activity: Activity) {
                    writeToExtraOutputIfNeeded(activity)
                }
                override fun onActivityCreated(a: Activity, b: Bundle?) {}
                override fun onActivityStarted(a: Activity) {}
                override fun onActivityPaused(a: Activity) {}
                override fun onActivityStopped(a: Activity) {}
                override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
                override fun onActivityDestroyed(a: Activity) {}
            })
        } catch (e: Exception) {
            Log.e(TAG, "IntentInterceptor install failed", e)
        }
    }

    /**
     * Create a mock ActivityResult that contains our mock bitmap.
     * The result mimics what the system camera would return:
     * - resultCode = RESULT_OK
     * - data intent with "data" extra containing a thumbnail Bitmap
     */
    private fun createMockResult(): Instrumentation.ActivityResult? {
        val jpegBytes = ImageWatcher.currentJpegBytes ?: return null
        val bitmap = BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.size) ?: return null

        // Create thumbnail (camera intent returns small thumbnail in extras)
        val thumbnail = Bitmap.createScaledBitmap(bitmap, 320, 240, true)

        val data = Intent()
        data.putExtra("data", thumbnail)

        return Instrumentation.ActivityResult(Activity.RESULT_OK, data)
    }

    /**
     * If the app specified EXTRA_OUTPUT URI in the camera intent,
     * it expects the full-resolution photo written to that URI.
     * We write our mock JPEG bytes there.
     */
    private fun writeToExtraOutputIfNeeded(activity: Activity) {
        try {
            val jpegBytes = ImageWatcher.currentJpegBytes ?: return

            // Check if the activity has a pending camera intent with EXTRA_OUTPUT
            // This is accessed via the activity's intent or stored state
            val intent = activity.intent ?: return
            val outputUri = intent.getParcelableExtra<Uri>(MediaStore.EXTRA_OUTPUT) ?: return

            activity.contentResolver.openOutputStream(outputUri)?.use { output ->
                output.write(jpegBytes)
                output.flush()
                Log.d(TAG, "IntentInterceptor: wrote ${jpegBytes.size} bytes to EXTRA_OUTPUT URI")
            }
        } catch (e: Exception) {
            // Not all activities will have EXTRA_OUTPUT — this is expected
        }
    }

    /**
     * Get the Instrumentation instance from ActivityThread via reflection.
     */
    private fun getInstrumentation(): Instrumentation? {
        return try {
            val atClass = Class.forName("android.app.ActivityThread")
            val currentThread = atClass.getMethod("currentActivityThread").invoke(null)
                ?: return null
            val instrField = atClass.getDeclaredField("mInstrumentation")
            instrField.isAccessible = true
            instrField.get(currentThread) as? Instrumentation
        } catch (e: Exception) {
            Log.e(TAG, "Failed to get Instrumentation: ${e.message}")
            null
        }
    }
}
