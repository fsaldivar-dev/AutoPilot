package dev.autopilot.test.Explorea

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Bundle
import android.widget.Toast
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import java.text.SimpleDateFormat
import java.util.*

// ─────────────────────────────────────────────────────
// Theme Colors
// ─────────────────────────────────────────────────────
object AppColors {
    val Primary = Color(0xFFFF6B6B)
    val Accent = Color(0xFFFF8E53)
    val Secondary = Color(0xFF4ECDC4)
    val Tertiary = Color(0xFFF093FB)
    val DarkText = Color(0xFF2C3E50)
    val LightText = Color(0xFF95A5A6)
    val CardBg = Color(0xFFF8F9FA)
    val White = Color.White
    val Background = Color(0xFFF5F5F5)

    val AuthGradient = listOf(Primary, Accent, Tertiary)
    val HeaderGradient = listOf(Primary, Accent)
}

// ─────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────
enum class TravelCategory(
    val label: String,
    val icon: ImageVector,
    val color: Color
) {
    ADVENTURE("Aventura", Icons.Default.Terrain, Color(0xFFFF9800)),
    FOOD("Gastronomia", Icons.Default.Restaurant, Color(0xFFF44336)),
    CULTURE("Cultura", Icons.Default.AccountBalance, Color(0xFF9C27B0)),
    NATURE("Naturaleza", Icons.Default.Park, Color(0xFF4CAF50)),
    NIGHTLIFE("Vida Nocturna", Icons.Default.NightlightRound, Color(0xFF3F51B5)),
    SHOPPING("Compras", Icons.Default.ShoppingBag, Color(0xFFE91E63)),
    RELAXATION("Relax", Icons.Default.Spa, Color(0xFF00BCD4));
}

data class JournalEntry(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val description: String = "",
    val date: Date = Date(),
    val category: TravelCategory,
    val mood: Int = 3,
    val isFavorite: Boolean = false,
    val locationName: String = "",
    val latitude: Double = 0.0,
    val longitude: Double = 0.0,
    val photos: List<String> = emptyList()
)

data class UserProfile(
    val name: String = "Viajero",
    val email: String = "viajero@explorea.app",
    val notifications: Boolean = true,
    val darkMode: Boolean = false,
    val metricSystem: Boolean = true
)

data class ScannedQR(
    val id: String = UUID.randomUUID().toString(),
    val content: String,
    val date: Date = Date()
)

// ─────────────────────────────────────────────────────
// App State
// ─────────────────────────────────────────────────────
class AppState {
    var isAuthenticated by mutableStateOf(false)
    var entries by mutableStateOf(sampleEntries())
    var profile by mutableStateOf(UserProfile())
    var scannedQRs by mutableStateOf(listOf<ScannedQR>())

    fun toggleFavorite(id: String) {
        entries = entries.map {
            if (it.id == id) it.copy(isFavorite = !it.isFavorite) else it
        }
    }

    fun deleteEntry(id: String) {
        entries = entries.filter { it.id != id }
    }

    fun addEntry(entry: JournalEntry) {
        entries = listOf(entry) + entries
    }

    fun addQR(content: String) {
        scannedQRs = listOf(ScannedQR(content = content)) + scannedQRs
    }

    companion object {
        fun sampleEntries(): List<JournalEntry> {
            val cal = Calendar.getInstance()
            return listOf(
                JournalEntry(
                    title = "Atardecer en Santorini",
                    description = "Un atardecer inolvidable desde Oia, con los techos azules y el mar Egeo de fondo. La luz dorada pintaba todo de naranja y rosa.",
                    date = cal.apply { add(Calendar.DAY_OF_YEAR, -2) }.time,
                    category = TravelCategory.ADVENTURE,
                    mood = 5,
                    isFavorite = true,
                    locationName = "Santorini, Grecia",
                    latitude = 36.3932,
                    longitude = 25.4615
                ),
                JournalEntry(
                    title = "Tacos al Pastor en CDMX",
                    description = "Los mejores tacos al pastor que he probado, en un puesto callejero cerca del Zocalo. La salsa verde era perfecta.",
                    date = cal.apply { add(Calendar.DAY_OF_YEAR, -3) }.time,
                    category = TravelCategory.FOOD,
                    mood = 5,
                    isFavorite = true,
                    locationName = "Ciudad de Mexico, Mexico",
                    latitude = 19.4326,
                    longitude = -99.1332
                ),
                JournalEntry(
                    title = "Museo del Louvre",
                    description = "Tres horas no fueron suficientes. La Mona Lisa es mas pequena de lo esperado, pero la Victoria de Samotracia me dejo sin palabras.",
                    date = cal.apply { add(Calendar.DAY_OF_YEAR, -5) }.time,
                    category = TravelCategory.CULTURE,
                    mood = 4,
                    isFavorite = false,
                    locationName = "Paris, Francia",
                    latitude = 48.8606,
                    longitude = 2.3376
                ),
                JournalEntry(
                    title = "Cruce de Shibuya",
                    description = "El caos ordenado de Shibuya al anochecer. Miles de personas cruzando al mismo tiempo, las luces de neon reflejandose en el asfalto mojado.",
                    date = cal.apply { add(Calendar.DAY_OF_YEAR, -7) }.time,
                    category = TravelCategory.NIGHTLIFE,
                    mood = 4,
                    isFavorite = false,
                    locationName = "Tokio, Japon",
                    latitude = 35.6595,
                    longitude = 139.7004
                ),
                JournalEntry(
                    title = "Senderismo en los Alpes",
                    description = "Ruta de 12 km por los Alpes suizos. El aire fresco, las montanas nevadas y el sonido de las campanas de las vacas.",
                    date = cal.apply { add(Calendar.DAY_OF_YEAR, -10) }.time,
                    category = TravelCategory.NATURE,
                    mood = 5,
                    isFavorite = true,
                    locationName = "Interlaken, Suiza",
                    latitude = 46.6863,
                    longitude = 7.8632
                ),
                JournalEntry(
                    title = "Spa en Bali",
                    description = "Un dia completo de spa balines: masaje con aceites esenciales, bano de flores y meditacion al atardecer.",
                    date = cal.apply { add(Calendar.DAY_OF_YEAR, -14) }.time,
                    category = TravelCategory.RELAXATION,
                    mood = 5,
                    isFavorite = false,
                    locationName = "Ubud, Bali",
                    latitude = -8.5069,
                    longitude = 115.2625
                ),
                JournalEntry(
                    title = "Gran Bazar de Estambul",
                    description = "Perderse en los pasillos del Gran Bazar es una experiencia unica. Regatear por lamparas turcas y probar el te de manzana.",
                    date = cal.apply { add(Calendar.DAY_OF_YEAR, -18) }.time,
                    category = TravelCategory.SHOPPING,
                    mood = 3,
                    isFavorite = false,
                    locationName = "Estambul, Turquia",
                    latitude = 41.0106,
                    longitude = 28.9684
                )
            )
        }
    }
}

val moodEmojis = listOf("\uD83D\uDE34", "\uD83D\uDE14", "\uD83D\uDE10", "\uD83D\uDE42", "\uD83D\uDE04", "\uD83E\uDD29")

fun formatDate(date: Date): String {
    val sdf = SimpleDateFormat("dd MMM yyyy", Locale("es", "MX"))
    return sdf.format(date)
}

// ─────────────────────────────────────────────────────
// MainActivity
// ─────────────────────────────────────────────────────
class MainActivity : FragmentActivity() {
    companion object {
        private const val RC_CAMERA = 1001
    }

    var hasCameraPermission by mutableStateOf(false)
        private set

    fun requestCameraPermission() {
        androidx.core.app.ActivityCompat.requestPermissions(
            this, arrayOf(Manifest.permission.CAMERA), RC_CAMERA
        )
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RC_CAMERA && grantResults.isNotEmpty()) {
            hasCameraPermission = grantResults[0] == PackageManager.PERMISSION_GRANTED
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        hasCameraPermission = ContextCompat.checkSelfPermission(
            this, Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
        enableEdgeToEdge()
        setContent {
            ExploreaApp()
        }
    }
}

// ─────────────────────────────────────────────────────
// Root App
// ─────────────────────────────────────────────────────
@Composable
fun ExploreaApp() {
    val appState = remember { AppState() }

    MaterialTheme(
        colorScheme = lightColorScheme(
            primary = AppColors.Primary,
            secondary = AppColors.Secondary,
            tertiary = AppColors.Accent,
            surface = AppColors.White,
            background = AppColors.Background,
            onPrimary = AppColors.White,
            onSurface = AppColors.DarkText,
            onBackground = AppColors.DarkText
        )
    ) {
        if (!appState.isAuthenticated) {
            AuthScreen(onAuthenticated = { appState.isAuthenticated = true })
        } else {
            MainScreen(appState)
        }
    }
}

// ─────────────────────────────────────────────────────
// Auth Screen
// ─────────────────────────────────────────────────────
@Composable
fun AuthScreen(onAuthenticated: () -> Unit) {
    val context = LocalContext.current
    var showPIN by remember { mutableStateOf(false) }
    var pin by remember { mutableStateOf("") }
    var pinError by remember { mutableStateOf(false) }

    val biometricAvailable = remember {
        val manager = BiometricManager.from(context)
        manager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG or
                    BiometricManager.Authenticators.BIOMETRIC_WEAK
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    fun promptBiometric() {
        val activity = context as? FragmentActivity ?: return
        val executor = ContextCompat.getMainExecutor(context)
        val callback = object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                onAuthenticated()
            }
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                // user cancelled
            }
        }
        val prompt = BiometricPrompt(activity, executor, callback)
        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle("Explorea")
            .setSubtitle("Desbloquea tu diario de viajes")
            .setNegativeButtonText("Usar código")
            .build()
        prompt.authenticate(info)
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(
                Brush.linearGradient(
                    colors = AppColors.AuthGradient,
                    start = Offset(0f, 0f),
                    end = Offset(0f, Float.POSITIVE_INFINITY)
                )
            )
            .systemBarsPadding(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(32.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Flight,
                contentDescription = "Explorea",
                tint = Color.White,
                modifier = Modifier.size(80.dp)
            )
            Spacer(Modifier.height(16.dp))
            Text(
                "Explorea",
                fontSize = 36.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
            Text(
                "Tu diario de viajes",
                fontSize = 16.sp,
                color = Color.White.copy(alpha = 0.8f)
            )

            Spacer(Modifier.height(48.dp))

            if (!showPIN) {
                Button(
                    onClick = {
                        if (biometricAvailable) promptBiometric()
                        else showPIN = true
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Color.White.copy(alpha = 0.25f)
                    ),
                    shape = RoundedCornerShape(16.dp),
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(56.dp)
                ) {
                    Icon(
                        Icons.Default.Fingerprint,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(Modifier.width(12.dp))
                    Text(
                        if (biometricAvailable) "Desbloquear con biometría"
                        else "Desbloquear con código",
                        color = Color.White,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold
                    )
                }

                if (biometricAvailable) {
                    Spacer(Modifier.height(16.dp))
                    TextButton(onClick = { showPIN = true }) {
                        Text("Usar código", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp)
                    }
                }
            } else {
                // PIN entry
                Text(
                    "Ingresa tu código",
                    color = Color.White,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold
                )
                Spacer(Modifier.height(24.dp))

                // PIN circles
                Row(
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    for (i in 0 until 4) {
                        val filled = i < pin.length
                        val circleColor by animateColorAsState(
                            if (pinError) Color(0xFFFF4444)
                            else if (filled) Color.White
                            else Color.White.copy(alpha = 0.3f),
                            label = "pin_circle_$i"
                        )
                        Box(
                            modifier = Modifier
                                .size(20.dp)
                                .clip(CircleShape)
                                .background(circleColor)
                                .then(
                                    if (!filled) Modifier.border(
                                        2.dp,
                                        Color.White.copy(alpha = 0.5f),
                                        CircleShape
                                    )
                                    else Modifier
                                )
                        )
                    }
                }

                if (pinError) {
                    Spacer(Modifier.height(8.dp))
                    Text("Código incorrecto", color = Color(0xFFFFCDD2), fontSize = 14.sp)
                }

                Spacer(Modifier.height(32.dp))

                // Number pad
                val numbers = listOf(
                    listOf("1", "2", "3"),
                    listOf("4", "5", "6"),
                    listOf("7", "8", "9"),
                    listOf("", "0", "DEL")
                )
                Column(
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    for (row in numbers) {
                        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
                            for (key in row) {
                                if (key.isEmpty()) {
                                    Spacer(Modifier.size(72.dp))
                                } else {
                                    Box(
                                        modifier = Modifier
                                            .size(72.dp)
                                            .clip(CircleShape)
                                            .background(Color.White.copy(alpha = 0.15f))
                                            .clickable {
                                                pinError = false
                                                if (key == "DEL") {
                                                    if (pin.isNotEmpty()) pin = pin.dropLast(1)
                                                } else if (pin.length < 4) {
                                                    pin += key
                                                    if (pin.length == 4) {
                                                        if (pin == "1234") {
                                                            onAuthenticated()
                                                        } else {
                                                            pinError = true
                                                            pin = ""
                                                        }
                                                    }
                                                }
                                            },
                                        contentAlignment = Alignment.Center
                                    ) {
                                        if (key == "DEL") {
                                            Icon(
                                                Icons.Default.Backspace,
                                                contentDescription = "Borrar",
                                                tint = Color.White,
                                                modifier = Modifier.size(24.dp)
                                            )
                                        } else {
                                            Text(
                                                key,
                                                color = Color.White,
                                                fontSize = 28.sp,
                                                fontWeight = FontWeight.Light
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer(Modifier.height(16.dp))
                if (biometricAvailable) {
                    TextButton(onClick = {
                        showPIN = false
                        pin = ""
                        pinError = false
                    }) {
                        Text(
                            "Usar biometría",
                            color = Color.White.copy(alpha = 0.8f),
                            fontSize = 14.sp
                        )
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────
// Navigation
// ─────────────────────────────────────────────────────
sealed class Screen(val route: String, val label: String, val icon: ImageVector) {
    data object Home : Screen("home", "Inicio", Icons.Default.MenuBook)
    data object Capture : Screen("capture", "Capturar", Icons.Default.CameraAlt)
    data object Map : Screen("map", "Mapa", Icons.Default.Map)
    data object Profile : Screen("profile", "Perfil", Icons.Default.Person)
}

@Composable
fun MainScreen(appState: AppState) {
    val navController = rememberNavController()
    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentRoute = navBackStackEntry?.destination?.route
    val activity = LocalContext.current as MainActivity

    val tabs = listOf(Screen.Home, Screen.Capture, Screen.Map, Screen.Profile)
    val showBottomBar = currentRoute in tabs.map { it.route }

    Scaffold(
        modifier = Modifier.systemBarsPadding(),
        bottomBar = {
            if (showBottomBar) {
                BottomNavBar(
                    tabs = tabs,
                    currentRoute = currentRoute,
                    onTabSelected = { route ->
                        if (currentRoute != route) {
                            navController.navigate(route) {
                                popUpTo(navController.graph.startDestinationId) {
                                    saveState = true
                                }
                                launchSingleTop = true
                                restoreState = true
                            }
                        }
                    },
                    onFabClick = { navController.navigate("new_entry") }
                )
            }
        }
    ) { innerPadding ->
        NavHost(
            navController = navController,
            startDestination = "home",
            modifier = Modifier.padding(innerPadding)
        ) {
            composable("home") { HomeView(appState, navController) }
            composable("capture") {
                CaptureView(appState, activity.hasCameraPermission) {
                    activity.requestCameraPermission()
                }
            }
            composable("map") { MapExploreView(appState) }
            composable("profile") {
                ProfileView(appState) { appState.isAuthenticated = false }
            }
            composable("entry_detail/{entryId}") { backStackEntry ->
                val entryId = backStackEntry.arguments?.getString("entryId") ?: ""
                val entry = appState.entries.find { it.id == entryId }
                if (entry != null) {
                    EntryDetailView(entry, appState, navController)
                }
            }
            composable("new_entry") { NewEntryView(appState, navController) }
        }
    }
}

@Composable
fun BottomNavBar(
    tabs: List<Screen>,
    currentRoute: String?,
    onTabSelected: (String) -> Unit,
    onFabClick: () -> Unit
) {
    Box {
        NavigationBar(
            containerColor = AppColors.White,
            contentColor = AppColors.DarkText,
            tonalElevation = 8.dp
        ) {
            val leftTabs = tabs.take(2)
            val rightTabs = tabs.drop(2)

            leftTabs.forEach { screen ->
                NavigationBarItem(
                    icon = { Icon(screen.icon, contentDescription = screen.label) },
                    label = { Text(screen.label, fontSize = 11.sp) },
                    selected = currentRoute == screen.route,
                    onClick = { onTabSelected(screen.route) },
                    colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = AppColors.Primary,
                        selectedTextColor = AppColors.Primary,
                        unselectedIconColor = AppColors.LightText,
                        unselectedTextColor = AppColors.LightText,
                        indicatorColor = AppColors.Primary.copy(alpha = 0.1f)
                    )
                )
            }

            // FAB spacer
            NavigationBarItem(
                icon = { Spacer(Modifier.size(24.dp)) },
                label = { },
                selected = false,
                onClick = { },
                enabled = false
            )

            rightTabs.forEach { screen ->
                NavigationBarItem(
                    icon = { Icon(screen.icon, contentDescription = screen.label) },
                    label = { Text(screen.label, fontSize = 11.sp) },
                    selected = currentRoute == screen.route,
                    onClick = { onTabSelected(screen.route) },
                    colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = AppColors.Primary,
                        selectedTextColor = AppColors.Primary,
                        unselectedIconColor = AppColors.LightText,
                        unselectedTextColor = AppColors.LightText,
                        indicatorColor = AppColors.Primary.copy(alpha = 0.1f)
                    )
                )
            }
        }

        FloatingActionButton(
            onClick = onFabClick,
            containerColor = AppColors.Primary,
            contentColor = Color.White,
            shape = CircleShape,
            modifier = Modifier
                .align(Alignment.TopCenter)
                .offset(y = (-28).dp)
                .size(56.dp)
                .shadow(8.dp, CircleShape)
        ) {
            Icon(Icons.Default.Add, contentDescription = "Nueva entrada", modifier = Modifier.size(28.dp))
        }
    }
}

// ─────────────────────────────────────────────────────
// HomeView
// ─────────────────────────────────────────────────────
@Composable
fun HomeView(appState: AppState, navController: NavHostController) {
    var selectedCategory by remember { mutableStateOf<TravelCategory?>(null) }
    var showFavoritesOnly by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }

    val filteredEntries = appState.entries.filter { entry ->
        val matchesCategory = selectedCategory == null || entry.category == selectedCategory
        val matchesFavorite = !showFavoritesOnly || entry.isFavorite
        val matchesSearch = searchQuery.isBlank() ||
                entry.title.contains(searchQuery, ignoreCase = true) ||
                entry.locationName.contains(searchQuery, ignoreCase = true)
        matchesCategory && matchesFavorite && matchesSearch
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // Header
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.horizontalGradient(AppColors.HeaderGradient))
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            Column {
                Text("Explorea", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = Color.White)
                Text("Tu diario de viajes", fontSize = 14.sp, color = Color.White.copy(alpha = 0.8f))
            }
        }

        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(bottom = 16.dp)
        ) {
            // Category chips
            item {
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    item {
                        FilterChip(
                            selected = selectedCategory == null,
                            onClick = { selectedCategory = null },
                            label = { Text("Todos") },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = AppColors.Primary,
                                selectedLabelColor = Color.White
                            )
                        )
                    }
                    items(TravelCategory.entries) { category ->
                        FilterChip(
                            selected = selectedCategory == category,
                            onClick = {
                                selectedCategory =
                                    if (selectedCategory == category) null else category
                            },
                            label = { Text(category.label) },
                            leadingIcon = {
                                Icon(category.icon, contentDescription = null, modifier = Modifier.size(16.dp))
                            },
                            colors = FilterChipDefaults.filterChipColors(
                                selectedContainerColor = category.color,
                                selectedLabelColor = Color.White,
                                selectedLeadingIconColor = Color.White
                            )
                        )
                    }
                }
            }

            // Search bar + favorites toggle
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedTextField(
                        value = searchQuery,
                        onValueChange = { searchQuery = it },
                        placeholder = {
                            Text("Buscar destinos, experiencias...", fontSize = 14.sp)
                        },
                        leadingIcon = {
                            Icon(Icons.Default.Search, contentDescription = null, modifier = Modifier.size(20.dp))
                        },
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp),
                        singleLine = true,
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = AppColors.Primary,
                            unfocusedBorderColor = Color.LightGray
                        )
                    )
                    IconButton(onClick = { showFavoritesOnly = !showFavoritesOnly }) {
                        Icon(
                            if (showFavoritesOnly) Icons.Default.Favorite
                            else Icons.Default.FavoriteBorder,
                            contentDescription = "Favoritos",
                            tint = if (showFavoritesOnly) AppColors.Primary else AppColors.LightText
                        )
                    }
                }
                Spacer(Modifier.height(12.dp))
            }

            if (filteredEntries.isEmpty()) {
                item { EmptyState() }
            } else {
                // Hero card
                item {
                    HeroEntryCard(
                        entry = filteredEntries.first(),
                        onTap = {
                            navController.navigate("entry_detail/${filteredEntries.first().id}")
                        },
                        onFavorite = { appState.toggleFavorite(filteredEntries.first().id) }
                    )
                }
                // Compact cards
                items(filteredEntries.drop(1), key = { it.id }) { entry ->
                    CompactEntryCard(
                        entry = entry,
                        onTap = { navController.navigate("entry_detail/${entry.id}") },
                        onFavorite = { appState.toggleFavorite(entry.id) }
                    )
                }
            }
        }
    }
}

@Composable
fun EmptyState() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(64.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Icon(
            Icons.Default.Flight,
            contentDescription = null,
            tint = AppColors.LightText,
            modifier = Modifier.size(64.dp)
        )
        Spacer(Modifier.height(16.dp))
        Text(
            "No hay viajes aun",
            fontSize = 18.sp,
            fontWeight = FontWeight.SemiBold,
            color = AppColors.DarkText
        )
        Spacer(Modifier.height(8.dp))
        Text(
            "Comienza a registrar tus aventuras",
            fontSize = 14.sp,
            color = AppColors.LightText
        )
        Spacer(Modifier.height(24.dp))
        Button(
            onClick = { },
            colors = ButtonDefaults.buttonColors(containerColor = AppColors.Primary),
            shape = RoundedCornerShape(12.dp)
        ) {
            Icon(Icons.Default.Add, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text("Crear primera entrada")
        }
    }
}

@Composable
fun HeroEntryCard(entry: JournalEntry, onTap: () -> Unit, onFavorite: () -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clickable { onTap() },
        shape = RoundedCornerShape(16.dp),
        elevation = CardDefaults.cardElevation(defaultElevation = 4.dp),
        colors = CardDefaults.cardColors(containerColor = AppColors.White)
    ) {
        Column {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
                    .background(
                        Brush.linearGradient(
                            colors = listOf(
                                entry.category.color,
                                entry.category.color.copy(alpha = 0.6f)
                            ),
                            start = Offset(0f, 0f),
                            end = Offset(
                                Float.POSITIVE_INFINITY,
                                Float.POSITIVE_INFINITY
                            )
                        )
                    )
            ) {
                // Category badge
                Surface(
                    modifier = Modifier
                        .padding(12.dp)
                        .align(Alignment.TopStart),
                    color = Color.White.copy(alpha = 0.25f),
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(4.dp)
                    ) {
                        Icon(
                            entry.category.icon,
                            contentDescription = null,
                            tint = Color.White,
                            modifier = Modifier.size(14.dp)
                        )
                        Text(
                            entry.category.label,
                            color = Color.White,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }

                IconButton(
                    onClick = onFavorite,
                    modifier = Modifier.align(Alignment.TopEnd)
                ) {
                    Icon(
                        if (entry.isFavorite) Icons.Default.Favorite
                        else Icons.Default.FavoriteBorder,
                        contentDescription = "Favorito",
                        tint = if (entry.isFavorite) AppColors.Primary else Color.White
                    )
                }

                Text(
                    moodEmojis.getOrElse(entry.mood) { "\uD83D\uDE42" },
                    fontSize = 32.sp,
                    modifier = Modifier
                        .align(Alignment.BottomEnd)
                        .padding(12.dp)
                )
            }

            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    entry.title,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                    color = AppColors.DarkText
                )
                Spacer(Modifier.height(4.dp))
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        Icons.Default.LocationOn,
                        contentDescription = null,
                        tint = AppColors.LightText,
                        modifier = Modifier.size(14.dp)
                    )
                    Text(entry.locationName, fontSize = 13.sp, color = AppColors.LightText)
                    Spacer(Modifier.width(12.dp))
                    Icon(
                        Icons.Default.CalendarToday,
                        contentDescription = null,
                        tint = AppColors.LightText,
                        modifier = Modifier.size(14.dp)
                    )
                    Text(formatDate(entry.date), fontSize = 13.sp, color = AppColors.LightText)
                }
                if (entry.description.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        entry.description,
                        fontSize = 14.sp,
                        color = AppColors.DarkText.copy(alpha = 0.7f),
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )
                }
            }
        }
    }
}

@Composable
fun CompactEntryCard(entry: JournalEntry, onTap: () -> Unit, onFavorite: () -> Unit) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .clickable { onTap() },
        shape = RoundedCornerShape(12.dp),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        colors = CardDefaults.cardColors(containerColor = AppColors.White)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box(
                modifier = Modifier
                    .size(48.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(entry.category.color.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    entry.category.icon,
                    contentDescription = null,
                    tint = entry.category.color,
                    modifier = Modifier.size(24.dp)
                )
            }

            Spacer(Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    entry.title,
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AppColors.DarkText,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        Icons.Default.LocationOn,
                        contentDescription = null,
                        tint = AppColors.LightText,
                        modifier = Modifier.size(12.dp)
                    )
                    Text(
                        entry.locationName,
                        fontSize = 12.sp,
                        color = AppColors.LightText,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )
                }
                Text(formatDate(entry.date), fontSize = 11.sp, color = AppColors.LightText)
            }

            Text(
                moodEmojis.getOrElse(entry.mood) { "\uD83D\uDE42" },
                fontSize = 20.sp,
                modifier = Modifier.padding(horizontal = 4.dp)
            )

            IconButton(onClick = onFavorite, modifier = Modifier.size(36.dp)) {
                Icon(
                    if (entry.isFavorite) Icons.Default.Favorite
                    else Icons.Default.FavoriteBorder,
                    contentDescription = "Favorito",
                    tint = if (entry.isFavorite) AppColors.Primary else AppColors.LightText,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

// ─────────────────────────────────────────────────────
// CaptureView
// ─────────────────────────────────────────────────────
@Composable
fun CaptureView(appState: AppState, hasCameraPermission: Boolean, requestCameraPermission: () -> Unit) {
    var selectedTab by remember { mutableIntStateOf(0) }

    LaunchedEffect(Unit) {
        if (!hasCameraPermission) {
            requestCameraPermission()
        }
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.horizontalGradient(AppColors.HeaderGradient))
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            Text("Capturar", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = Color.White)
        }

        // Segmented picker
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFFF0F0F0))
                .padding(4.dp)
        ) {
            listOf("Fotos", "Escaner QR").forEachIndexed { index, label ->
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .background(
                            if (selectedTab == index) AppColors.White else Color.Transparent
                        )
                        .clickable { selectedTab = index }
                        .padding(vertical = 10.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        label,
                        fontSize = 14.sp,
                        fontWeight = if (selectedTab == index) FontWeight.SemiBold
                        else FontWeight.Normal,
                        color = if (selectedTab == index) AppColors.DarkText
                        else AppColors.LightText
                    )
                }
            }
        }

        if (selectedTab == 0) {
            PhotoCaptureView(hasCameraPermission)
        } else {
            QRScannerView(appState)
        }
    }
}

@Composable
fun PhotoCaptureView(hasCameraPermission: Boolean) {
    var flashOn by remember { mutableStateOf(false) }
    var imageCapture by remember { mutableStateOf<androidx.camera.core.ImageCapture?>(null) }
    val capturedPhotos = remember { mutableStateListOf<android.graphics.Bitmap>() }
    val context = LocalContext.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // Camera preview
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(340.dp)
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF1A1A2E)),
            contentAlignment = Alignment.Center
        ) {
            if (hasCameraPermission) {
                CameraPreview { imageCapture = it }
            } else {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(
                        Icons.Default.CameraAlt,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.5f),
                        modifier = Modifier.size(48.dp)
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Camara no disponible",
                        color = Color.White.copy(alpha = 0.5f),
                        fontSize = 14.sp
                    )
                    Text(
                        "Otorga permiso en Ajustes",
                        color = Color.White.copy(alpha = 0.3f),
                        fontSize = 12.sp
                    )
                }
            }
        }

        Spacer(Modifier.height(24.dp))

        // Camera controls with labels
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceEvenly,
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Flash
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                IconButton(
                    onClick = { flashOn = !flashOn },
                    modifier = Modifier
                        .size(52.dp)
                        .clip(CircleShape)
                        .background(Color(0xFFF0F0F0))
                ) {
                    Icon(
                        if (flashOn) Icons.Default.FlashOn else Icons.Default.FlashOff,
                        contentDescription = "Flash",
                        tint = if (flashOn) AppColors.Accent else AppColors.LightText
                    )
                }
                Spacer(Modifier.height(4.dp))
                Text("Flash", fontSize = 11.sp, color = AppColors.LightText)
            }

            // Capture button
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    modifier = Modifier
                        .size(72.dp)
                        .clip(CircleShape)
                        .background(Brush.linearGradient(AppColors.HeaderGradient))
                        .semantics { contentDescription = "Tomar foto" }
                        .clickable {
                            imageCapture?.takePicture(
                                ContextCompat.getMainExecutor(context),
                                object : androidx.camera.core.ImageCapture.OnImageCapturedCallback() {
                                    override fun onCaptureSuccess(image: androidx.camera.core.ImageProxy) {
                                        val buffer = image.planes[0].buffer
                                        val bytes = ByteArray(buffer.remaining())
                                        buffer.get(bytes)
                                        val bmp = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                                        if (bmp != null) capturedPhotos.add(0, bmp)
                                        image.close()
                                    }
                                    override fun onError(exception: androidx.camera.core.ImageCaptureException) {
                                        android.util.Log.e("Explorea", "Capture failed", exception)
                                    }
                                }
                            )
                        }
                        .padding(4.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(
                        Icons.Default.CameraAlt,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(28.dp)
                    )
                }
            }

            // Flip camera
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                IconButton(
                    onClick = { },
                    modifier = Modifier
                        .size(52.dp)
                        .clip(CircleShape)
                        .background(Color(0xFFF0F0F0))
                ) {
                    Icon(
                        Icons.Default.FlipCameraAndroid,
                        contentDescription = "Voltear",
                        tint = AppColors.DarkText
                    )
                }
                Spacer(Modifier.height(4.dp))
                Text("Voltear", fontSize = 11.sp, color = AppColors.LightText)
            }
        }

        Spacer(Modifier.height(16.dp))

        // Gallery button
        OutlinedButton(
            onClick = { },
            shape = RoundedCornerShape(12.dp),
            border = BorderStroke(1.dp, AppColors.Primary)
        ) {
            Icon(Icons.Default.PhotoLibrary, contentDescription = null, tint = AppColors.Primary)
            Spacer(Modifier.width(8.dp))
            Text("Seleccionar de galeria", color = AppColors.Primary)
        }

        // Captured photos section
        if (capturedPhotos.isNotEmpty()) {
            Spacer(Modifier.height(20.dp))

            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    "Fotos capturadas",
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold,
                    color = AppColors.DarkText
                )
                Text(
                    "${capturedPhotos.size} fotos",
                    fontSize = 14.sp,
                    color = AppColors.LightText
                )
            }

            Spacer(Modifier.height(12.dp))

            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(capturedPhotos.size) { index ->
                    androidx.compose.foundation.Image(
                        bitmap = capturedPhotos[index].asImageBitmap(),
                        contentDescription = "Foto ${index + 1}",
                        modifier = Modifier
                            .size(100.dp)
                            .clip(RoundedCornerShape(12.dp)),
                        contentScale = androidx.compose.ui.layout.ContentScale.Crop
                    )
                }
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
fun CameraPreview(onImageCaptureReady: (androidx.camera.core.ImageCapture) -> Unit) {
    val lifecycleOwner = LocalLifecycleOwner.current

    AndroidView(
        factory = { ctx ->
            val previewView = androidx.camera.view.PreviewView(ctx)
            try {
                val cameraProviderFuture =
                    androidx.camera.lifecycle.ProcessCameraProvider.getInstance(ctx)
                cameraProviderFuture.addListener({
                    val cameraProvider = cameraProviderFuture.get()
                    val preview = androidx.camera.core.Preview.Builder().build().also {
                        it.surfaceProvider = previewView.surfaceProvider
                    }
                    val capture = androidx.camera.core.ImageCapture.Builder()
                        .setCaptureMode(androidx.camera.core.ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                        .build()
                    val cameraSelector =
                        androidx.camera.core.CameraSelector.DEFAULT_BACK_CAMERA
                    try {
                        cameraProvider.unbindAll()
                        cameraProvider.bindToLifecycle(
                            lifecycleOwner,
                            cameraSelector,
                            preview,
                            capture
                        )
                        onImageCaptureReady(capture)
                    } catch (_: Exception) {
                    }
                }, ContextCompat.getMainExecutor(ctx))
            } catch (_: Exception) {
            }
            previewView
        },
        modifier = Modifier.fillMaxSize()
    )
}

@Composable
fun QRScannerView(appState: AppState) {
    val infiniteTransition = rememberInfiniteTransition(label = "qr_scan")
    val scanLineOffset by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(
            animation = tween(2000, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "scan_line"
    )

    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Box(
            modifier = Modifier
                .size(280.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(Color(0xFF1A1A2E)),
            contentAlignment = Alignment.Center
        ) {
            Box(
                modifier = Modifier
                    .size(220.dp)
                    .border(2.dp, AppColors.Secondary, RoundedCornerShape(8.dp))
            )
            Box(
                modifier = Modifier
                    .width(200.dp)
                    .height(2.dp)
                    .offset(y = ((scanLineOffset - 0.5f) * 200).dp)
                    .background(AppColors.Secondary)
            )
            Icon(
                Icons.Default.QrCodeScanner,
                contentDescription = null,
                tint = Color.White.copy(alpha = 0.3f),
                modifier = Modifier.size(48.dp)
            )
        }

        Spacer(Modifier.height(16.dp))
        Text(
            "Apunta la camara al codigo QR",
            fontSize = 14.sp,
            color = AppColors.LightText
        )

        Spacer(Modifier.height(24.dp))

        if (appState.scannedQRs.isNotEmpty()) {
            Text(
                "Codigos escaneados",
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = AppColors.DarkText,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp)
            )
            Spacer(Modifier.height(8.dp))
            LazyColumn(
                contentPadding = PaddingValues(horizontal = 16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                items(appState.scannedQRs, key = { it.id }) { qr ->
                    Card(
                        shape = RoundedCornerShape(12.dp),
                        colors = CardDefaults.cardColors(containerColor = AppColors.White)
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(12.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(
                                Icons.Default.QrCode,
                                contentDescription = null,
                                tint = AppColors.Secondary
                            )
                            Spacer(Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    qr.content,
                                    fontSize = 14.sp,
                                    color = AppColors.DarkText,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis
                                )
                                Text(
                                    formatDate(qr.date),
                                    fontSize = 11.sp,
                                    color = AppColors.LightText
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────
// MapExploreView
// ─────────────────────────────────────────────────────
@Composable
fun MapExploreView(appState: AppState) {
    var mapStyle by remember { mutableIntStateOf(0) }
    val styles = listOf("Estandar", "Satelite", "Hibrido")

    val favoriteCount = appState.entries.count { it.isFavorite }
    val cityCount =
        appState.entries.map { it.locationName.substringAfter(", ") }.distinct().size

    Column(modifier = Modifier.fillMaxSize()) {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.horizontalGradient(AppColors.HeaderGradient))
                .padding(horizontal = 20.dp, vertical = 16.dp)
        ) {
            Text(
                "Explorar Mapa",
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White
            )
        }

        // Map style picker
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFFF0F0F0))
                .padding(4.dp)
        ) {
            styles.forEachIndexed { index, label ->
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .clip(RoundedCornerShape(8.dp))
                        .background(
                            if (mapStyle == index) AppColors.White else Color.Transparent
                        )
                        .clickable { mapStyle = index }
                        .padding(vertical = 8.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        label,
                        fontSize = 13.sp,
                        fontWeight = if (mapStyle == index) FontWeight.SemiBold
                        else FontWeight.Normal,
                        color = if (mapStyle == index) AppColors.DarkText
                        else AppColors.LightText
                    )
                }
            }
        }

        // Map placeholder
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(
                    when (mapStyle) {
                        0 -> Color(0xFFE8F5E9)
                        1 -> Color(0xFF2E3440)
                        else -> Color(0xFFE3F2FD)
                    }
                ),
            contentAlignment = Alignment.Center
        ) {
            val textColor =
                if (mapStyle == 1) Color.White.copy(alpha = 0.5f) else AppColors.LightText

            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    Icons.Default.Map,
                    contentDescription = null,
                    tint = textColor,
                    modifier = Modifier.size(64.dp)
                )
                Spacer(Modifier.height(12.dp))
                Text(
                    "Mapa -- requiere Google Maps SDK",
                    fontSize = 14.sp,
                    color = textColor,
                    textAlign = TextAlign.Center
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "${appState.entries.size} ubicaciones guardadas",
                    fontSize = 12.sp,
                    color = textColor.copy(alpha = 0.6f)
                )

                Spacer(Modifier.height(16.dp))
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(horizontal = 16.dp)
                ) {
                    items(appState.entries) { entry ->
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(entry.category.color.copy(alpha = 0.15f))
                                .padding(8.dp)
                        ) {
                            Icon(
                                Icons.Default.LocationOn,
                                contentDescription = null,
                                tint = entry.category.color,
                                modifier = Modifier.size(20.dp)
                            )
                            Text(
                                entry.locationName.substringBefore(","),
                                fontSize = 10.sp,
                                color = AppColors.DarkText,
                                maxLines = 1
                            )
                        }
                    }
                }
            }
        }

        // Stats overlay
        Spacer(Modifier.height(12.dp))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceEvenly
        ) {
            StatBadge("Lugares", "${appState.entries.size}", AppColors.Primary)
            StatBadge("Ciudades", "$cityCount", AppColors.Accent)
            StatBadge("Favoritos", "$favoriteCount", AppColors.Secondary)
        }
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
fun StatBadge(label: String, value: String, color: Color) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clip(RoundedCornerShape(12.dp))
            .background(color.copy(alpha = 0.1f))
            .padding(horizontal = 20.dp, vertical = 12.dp)
    ) {
        Text(value, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = color)
        Text(label, fontSize = 12.sp, color = AppColors.LightText)
    }
}

// ─────────────────────────────────────────────────────
// ProfileView
// ─────────────────────────────────────────────────────
@Composable
fun ProfileView(appState: AppState, onLogout: () -> Unit) {
    val context = LocalContext.current
    val favoriteCount = appState.entries.count { it.isFavorite }
    val cityCount =
        appState.entries.map { it.locationName.substringAfter(", ") }.distinct().size
    val topCategory =
        appState.entries.groupBy { it.category }.maxByOrNull { it.value.size }?.key

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
    ) {
        // Header with avatar
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.horizontalGradient(AppColors.HeaderGradient))
                .padding(horizontal = 20.dp, vertical = 24.dp),
            contentAlignment = Alignment.Center
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Box(
                    modifier = Modifier
                        .size(90.dp)
                        .clip(CircleShape)
                        .background(Color.White.copy(alpha = 0.25f))
                        .border(3.dp, Color.White, CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Text(
                        appState.profile.name.firstOrNull()?.uppercase() ?: "V",
                        fontSize = 36.sp,
                        fontWeight = FontWeight.Bold,
                        color = Color.White
                    )
                }
                Spacer(Modifier.height(12.dp))
                Text(
                    appState.profile.name,
                    fontSize = 22.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Text(
                    appState.profile.email,
                    fontSize = 14.sp,
                    color = Color.White.copy(alpha = 0.8f)
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        // Editable fields
        ProfileSection("Informacion personal") {
            var name by remember { mutableStateOf(appState.profile.name) }
            var email by remember { mutableStateOf(appState.profile.email) }

            ProfileTextField("Nombre", name) {
                name = it
                appState.profile = appState.profile.copy(name = it)
            }
            ProfileTextField("Correo electronico", email) {
                email = it
                appState.profile = appState.profile.copy(email = it)
            }
        }

        // Toggles
        ProfileSection("Preferencias") {
            ProfileToggle("Notificaciones", Icons.Default.Notifications, appState.profile.notifications) {
                appState.profile = appState.profile.copy(notifications = it)
            }
            ProfileToggle("Sistema metrico", Icons.Default.Straighten, appState.profile.metricSystem) {
                appState.profile = appState.profile.copy(metricSystem = it)
            }
            ProfileToggle("Modo oscuro", Icons.Default.DarkMode, appState.profile.darkMode) {
                appState.profile = appState.profile.copy(darkMode = it)
            }
        }

        // Statistics
        ProfileSection("Estadisticas") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                ProfileStat("Entradas", "${appState.entries.size}")
                ProfileStat("Ciudades", "$cityCount")
                ProfileStat("Favoritos", "$favoriteCount")
            }
            Spacer(Modifier.height(12.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceEvenly
            ) {
                ProfileStat("Fotos", "${appState.entries.sumOf { it.photos.size }}")
                if (topCategory != null) {
                    ProfileStat("Top", topCategory.label)
                }
            }
        }

        // Clipboard
        ProfileSection("Portapapeles") {
            Button(
                onClick = {
                    val clipboard =
                        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    val text = appState.entries.joinToString("\n") {
                        "${it.title} - ${it.locationName}"
                    }
                    clipboard.setPrimaryClip(ClipData.newPlainText("Explorea", text))
                    Toast.makeText(context, "Copiado al portapapeles", Toast.LENGTH_SHORT).show()
                },
                colors = ButtonDefaults.buttonColors(containerColor = AppColors.Secondary),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.ContentCopy, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Copiar entradas al portapapeles")
            }
        }

        // Actions
        ProfileSection("Acciones") {
            OutlinedButton(
                onClick = {
                    Toast.makeText(context, "Datos exportados", Toast.LENGTH_SHORT).show()
                },
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(1.dp, AppColors.Primary),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.FileDownload, contentDescription = null, tint = AppColors.Primary)
                Spacer(Modifier.width(8.dp))
                Text("Exportar datos", color = AppColors.Primary)
            }
            Spacer(Modifier.height(8.dp))
            Button(
                onClick = onLogout,
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFE74C3C)),
                shape = RoundedCornerShape(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(Icons.Default.Logout, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Cerrar sesion")
            }
        }

        // About
        ProfileSection("Acerca de") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("Version", color = AppColors.LightText, fontSize = 14.sp)
                Text(
                    "v1.0.0",
                    color = AppColors.DarkText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium
                )
            }
            Spacer(Modifier.height(4.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("Plataforma", color = AppColors.LightText, fontSize = 14.sp)
                Text(
                    "Android",
                    color = AppColors.DarkText,
                    fontSize = 14.sp,
                    fontWeight = FontWeight.Medium
                )
            }
        }

        Spacer(Modifier.height(32.dp))
    }
}

@Composable
fun ProfileSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(
            title,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
            color = AppColors.LightText,
            modifier = Modifier.padding(bottom = 8.dp)
        )
        Card(
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = AppColors.White),
            elevation = CardDefaults.cardElevation(defaultElevation = 1.dp)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                content()
            }
        }
    }
}

@Composable
fun ProfileTextField(label: String, value: String, onValueChange: (String) -> Unit) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        label = { Text(label) },
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        shape = RoundedCornerShape(8.dp),
        singleLine = true,
        colors = OutlinedTextFieldDefaults.colors(
            focusedBorderColor = AppColors.Primary,
            unfocusedBorderColor = Color.LightGray
        )
    )
}

@Composable
fun ProfileToggle(
    label: String,
    icon: ImageVector,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = AppColors.Primary, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Text(label, fontSize = 15.sp, color = AppColors.DarkText, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = AppColors.White,
                checkedTrackColor = AppColors.Primary,
                uncheckedThumbColor = AppColors.White,
                uncheckedTrackColor = Color.LightGray
            )
        )
    }
}

@Composable
fun ProfileStat(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = AppColors.Primary)
        Text(label, fontSize = 12.sp, color = AppColors.LightText)
    }
}

// ─────────────────────────────────────────────────────
// Entry Detail View
// ─────────────────────────────────────────────────────
@Composable
fun EntryDetailView(
    entry: JournalEntry,
    appState: AppState,
    navController: NavHostController
) {
    val context = LocalContext.current
    var currentEntry by remember { mutableStateOf(entry) }

    LaunchedEffect(appState.entries) {
        appState.entries.find { it.id == entry.id }?.let { currentEntry = it }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
    ) {
        // Hero header
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(260.dp)
                .background(
                    Brush.linearGradient(
                        colors = listOf(
                            currentEntry.category.color,
                            currentEntry.category.color.copy(alpha = 0.7f),
                            currentEntry.category.color.copy(alpha = 0.4f)
                        ),
                        start = Offset(0f, 0f),
                        end = Offset(Float.POSITIVE_INFINITY, Float.POSITIVE_INFINITY)
                    )
                )
        ) {
            IconButton(
                onClick = { navController.popBackStack() },
                modifier = Modifier
                    .padding(start = 8.dp, top = 8.dp)
                    .align(Alignment.TopStart)
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Volver",
                    tint = Color.White
                )
            }

            Surface(
                modifier = Modifier
                    .padding(16.dp)
                    .align(Alignment.TopEnd),
                color = Color.White.copy(alpha = 0.25f),
                shape = RoundedCornerShape(8.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        currentEntry.category.icon,
                        contentDescription = null,
                        tint = Color.White,
                        modifier = Modifier.size(14.dp)
                    )
                    Text(
                        currentEntry.category.label,
                        color = Color.White,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }

            Text(
                moodEmojis.getOrElse(currentEntry.mood) { "\uD83D\uDE42" },
                fontSize = 48.sp,
                modifier = Modifier
                    .align(Alignment.Center)
                    .padding(top = 16.dp)
            )

            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .padding(16.dp)
            ) {
                Text(
                    currentEntry.title,
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                    color = Color.White
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    Icon(
                        Icons.Default.LocationOn,
                        contentDescription = null,
                        tint = Color.White.copy(alpha = 0.8f),
                        modifier = Modifier.size(14.dp)
                    )
                    Text(
                        currentEntry.locationName,
                        fontSize = 14.sp,
                        color = Color.White.copy(alpha = 0.8f)
                    )
                }
            }
        }

        // Date + mood
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.Default.CalendarToday,
                    contentDescription = null,
                    tint = AppColors.LightText,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(Modifier.width(4.dp))
                Text(formatDate(currentEntry.date), fontSize = 14.sp, color = AppColors.LightText)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Estado de animo: ", fontSize = 14.sp, color = AppColors.LightText)
                Text(moodEmojis.getOrElse(currentEntry.mood) { "\uD83D\uDE42" }, fontSize = 20.sp)
            }
        }

        HorizontalDivider(modifier = Modifier.padding(horizontal = 16.dp))

        if (currentEntry.description.isNotBlank()) {
            Text(
                currentEntry.description,
                fontSize = 15.sp,
                color = AppColors.DarkText,
                lineHeight = 24.sp,
                modifier = Modifier.padding(16.dp)
            )
        }

        // Map embed placeholder
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(150.dp)
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFFE8F5E9)),
            contentAlignment = Alignment.Center
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(
                    Icons.Default.Map,
                    contentDescription = null,
                    tint = AppColors.LightText,
                    modifier = Modifier.size(32.dp)
                )
                Text(currentEntry.locationName, fontSize = 12.sp, color = AppColors.LightText)
                Text(
                    "%.4f, %.4f".format(currentEntry.latitude, currentEntry.longitude),
                    fontSize = 10.sp,
                    color = AppColors.LightText.copy(alpha = 0.6f)
                )
            }
        }

        Spacer(Modifier.height(16.dp))

        // Action buttons
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            OutlinedButton(
                onClick = { appState.toggleFavorite(currentEntry.id) },
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(
                    1.dp,
                    if (currentEntry.isFavorite) AppColors.Primary else Color.LightGray
                ),
                modifier = Modifier.weight(1f)
            ) {
                Icon(
                    if (currentEntry.isFavorite) Icons.Default.Favorite
                    else Icons.Default.FavoriteBorder,
                    contentDescription = null,
                    tint = if (currentEntry.isFavorite) AppColors.Primary else AppColors.LightText
                )
                Spacer(Modifier.width(4.dp))
                Text(
                    if (currentEntry.isFavorite) "Favorito" else "Agregar",
                    color = if (currentEntry.isFavorite) AppColors.Primary else AppColors.LightText
                )
            }

            OutlinedButton(
                onClick = {
                    val clipboard =
                        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                    clipboard.setPrimaryClip(
                        ClipData.newPlainText(
                            "Explorea",
                            "${currentEntry.title}\n${currentEntry.locationName}\n${currentEntry.description}"
                        )
                    )
                    Toast.makeText(context, "Copiado", Toast.LENGTH_SHORT).show()
                },
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(1.dp, Color.LightGray),
                modifier = Modifier.weight(1f)
            ) {
                Icon(
                    Icons.Default.ContentCopy,
                    contentDescription = null,
                    tint = AppColors.LightText
                )
                Spacer(Modifier.width(4.dp))
                Text("Copiar", color = AppColors.LightText)
            }

            OutlinedButton(
                onClick = {
                    appState.deleteEntry(currentEntry.id)
                    navController.popBackStack()
                },
                shape = RoundedCornerShape(12.dp),
                border = BorderStroke(1.dp, Color(0xFFE74C3C)),
                modifier = Modifier.weight(1f)
            ) {
                Icon(
                    Icons.Default.Delete,
                    contentDescription = null,
                    tint = Color(0xFFE74C3C)
                )
                Spacer(Modifier.width(4.dp))
                Text("Eliminar", color = Color(0xFFE74C3C))
            }
        }

        Spacer(Modifier.height(32.dp))
    }
}

// ─────────────────────────────────────────────────────
// New Entry View
// ─────────────────────────────────────────────────────
@Composable
fun NewEntryView(appState: AppState, navController: NavHostController) {
    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var selectedCategory by remember { mutableStateOf(TravelCategory.ADVENTURE) }
    var locationName by remember { mutableStateOf("") }
    var mood by remember { mutableFloatStateOf(3f) }
    var isFavorite by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
    ) {
        // Top bar
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(Brush.horizontalGradient(AppColors.HeaderGradient))
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            IconButton(onClick = { navController.popBackStack() }) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Volver",
                    tint = Color.White
                )
            }
            Text(
                "Nueva entrada",
                fontSize = 20.sp,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                modifier = Modifier.weight(1f)
            )
            TextButton(onClick = {
                if (title.isNotBlank()) {
                    appState.addEntry(
                        JournalEntry(
                            title = title,
                            description = description,
                            category = selectedCategory,
                            mood = mood.toInt(),
                            isFavorite = isFavorite,
                            locationName = locationName.ifBlank { "Sin ubicacion" }
                        )
                    )
                    navController.popBackStack()
                }
            }) {
                Text("Guardar", color = Color.White, fontWeight = FontWeight.SemiBold)
            }
        }

        Spacer(Modifier.height(16.dp))

        // Photo section
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = AppColors.White)
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(
                    "Fotos",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AppColors.DarkText
                )
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedButton(
                        onClick = { },
                        shape = RoundedCornerShape(8.dp),
                        border = BorderStroke(1.dp, AppColors.Primary)
                    ) {
                        Icon(
                            Icons.Default.CameraAlt,
                            contentDescription = null,
                            tint = AppColors.Primary
                        )
                        Spacer(Modifier.width(4.dp))
                        Text("Camara", color = AppColors.Primary)
                    }
                    OutlinedButton(
                        onClick = { },
                        shape = RoundedCornerShape(8.dp),
                        border = BorderStroke(1.dp, AppColors.Primary)
                    ) {
                        Icon(
                            Icons.Default.PhotoLibrary,
                            contentDescription = null,
                            tint = AppColors.Primary
                        )
                        Spacer(Modifier.width(4.dp))
                        Text("Galeria", color = AppColors.Primary)
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        // Title
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            label = { Text("Titulo") },
            placeholder = { Text("Nombre de tu viaje") },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            shape = RoundedCornerShape(12.dp),
            singleLine = true,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = AppColors.Primary,
                unfocusedBorderColor = Color.LightGray
            )
        )

        Spacer(Modifier.height(12.dp))

        // Description
        OutlinedTextField(
            value = description,
            onValueChange = { description = it },
            label = { Text("Descripcion") },
            placeholder = { Text("Cuenta tu experiencia...") },
            modifier = Modifier
                .fillMaxWidth()
                .height(120.dp)
                .padding(horizontal = 16.dp),
            shape = RoundedCornerShape(12.dp),
            maxLines = 5,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = AppColors.Primary,
                unfocusedBorderColor = Color.LightGray
            )
        )

        Spacer(Modifier.height(16.dp))

        // Category grid
        Text(
            "Categoria",
            fontSize = 15.sp,
            fontWeight = FontWeight.SemiBold,
            color = AppColors.DarkText,
            modifier = Modifier.padding(horizontal = 16.dp)
        )
        Spacer(Modifier.height(8.dp))
        LazyVerticalGrid(
            columns = GridCells.Fixed(4),
            modifier = Modifier
                .fillMaxWidth()
                .height(180.dp)
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            items(TravelCategory.entries) { category ->
                val isSelected = selectedCategory == category
                Column(
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .background(
                            if (isSelected) category.color.copy(alpha = 0.2f)
                            else Color(0xFFF5F5F5)
                        )
                        .border(
                            width = if (isSelected) 2.dp else 0.dp,
                            color = if (isSelected) category.color else Color.Transparent,
                            shape = RoundedCornerShape(12.dp)
                        )
                        .clickable { selectedCategory = category }
                        .padding(vertical = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Icon(
                        category.icon,
                        contentDescription = null,
                        tint = if (isSelected) category.color else AppColors.LightText,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        category.label,
                        fontSize = 10.sp,
                        color = if (isSelected) category.color else AppColors.LightText,
                        textAlign = TextAlign.Center,
                        maxLines = 1
                    )
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        // Location
        OutlinedTextField(
            value = locationName,
            onValueChange = { locationName = it },
            label = { Text("Ubicacion") },
            placeholder = { Text("Ciudad, Pais") },
            leadingIcon = { Icon(Icons.Default.LocationOn, contentDescription = null) },
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp),
            shape = RoundedCornerShape(12.dp),
            singleLine = true,
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = AppColors.Primary,
                unfocusedBorderColor = Color.LightGray
            )
        )

        Spacer(Modifier.height(16.dp))

        // Mood slider
        Column(modifier = Modifier.padding(horizontal = 16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    "Estado de animo",
                    fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = AppColors.DarkText
                )
                Text(moodEmojis.getOrElse(mood.toInt()) { "\uD83D\uDE42" }, fontSize = 24.sp)
            }
            Slider(
                value = mood,
                onValueChange = { mood = it },
                valueRange = 0f..5f,
                steps = 4,
                colors = SliderDefaults.colors(
                    thumbColor = AppColors.Primary,
                    activeTrackColor = AppColors.Primary
                )
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text("\uD83D\uDE34", fontSize = 16.sp)
                Text("\uD83E\uDD29", fontSize = 16.sp)
            }
        }

        Spacer(Modifier.height(12.dp))

        // Favorite toggle
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(AppColors.White)
                .clickable { isFavorite = !isFavorite }
                .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                if (isFavorite) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                contentDescription = null,
                tint = if (isFavorite) AppColors.Primary else AppColors.LightText,
                modifier = Modifier.size(24.dp)
            )
            Spacer(Modifier.width(12.dp))
            Text(
                "Marcar como favorito",
                fontSize = 15.sp,
                color = AppColors.DarkText,
                modifier = Modifier.weight(1f)
            )
            Switch(
                checked = isFavorite,
                onCheckedChange = { isFavorite = it },
                colors = SwitchDefaults.colors(
                    checkedThumbColor = AppColors.White,
                    checkedTrackColor = AppColors.Primary
                )
            )
        }

        Spacer(Modifier.height(32.dp))
    }
}
