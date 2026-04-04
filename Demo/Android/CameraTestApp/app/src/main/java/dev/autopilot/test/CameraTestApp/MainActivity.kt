package dev.autopilot.test.CameraTestApp

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import dev.autopilot.test.CameraTestApp.ui.tabs.*
import dev.autopilot.test.CameraTestApp.ui.theme.CameraTestAppTheme

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
                if (hasCameraPermission) {
                    CameraTestApp()
                } else {
                    Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                        Box(contentAlignment = Alignment.Center) {
                            Text("Se requiere permiso de camara",
                                style = MaterialTheme.typography.titleMedium, color = Color.Gray)
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CameraTestApp() {
    val tabs = listOf("CameraX", "QR", "OCR", "Intent", "Camera1", "ID")
    var selected by remember { mutableIntStateOf(0) }

    Column(modifier = Modifier.fillMaxSize()) {
        // Header
        TopAppBar(
            title = { Text("Camera Test", fontWeight = FontWeight.Bold) },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.primaryContainer
            )
        )

        // Tab row
        ScrollableTabRow(
            selectedTabIndex = selected,
            edgePadding = 8.dp
        ) {
            tabs.forEachIndexed { index, title ->
                Tab(
                    selected = index == selected,
                    onClick = { selected = index },
                    text = { Text(title) }
                )
            }
        }

        // Tab content
        when (selected) {
            0 -> CameraXTab()
            1 -> QrScanTab()
            2 -> OcrTab()
            3 -> IntentCaptureTab()
            4 -> Camera1Tab()
            5 -> IdCaptureTab()
        }
    }
}
