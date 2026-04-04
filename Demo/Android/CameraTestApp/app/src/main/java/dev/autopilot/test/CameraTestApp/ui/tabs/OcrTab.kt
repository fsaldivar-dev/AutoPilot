package dev.autopilot.test.CameraTestApp.ui.tabs

import android.graphics.BitmapFactory
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.nio.ByteBuffer

/**
 * OCR tab — uses ML Kit Text Recognition on captured image.
 *
 * Flow: CameraX captures photo (intercepted by our mock) →
 *       decode JPEG → create InputImage → ML Kit recognizes text →
 *       display recognized text with block/line structure.
 *
 * This proves our mock bytes contain processable text for OCR engines.
 */
@Composable
fun OcrTab() {
    var statusText by remember { mutableStateOf("Listo para OCR") }
    var ocrResult by remember { mutableStateOf<String?>(null) }
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    val context = LocalContext.current
    val recognizer = remember { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(statusText, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)

        // Camera preview
        val lifecycleOwner = LocalLifecycleOwner.current
        AndroidView(
            modifier = Modifier.fillMaxWidth().height(280.dp).clip(RoundedCornerShape(16.dp)),
            factory = { ctx ->
                val previewView = PreviewView(ctx)
                val future = ProcessCameraProvider.getInstance(ctx)
                future.addListener({
                    val provider = future.get()
                    val preview = Preview.Builder().build().also {
                        it.surfaceProvider = previewView.surfaceProvider
                    }
                    val capture = ImageCapture.Builder()
                        .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                        .build()
                    try {
                        provider.unbindAll()
                        provider.bindToLifecycle(lifecycleOwner, CameraSelector.DEFAULT_BACK_CAMERA, preview, capture)
                        imageCapture = capture
                    } catch (e: Exception) {
                        Log.e("OcrTab", "Camera bind failed", e)
                    }
                }, ContextCompat.getMainExecutor(ctx))
                previewView
            }
        )

        // OCR button — captures photo then runs ML Kit text recognition
        Button(
            onClick = {
                statusText = "Capturando..."
                imageCapture?.takePicture(
                    ContextCompat.getMainExecutor(context),
                    object : ImageCapture.OnImageCapturedCallback() {
                        override fun onCaptureSuccess(image: ImageProxy) {
                            statusText = "Reconociendo texto..."
                            val buffer: ByteBuffer = image.planes[0].buffer
                            val bytes = ByteArray(buffer.remaining())
                            buffer.get(bytes)
                            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                            image.close()

                            if (bitmap == null) {
                                statusText = "Error: no se pudo decodificar imagen"
                                return
                            }

                            val inputImage = InputImage.fromBitmap(bitmap, 0)
                            recognizer.process(inputImage)
                                .addOnSuccessListener { text ->
                                    if (text.text.isEmpty()) {
                                        statusText = "No se detecto texto"
                                        ocrResult = null
                                    } else {
                                        ocrResult = text.text
                                        statusText = "Texto detectado (${text.textBlocks.size} bloques)"
                                        Log.d("OcrTab", "OCR: ${text.text}")
                                    }
                                }
                                .addOnFailureListener { e ->
                                    statusText = "Error ML Kit: ${e.message}"
                                    Log.e("OcrTab", "Text recognition failed", e)
                                }
                        }
                        override fun onError(exception: ImageCaptureException) {
                            statusText = "Error captura: ${exception.message}"
                        }
                    }
                )
            },
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF5722)),
            enabled = imageCapture != null
        ) {
            Icon(Icons.Default.TextFields, contentDescription = null, modifier = Modifier.size(24.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Reconocer Texto", fontWeight = FontWeight.Bold)
        }

        // Result display
        ocrResult?.let { result ->
            Card(
                modifier = Modifier.fillMaxWidth().weight(1f),
                colors = CardDefaults.cardColors(containerColor = Color(0xFFFFF3E0))
            ) {
                Column(
                    modifier = Modifier.padding(16.dp).verticalScroll(rememberScrollState())
                ) {
                    Text("Texto detectado:", fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.titleSmall)
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(result, style = MaterialTheme.typography.bodyMedium,
                        color = Color(0xFFE65100))
                }
            }
        }
    }
}
