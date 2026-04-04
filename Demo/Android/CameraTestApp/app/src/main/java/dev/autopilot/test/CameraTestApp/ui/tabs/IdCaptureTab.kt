package dev.autopilot.test.CameraTestApp.ui.tabs

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Badge
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Face
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
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

/**
 * ID Capture tab — multi-step identity verification flow.
 *
 * Steps: 1) Capture front of ID (back camera)
 *        2) Capture back of ID (back camera)
 *        3) Capture selfie (FRONT camera)
 *
 * Each step uses CameraX ImageCapture (intercepted by our mock).
 * Between steps, the test harness can hot-swap the injected image
 * via `auto-android inject <new-image>`.
 *
 * This simulates real KYC/onboarding flows (Jumio, Onfido, etc.)
 */

enum class IdStep(val label: String, val useFrontCamera: Boolean) {
    FRONT("Frente de ID", false),
    BACK("Reverso de ID", false),
    SELFIE("Selfie", true)
}

@Composable
fun IdCaptureTab() {
    var currentStep by remember { mutableStateOf(IdStep.FRONT) }
    var captures by remember { mutableStateOf(mapOf<IdStep, Bitmap>()) }
    var capturedSizes by remember { mutableStateOf(mapOf<IdStep, Int>()) }
    var statusText by remember { mutableStateOf("Paso 1/3: Captura frente de ID") }
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }
    var allDone by remember { mutableStateOf(false) }
    val context = LocalContext.current

    val cameraSelector = if (currentStep.useFrontCamera)
        CameraSelector.DEFAULT_FRONT_CAMERA else CameraSelector.DEFAULT_BACK_CAMERA

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp).verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text(statusText, style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)

        // Step indicator
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            IdStep.entries.forEach { step ->
                val completed = captures.containsKey(step)
                val active = step == currentStep && !allDone
                FilterChip(
                    selected = completed,
                    onClick = {},
                    label = { Text(step.label, style = MaterialTheme.typography.labelSmall) },
                    leadingIcon = if (completed) {
                        { Icon(Icons.Default.Check, contentDescription = null, modifier = Modifier.size(16.dp)) }
                    } else null,
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = Color(0xFF4CAF50),
                        selectedLabelColor = Color.White,
                        selectedLeadingIconColor = Color.White
                    ),
                    border = if (active) FilterChipDefaults.filterChipBorder(
                        borderColor = Color(0xFF1976D2), borderWidth = 2.dp,
                        enabled = true, selected = false
                    ) else null,
                    modifier = Modifier.weight(1f)
                )
            }
        }

        if (!allDone) {
            // Camera preview for current step
            key(currentStep) {
                CameraPreviewView(
                    modifier = Modifier.fillMaxWidth().height(260.dp).clip(RoundedCornerShape(16.dp)),
                    cameraSelector = cameraSelector,
                    onImageCaptureReady = { imageCapture = it }
                )
            }

            // Capture button
            val buttonIcon = if (currentStep == IdStep.SELFIE) Icons.Default.Face else Icons.Default.Badge
            val buttonColor = when (currentStep) {
                IdStep.FRONT -> Color(0xFF1976D2)
                IdStep.BACK -> Color(0xFF0097A7)
                IdStep.SELFIE -> Color(0xFFE91E63)
            }

            Button(
                onClick = {
                    statusText = "Capturando ${currentStep.label}..."
                    imageCapture?.takePicture(
                        ContextCompat.getMainExecutor(context),
                        object : ImageCapture.OnImageCapturedCallback() {
                            override fun onCaptureSuccess(image: ImageProxy) {
                                val buffer: ByteBuffer = image.planes[0].buffer
                                val bytes = ByteArray(buffer.remaining())
                                buffer.get(bytes)
                                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                                image.close()

                                if (bmp == null) {
                                    statusText = "Error: no se pudo decodificar"
                                    return
                                }

                                val stream = ByteArrayOutputStream()
                                bmp.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                                val size = stream.size()

                                captures = captures + (currentStep to bmp)
                                capturedSizes = capturedSizes + (currentStep to size)
                                Log.d("IdCapture", "${currentStep.name} capturado: $size bytes")

                                // Advance to next step or finish
                                val steps = IdStep.entries
                                val nextIndex = steps.indexOf(currentStep) + 1
                                if (nextIndex < steps.size) {
                                    currentStep = steps[nextIndex]
                                    imageCapture = null
                                    statusText = "Paso ${nextIndex + 1}/3: Captura ${steps[nextIndex].label}"
                                } else {
                                    allDone = true
                                    statusText = "Verificacion completa (${captures.size}/3 capturas)"
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
                colors = ButtonDefaults.buttonColors(containerColor = buttonColor),
                enabled = imageCapture != null
            ) {
                Icon(buttonIcon, contentDescription = null, modifier = Modifier.size(24.dp))
                Spacer(modifier = Modifier.width(8.dp))
                Text("Capturar ${currentStep.label}", fontWeight = FontWeight.Bold)
            }
        }

        // Show captured thumbnails
        if (captures.isNotEmpty()) {
            Card(
                modifier = Modifier.fillMaxWidth(),
                colors = CardDefaults.cardColors(
                    containerColor = if (allDone) Color(0xFFE8F5E9) else Color(0xFFFAFAFA)
                )
            ) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Text(
                        if (allDone) "Verificacion completa" else "Capturas realizadas",
                        fontWeight = FontWeight.Bold,
                        style = MaterialTheme.typography.titleSmall,
                        color = if (allDone) Color(0xFF2E7D32) else Color.Unspecified
                    )
                    Spacer(modifier = Modifier.height(8.dp))
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        captures.forEach { (step, bmp) ->
                            Column(
                                horizontalAlignment = Alignment.CenterHorizontally,
                                modifier = Modifier.weight(1f)
                            ) {
                                Image(
                                    bitmap = bmp.asImageBitmap(),
                                    contentDescription = step.label,
                                    modifier = Modifier.size(80.dp).clip(RoundedCornerShape(8.dp))
                                )
                                Text(step.label, style = MaterialTheme.typography.labelSmall)
                                val size = capturedSizes[step] ?: 0
                                Text("${size}b", style = MaterialTheme.typography.labelSmall,
                                    color = Color(0xFF4CAF50))
                            }
                        }
                    }
                }
            }
        }
    }
}
