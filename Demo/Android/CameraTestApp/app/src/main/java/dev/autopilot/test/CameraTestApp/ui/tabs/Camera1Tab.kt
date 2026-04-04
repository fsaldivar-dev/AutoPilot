@file:Suppress("DEPRECATION")
package dev.autopilot.test.CameraTestApp.ui.tabs

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.hardware.Camera
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import java.io.ByteArrayOutputStream

/**
 * Camera1 Legacy tab — uses deprecated android.hardware.Camera API.
 *
 * Flow: open Camera → set preview display (SurfaceView) →
 *       startPreview → takePicture(PictureCallback) →
 *       Camera1Interceptor (if loaded) replaces JPEG bytes.
 *
 * This tests the oldest camera API path that some banking/gov apps still use.
 */
@Composable
fun Camera1Tab() {
    var statusText by remember { mutableStateOf("Listo para Camera1 (legacy)") }
    var capturedBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var capturedSize by remember { mutableIntStateOf(0) }
    var camera by remember { mutableStateOf<Camera?>(null) }
    var previewing by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        onDispose {
            try {
                camera?.stopPreview()
                camera?.release()
            } catch (_: Exception) {}
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(statusText, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)

        // SurfaceView for Camera1 preview
        AndroidView(
            modifier = Modifier.fillMaxWidth().height(280.dp).clip(RoundedCornerShape(16.dp)),
            factory = { ctx ->
                val surfaceView = SurfaceView(ctx)
                surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) {
                        try {
                            val cam = Camera.open()
                            cam.setDisplayOrientation(90)
                            cam.setPreviewDisplay(holder)
                            cam.startPreview()
                            camera = cam
                            previewing = true
                            statusText = "Camera1 preview activo"
                            Log.d("Camera1Tab", "Camera1 opened and previewing")
                        } catch (e: Exception) {
                            statusText = "Error abriendo Camera1: ${e.message}"
                            Log.e("Camera1Tab", "Camera.open() failed", e)
                        }
                    }
                    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {}
                    override fun surfaceDestroyed(holder: SurfaceHolder) {
                        try {
                            camera?.stopPreview()
                            camera?.release()
                            camera = null
                            previewing = false
                        } catch (_: Exception) {}
                    }
                })
                surfaceView
            }
        )

        // Captured image
        capturedBitmap?.let { bmp ->
            Image(bitmap = bmp.asImageBitmap(), contentDescription = "Camera1 foto",
                modifier = Modifier.fillMaxWidth().height(80.dp).clip(RoundedCornerShape(8.dp)))
        }

        // Capture button — calls takePicture on legacy Camera
        Button(
            onClick = {
                statusText = "Capturando con Camera1..."
                camera?.takePicture(null, null) { data, cam ->
                    val bmp = BitmapFactory.decodeByteArray(data, 0, data.size)
                    if (bmp != null) {
                        capturedBitmap = bmp
                        val stream = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                        capturedSize = stream.size()
                        statusText = "Camera1 capturada ($capturedSize bytes)"
                        Log.d("Camera1Tab", "Camera1 photo: ${data.size} raw, $capturedSize compressed")
                    } else {
                        statusText = "Error: no se pudo decodificar Camera1 JPEG"
                    }
                    // Restart preview after capture
                    cam.startPreview()
                }
            },
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF795548)),
            enabled = previewing
        ) {
            Icon(Icons.Default.CameraAlt, contentDescription = null, modifier = Modifier.size(24.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Capturar (Camera1)", fontWeight = FontWeight.Bold)
        }

        if (capturedSize > 0) {
            Text("Camera1 capturada ($capturedSize bytes)",
                style = MaterialTheme.typography.bodySmall, color = Color(0xFF4CAF50))
        }
    }
}
