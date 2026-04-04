package dev.autopilot.cameramock

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.BitmapDrawable
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView

/**
 * Renders the mock camera image by overlaying an ImageView on top of
 * the camera preview. This works regardless of whether the preview
 * uses SurfaceView (PUSH_BUFFERS, no lockCanvas) or TextureView.
 *
 * The overlay is added as a sibling of the preview view in the layout
 * hierarchy, positioned exactly on top of it.
 */
object PreviewRenderer {
    private const val TAG = "AutoPilotCamera"
    private const val OVERLAY_TAG = "autopilot_camera_overlay"
    private val handler = Handler(Looper.getMainLooper())
    private var overlayView: View? = null
    @Volatile private var active = false

    fun attachToPreview(previewView: View) {
        handler.post {
            try {
                doAttach(previewView)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to attach overlay", e)
            }
        }
    }

    private fun doAttach(previewView: View) {
        // Remove existing overlay if any
        removeOverlay()

        // If the preview is a ViewGroup (e.g. PreviewView), add overlay as a child on top
        // This ensures it covers the preview exactly regardless of layout
        val targetParent: ViewGroup
        val useAsChild: Boolean

        if (previewView is ViewGroup) {
            targetParent = previewView
            useAsChild = true
        } else {
            val parent = previewView.parent as? ViewGroup
            if (parent == null) {
                Log.e(TAG, "Preview has no parent ViewGroup")
                return
            }
            targetParent = parent
            useAsChild = false
        }

        // Create overlay container
        val container = FrameLayout(previewView.context).apply {
            tag = OVERLAY_TAG
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
            // Ensure overlay draws on top
            elevation = 100f
        }

        // Create ImageView for mock camera image
        val imageView = ImageView(previewView.context).apply {
            scaleType = ImageView.ScaleType.CENTER_CROP
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        }
        container.addView(imageView)

        // Create "MOCK" badge
        val badge = TextView(previewView.context).apply {
            text = "AutoPilot | Mock Camera"
            setTextColor(Color.WHITE)
            textSize = 12f
            setShadowLayer(2f, 1f, 1f, Color.BLACK)
            setPadding(16, 8, 16, 8)
            setBackgroundColor(Color.argb(128, 0, 0, 0))
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                bottomMargin = 16
            }
        }
        container.addView(badge)

        if (useAsChild) {
            // Add as child of PreviewView — covers its entire area
            targetParent.addView(container)
        } else {
            // Insert overlay right after the preview view in the parent
            val previewIndex = targetParent.indexOfChild(previewView)
            container.layoutParams = previewView.layoutParams?.let {
                ViewGroup.LayoutParams(it.width, it.height)
            } ?: ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
            targetParent.addView(container, previewIndex + 1)
        }

        overlayView = container
        active = true

        // Start updating the image
        updateImage(imageView)
        Log.d(TAG, "Overlay attached on top of preview (asChild=$useAsChild)")
    }

    private fun updateImage(imageView: ImageView) {
        if (!active) return

        val bitmap = ImageWatcher.currentBitmap
        if (bitmap != null) {
            imageView.setImageBitmap(bitmap)
        }

        // Poll for image changes (hot-swap)
        handler.postDelayed({ updateImage(imageView) }, 500)
    }

    fun removeOverlay() {
        active = false
        val overlay = overlayView ?: return
        (overlay.parent as? ViewGroup)?.removeView(overlay)
        overlayView = null
    }

    fun isActive(): Boolean {
        // Check if the overlay is still in a valid view hierarchy
        if (active && overlayView?.parent == null) {
            active = false
            overlayView = null
        }
        return active
    }
}
