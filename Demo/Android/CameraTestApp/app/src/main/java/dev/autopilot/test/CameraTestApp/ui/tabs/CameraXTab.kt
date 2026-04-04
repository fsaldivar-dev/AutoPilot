package dev.autopilot.test.CameraTestApp.ui.tabs

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Camera
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

@Composable
fun CameraXTab() {
    var statusText by remember { mutableStateOf("Camara lista") }
    var capturedBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var capturedSize by remember { mutableIntStateOf(0) }
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    val context = LocalContext.current

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(statusText, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)

        CameraPreviewView(
            modifier = Modifier.fillMaxWidth().height(280.dp).clip(RoundedCornerShape(16.dp)),
            onImageCaptureReady = { imageCapture = it }
        )

        capturedBitmap?.let { bmp ->
            Image(bitmap = bmp.asImageBitmap(), contentDescription = "Foto capturada",
                modifier = Modifier.fillMaxWidth().height(80.dp).clip(RoundedCornerShape(8.dp)))
        }

        Button(
            onClick = {
                imageCapture?.takePicture(
                    ContextCompat.getMainExecutor(context),
                    object : ImageCapture.OnImageCapturedCallback() {
                        override fun onCaptureSuccess(image: ImageProxy) {
                            val buffer: ByteBuffer = image.planes[0].buffer
                            val bytes = ByteArray(buffer.remaining())
                            buffer.get(bytes)
                            val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            val stream = ByteArrayOutputStream()
                            bmp.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                            capturedBitmap = bmp
                            capturedSize = stream.size()
                            statusText = "Foto capturada"
                            Log.d("CameraTest", "Foto capturada (${stream.size()} bytes)")
                            image.close()
                        }
                        override fun onError(exception: ImageCaptureException) {
                            statusText = "Error: ${exception.message}"
                        }
                    }
                )
            },
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF007AFF)),
            enabled = imageCapture != null
        ) {
            Icon(Icons.Default.Camera, contentDescription = null, modifier = Modifier.size(24.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Capturar Foto", fontWeight = FontWeight.Bold)
        }

        if (capturedSize > 0) {
            Text("Foto capturada ($capturedSize bytes)",
                style = MaterialTheme.typography.bodySmall, color = Color(0xFF4CAF50))
        }
    }
}

@Composable
fun CameraPreviewView(
    modifier: Modifier = Modifier,
    cameraSelector: CameraSelector = CameraSelector.DEFAULT_BACK_CAMERA,
    onImageCaptureReady: (ImageCapture) -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    AndroidView(modifier = modifier, factory = { ctx ->
        val previewView = PreviewView(ctx)
        val cameraProviderFuture = ProcessCameraProvider.getInstance(ctx)
        cameraProviderFuture.addListener({
            val cameraProvider = cameraProviderFuture.get()
            val preview = Preview.Builder().build().also {
                it.surfaceProvider = previewView.surfaceProvider
            }
            val capture = ImageCapture.Builder()
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .build()
            try {
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(lifecycleOwner, cameraSelector, preview, capture)
                onImageCaptureReady(capture)
            } catch (e: Exception) {
                Log.e("CameraTest", "Camera bind failed", e)
            }
        }, ContextCompat.getMainExecutor(ctx))
        previewView
    })
}
