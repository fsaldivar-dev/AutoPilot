package dev.autopilot.test.CameraTestApp.ui.tabs

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.provider.MediaStore
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import java.io.ByteArrayOutputStream

/**
 * Intent Capture tab — uses ACTION_IMAGE_CAPTURE to launch the system camera.
 *
 * Flow: app fires intent → IntentInterceptor (if loaded) blocks system camera
 *       and returns mock thumbnail → app receives Bitmap in onActivityResult.
 *
 * This tests a completely different capture path from CameraX.
 */
@Composable
fun IntentCaptureTab() {
    var statusText by remember { mutableStateOf("Listo para captura por Intent") }
    var capturedBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var capturedSize by remember { mutableIntStateOf(0) }

    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val data = result.data
            val thumbnail = data?.extras?.get("data") as? Bitmap
            if (thumbnail != null) {
                capturedBitmap = thumbnail
                val stream = ByteArrayOutputStream()
                thumbnail.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                capturedSize = stream.size()
                statusText = "Intent capturada (${capturedSize} bytes)"
                Log.d("IntentCapture", "Thumbnail recibido: ${thumbnail.width}x${thumbnail.height}")
            } else {
                statusText = "Intent: sin thumbnail en extras"
                Log.w("IntentCapture", "No thumbnail in result extras")
            }
        } else {
            statusText = "Intent cancelado (code=${result.resultCode})"
        }
    }

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(statusText, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)

        // Captured image preview
        capturedBitmap?.let { bmp ->
            Image(
                bitmap = bmp.asImageBitmap(),
                contentDescription = "Foto capturada por Intent",
                modifier = Modifier.fillMaxWidth().height(280.dp).clip(RoundedCornerShape(16.dp))
            )
        }

        if (capturedBitmap == null) {
            Card(
                modifier = Modifier.fillMaxWidth().height(280.dp),
                colors = CardDefaults.cardColors(containerColor = Color(0xFFF5F5F5))
            ) {
                Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                    Text("La imagen aparecera aqui",
                        color = Color.Gray, style = MaterialTheme.typography.bodyLarge)
                }
            }
        }

        // Capture button — launches ACTION_IMAGE_CAPTURE
        Button(
            onClick = {
                statusText = "Lanzando camara del sistema..."
                val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
                launcher.launch(intent)
            },
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(12.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF4CAF50))
        ) {
            Icon(Icons.Default.PhotoCamera, contentDescription = null, modifier = Modifier.size(24.dp))
            Spacer(modifier = Modifier.width(8.dp))
            Text("Capturar por Intent", fontWeight = FontWeight.Bold)
        }

        if (capturedSize > 0) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(containerColor = Color(0xFFE8F5E9))
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text("Resultado:", fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.titleSmall)
                    Spacer(modifier = Modifier.height(4.dp))
                    val bmp = capturedBitmap
                    Text("Thumbnail: ${bmp?.width}x${bmp?.height}",
                        style = MaterialTheme.typography.bodyMedium)
                    Text("Tamano JPEG: $capturedSize bytes",
                        style = MaterialTheme.typography.bodyMedium,
                        color = Color(0xFF2E7D32))
                }
            }
        }
    }
}
