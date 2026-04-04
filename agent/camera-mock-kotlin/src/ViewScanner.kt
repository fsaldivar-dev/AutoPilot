package dev.autopilot.cameramock

import android.util.Log
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup

/**
 * Scans the view hierarchy to find camera preview views.
 * Looks for TextureView (CameraX PreviewView), SurfaceView, and
 * CameraX's PreviewView specifically.
 *
 * Returns the Views themselves so an overlay can be placed on top.
 */
object ViewScanner {
    private const val TAG = "AutoPilotCamera"

    fun findPreviewViews(root: View): List<View> {
        val results = mutableListOf<View>()
        scanView(root, results)
        return results
    }

    private fun scanView(view: View, results: MutableList<View>) {
        val className = view.javaClass.name

        // CameraX PreviewView — return it directly (overlay goes on top of the whole thing)
        if (className == "androidx.camera.view.PreviewView") {
            Log.d(TAG, "Found PreviewView: ${view.width}x${view.height}")
            results.add(view)
            return
        }

        // TextureView used as camera preview (common in Camera2 direct usage)
        if (view is TextureView && view.surfaceTexture != null) {
            Log.d(TAG, "Found TextureView: ${view.width}x${view.height}")
            results.add(view)
            return
        }

        // SurfaceView used as camera preview
        if (view is SurfaceView) {
            val holder = view.holder
            if (holder != null && holder.surface != null && holder.surface.isValid) {
                Log.d(TAG, "Found SurfaceView: ${view.width}x${view.height}")
                results.add(view)
                return
            }
        }

        // Recurse into ViewGroups
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                scanView(view.getChildAt(i), results)
            }
        }
    }
}
