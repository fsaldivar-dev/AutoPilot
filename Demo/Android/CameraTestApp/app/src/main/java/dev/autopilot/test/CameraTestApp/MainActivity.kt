package dev.autopilot.test.CameraTestApp

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageCapture
import androidx.camera.core.ImageCaptureException
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
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
import dev.autopilot.test.CameraTestApp.ui.theme.CameraTestAppTheme
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer

class MainActivity : ComponentActivity() {

    private var hasCameraPermission by mutableStateOf(false)

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasCameraPermission = granted
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        hasCameraPermission = ContextCompat.checkSelfPermission(
            this, Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasCameraPermission) {
            permissionLauncher.launch(Manifest.permission.CAMERA)
        }

        setContent {
            CameraTestAppTheme {
                CameraTestScreen(hasCameraPermission = hasCameraPermission)
            }
        }
    }
}

@Composable
fun CameraTestScreen(hasCameraPermission: Boolean) {
    var statusText by remember { mutableStateOf("Inicializando...") }
    var capturedBitmap by remember { mutableStateOf<Bitmap?>(null) }
    var capturedSize by remember { mutableIntStateOf(0) }
    var imageCapture by remember { mutableStateOf<ImageCapture?>(null) }

    val context = LocalContext.current

    LaunchedEffect(hasCameraPermission) {
        statusText = if (hasCameraPermission) "Camara lista" else "Sin permiso de camara"
    }

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp)
                .padding(top = 48.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(20.dp)
        ) {
            // Title
            Text(
                text = "Camera Test",
                style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold
            )

            // Status
            Text(
                text = statusText,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // Camera Preview
            if (hasCameraPermission) {
                CameraPreview(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(300.dp)
                        .clip(RoundedCornerShape(16.dp)),
                    onImageCaptureReady = { imageCapture = it }
                )
            } else {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(300.dp)
                        .clip(RoundedCornerShape(16.dp))
                        .background(Color.DarkGray),
                    contentAlignment = Alignment.Center
                ) {
                    Text("Camara no disponible", color = Color.White)
                }
            }

            // Captured image
            capturedBitmap?.let { bitmap ->
                Image(
                    bitmap = bitmap.asImageBitmap(),
                    contentDescription = "Foto capturada",
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(100.dp)
                        .clip(RoundedCornerShape(8.dp))
                )
            }

            // Capture button
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
                                val size = stream.size()

                                capturedBitmap = bmp
                                capturedSize = size
                                statusText = "Foto capturada"
                                Log.d("CameraTest", "Foto capturada ($size bytes)")
                                image.close()
                            }

                            override fun onError(exception: ImageCaptureException) {
                                statusText = "Error: ${exception.message}"
                                Log.e("CameraTest", "Capture failed", exception)
                            }
                        }
                    )
                },
                modifier = Modifier
                    .fillMaxWidth()
                    .height(52.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF007AFF)),
                enabled = hasCameraPermission && imageCapture != null
            ) {
                Icon(
                    Icons.Default.Camera,
                    contentDescription = null,
                    modifier = Modifier.size(24.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    "Capturar Foto",
                    fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.titleMedium
                )
            }

            // Captured info
            if (capturedSize > 0) {
                Text(
                    text = "Foto capturada ($capturedSize bytes)",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color(0xFF4CAF50)
                )
            }

            Spacer(modifier = Modifier.weight(1f))
        }
    }
}

@Composable
fun CameraPreview(
    modifier: Modifier = Modifier,
    onImageCaptureReady: (ImageCapture) -> Unit
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
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
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        capture
                    )
                    onImageCaptureReady(capture)
                } catch (e: Exception) {
                    Log.e("CameraTest", "Camera bind failed", e)
                }
            }, ContextCompat.getMainExecutor(ctx))

            previewView
        }
    )
}
