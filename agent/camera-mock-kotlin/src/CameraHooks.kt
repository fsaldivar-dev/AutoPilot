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

        // Monitor activity lifecycle for preview overlay + Camera1 hooking
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                // Force Camera2Interceptor to fast-scan for new ImageReaders
                // (tab changes create new CameraX bindings with new ImageReaders)
                Camera2Interceptor.requestRescan()

                // Delay scan to let camera preview initialize
                handler.postDelayed({ scanAndHook(activity) }, 1000)
                handler.postDelayed({ scanAndHook(activity) }, 2000)
                handler.postDelayed({ scanAndHook(activity) }, 3000)

                // Scan for Camera1 instances in the activity's fields
                handler.postDelayed({ Camera1Interceptor.onActivityResumed(activity) }, 1500)
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

        // Periodic overlay re-scan: Compose tab changes don't trigger lifecycle events,
        // so we poll every 2s to detect when the preview view has been replaced.
        startOverlayWatchdog()

        Log.d(TAG, "Lifecycle observer registered, waiting for camera views")
    }

    /**
     * Periodically check if the overlay is still visible. Compose tab changes
     * destroy and recreate PreviewView without triggering Activity lifecycle.
     */
    private fun startOverlayWatchdog() {
        Thread {
            while (true) {
                try {
                    Thread.sleep(2_000)
                    if (!PreviewRenderer.isActive()) {
                        // Overlay lost — Compose likely switched tabs/cameras
                        Camera2Interceptor.requestRescan()
                        handler.post {
                            val activity = getCurrentActivity() ?: return@post
                            scanAndHook(activity)
                        }
                    }
                } catch (_: InterruptedException) { break }
                catch (_: Exception) {}
            }
        }.apply {
            isDaemon = true
            name = "autopilot-overlay-watchdog"
        }.start()
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
