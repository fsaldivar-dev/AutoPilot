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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.QrCodeScanner
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
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import java.nio.ByteBuffer

/**
 * QR Scan tab — uses ML Kit Barcode Scanner on captured image.
 *
 * Flow: CameraX captures photo (intercepted by our mock) →
 *       decode JPEG → create InputImage → ML Kit scans →
 *       display decoded QR text.
 *
 * This proves our mock bytes are valid enough for ML Kit to process.
 */
@Composable
fun QrScanTab() {
    var statusText by remember { mutableStateOf("Listo para escanear QR") }
    var qrResult by remember { mutableStateOf<String?>(null) }
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    val context = LocalContext.current
    val scanner = remember { BarcodeScanning.getClient() }

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
                        Log.e("QrScan", "Camera bind failed", e)
                    }
                }, ContextCompat.getMainExecutor(ctx))
                previewView
            }
        )

        // Scan button — captures photo then runs ML Kit barcode scanner
        Button(
            onClick = {
                statusText = "Capturando..."
                imageCapture?.takePicture(
                    ContextCompat.getMainExecutor(context),
                    object : ImageCapture.OnImageCapturedCallback() {
                        override fun onCaptureSuccess(image: ImageProxy) {
                            statusText = "Analizando QR..."
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
                            scanner.process(inputImage)
                                .addOnSuccessListener { barcodes ->
                                    if (barcodes.isEmpty()) {
                                        statusText = "No se detecto QR"
                                        qrResult = null
                                    } else {
                                        val first = barcodes.first()
                                        val value = first.rawValue ?: "(sin valor)"
                                        val format = when (first.format) {
                                            Barcode.FORMAT_QR_CODE -> "QR"
                                            Barcode.FORMAT_EAN_13 -> "EAN-13"
                                            Barcode.FORMAT_CODE_128 -> "Code128"
                                            else -> "Barcode"
                                        }
                                        qrResult = value
                                        statusText = "QR detectado"
                                        Log.d("QrScan", "$format detectado: $value")
                                    }
                                }
                                .addOnFailureListener { e ->
                                    statusText = "Error ML Kit: ${e.message}"
                                    Log.e("QrScan", "Barcode scan failed", e)
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
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF9C27B0)),
            enabled = imageCapture != null
        ) {
            Icon(Icons.Default.QrCodeScanner, contentDescription = null, modifier = Modifier.size(24.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Escanear QR", fontWeight = FontWeight.Bold)
        }

        // Result display
        qrResult?.let { result ->
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = Color(0xFFE8F5E9))
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("QR detectado:", fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.titleSmall)
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(result, style = MaterialTheme.typography.bodyLarge,
                        color = Color(0xFF2E7D32))
                }
            }
        }
    }
}
