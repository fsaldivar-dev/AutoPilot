package dev.autopilot.cameramock

import android.app.Activity
import android.app.Application
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Entry point called by the native JVMTI agent.
 * Installs all camera hooks:
 *
 * 1. Preview overlay — ImageView on top of the camera preview (visual)
 * 2. IntentInterceptor — intercepts ACTION_IMAGE_CAPTURE results
 * 3. Camera2Interceptor — intercepts Camera2/CameraX ImageReader output
 * 4. Camera1Interceptor — intercepts legacy Camera API callbacks
 *
 * Together these cover both the preview (what the user sees) and the
 * capture output (the bytes the app receives when taking a photo).
 */
object CameraHooks {
    private const val TAG = "AutoPilotCamera"
    private val handler = Handler(Looper.getMainLooper())
    @Volatile private var installed = false

    @JvmStatic
    fun install(imagePath: String) {
        if (installed) return
        installed = true
        Log.d(TAG, "Installing camera hooks, image: $imagePath")

        // Start watching the image file for hot-swap
        ImageWatcher.start(imagePath)

        val app = getApplication()
        if (app == null) {
            Log.e(TAG, "Failed to get Application")
            return
        }

        // Install capture interceptors (output bytes)
        IntentInterceptor.install(app)
        Camera2Interceptor.install()
        Camera1Interceptor.install()
        Log.d(TAG, "Capture interceptors installed")

        // Monitor activity lifecycle to find camera preview views (visual overlay)
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                // Delay scan to let camera preview initialize
                handler.postDelayed({ scanAndHook(activity) }, 1000)
                handler.postDelayed({ scanAndHook(activity) }, 2000)
                handler.postDelayed({ scanAndHook(activity) }, 3000)
            }

            override fun onActivityPaused(activity: Activity) {
                PreviewRenderer.removeOverlay()
            }

            override fun onActivityCreated(a: Activity, b: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, b: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })

        // Also scan immediately if an activity is already visible
        handler.postDelayed({
            val currentActivity = getCurrentActivity()
            if (currentActivity != null) {
                scanAndHook(currentActivity)
            }
        }, 500)

        Log.d(TAG, "Lifecycle observer registered, waiting for camera views")
    }

    private fun scanAndHook(activity: Activity) {
        if (PreviewRenderer.isActive()) return

        val decorView = activity.window?.decorView ?: return
        val views = ViewScanner.findPreviewViews(decorView)

        if (views.isEmpty()) {
            Log.d(TAG, "No camera preview views found yet")
            return
        }

        // Attach overlay to the first preview view found
        val previewView = views.first()
        Log.d(TAG, "Attaching overlay to: ${previewView.javaClass.simpleName}[${previewView.width}x${previewView.height}]")
        PreviewRenderer.attachToPreview(previewView)
    }

    private fun getApplication(): Application? {
        return try {
            val atClass = Class.forName("android.app.ActivityThread")
            val currentApp = atClass.getMethod("currentApplication").invoke(null)
            currentApp as? Application
        } catch (e: Exception) {
            Log.e(TAG, "currentApplication() failed", e)
            null
        }
    }

    private fun getCurrentActivity(): Activity? {
        return try {
            val atClass = Class.forName("android.app.ActivityThread")
            val at = atClass.getMethod("currentActivityThread").invoke(null) ?: return null
            val activitiesField = atClass.getDeclaredField("mActivities")
            activitiesField.isAccessible = true
            @Suppress("UNCHECKED_CAST")
            val activities = activitiesField.get(at) as? android.util.ArrayMap<*, *> ?: return null
            for (record in activities.values) {
                if (record == null) continue
                val pausedField = record.javaClass.getDeclaredField("paused")
                pausedField.isAccessible = true
                if (!pausedField.getBoolean(record)) {
                    val activityField = record.javaClass.getDeclaredField("activity")
                    activityField.isAccessible = true
                    return activityField.get(record) as? Activity
                }
            }
            null
        } catch (e: Exception) {
            Log.w(TAG, "getCurrentActivity failed: ${e.message}")
            null
        }
    }
}
