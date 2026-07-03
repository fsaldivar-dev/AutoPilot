package dev.autopilot.agent

import android.app.UiAutomation
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Rect
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import android.view.KeyEvent as AndroidKeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Servidor de comandos sobre LocalSocket.
 *
 * Acepta conexiones en el socket abstracto "autopilot".
 * Desde el host: adb forward tcp:9008 localabstract:autopilot
 *
 * Protocolo: una línea JSON por request, una línea JSON por response.
 *   → {"method": "ping"}
 *   ← {"result": "pong", "api": 36}
 *
 *   → {"method": "tree"}
 *   ← {"result": [{...tree...}]}
 */
class SocketServer(
    private val uiAutomation: UiAutomation,
    private val context: Context
) {

    companion object {
        const val TAG = "AutoPilot"
        const val SOCKET_NAME = "autopilot"
    }

    private val input = InputInjector(uiAutomation)

    // Clipboard cache (Android 10+ restricts background clipboard read)
    private var lastClipboardText: String? = null

    // Camera mock state
    private var cameraActive = false
    private var cameraImagePath: String? = null
    private val cameraDir: String by lazy {
        context.filesDir.absolutePath
    }

    fun start() {
        val server = LocalServerSocket(SOCKET_NAME)
        Log.i(TAG, "Socket server listening on localabstract:$SOCKET_NAME")

        while (true) {
            val client = server.accept()
            Log.i(TAG, "Client connected")
            try {
                handleClient(client)
            } catch (e: Exception) {
                Log.e(TAG, "Client error: ${e.message}")
            }
            Log.i(TAG, "Client disconnected")
        }
    }

    private fun handleClient(client: LocalSocket) {
        val reader = BufferedReader(InputStreamReader(client.inputStream))
        val writer = PrintWriter(OutputStreamWriter(client.outputStream), true)

        var line = reader.readLine()
        while (line != null) {
            val response = handleCommand(line)
            writer.println(response)
            line = reader.readLine()
        }

        client.close()
    }

    private fun handleCommand(line: String): String {
        return try {
            val request = JSONObject(line)
            val method = request.optString("method", "")
            val startTime = System.currentTimeMillis()

            val params = request.optJSONObject("params")

            val result = when (method) {
                "ping" -> handlePing()
                "tree" -> handleTree()
                "tap" -> handleTap(params)
                "tapAt" -> handleTapAt(params)
                "longPress" -> handleLongPress(params)
                "doubleTap" -> handleDoubleTap(params)
                "type" -> handleType(params)
                "swipe" -> handleSwipe(params)
                "keyevent" -> handleKeyEvent(params)
                "clear" -> handleClear(params)
                "getClipboard" -> handleGetClipboard()
                "setClipboard" -> handleSetClipboard(params)
                "camera" -> handleCamera(params)
                else -> errorResponse("Unknown method: $method")
            }

            val elapsed = System.currentTimeMillis() - startTime
            Log.d(TAG, "$method → ${elapsed}ms")
            result
        } catch (e: Exception) {
            errorResponse("Parse error: ${e.message}")
        }
    }

    private fun handlePing(): String {
        val result = JSONObject()
        result.put("result", "pong")
        result.put("api", Build.VERSION.SDK_INT)
        result.put("device", Build.MODEL)
        result.put("android", Build.VERSION.RELEASE)
        return result.toString()
    }

    private fun handleTree(): String {
        val root = getRoot()
            ?: return errorResponse("No active window — is an app open? Try restarting the agent.")

        val tree = TreeSerializer.serialize(root)
        root.recycle()

        val response = JSONObject()
        response.put("result", tree)
        return response.toString()
    }

    // ── Tap by text/label/id ────────────────────────────

    private fun handleTap(params: JSONObject?): String {
        val target = params?.optString("target", "") ?: return errorResponse("Missing target")
        if (target.isEmpty()) return errorResponse("Empty target")

        val node = findNode(target) ?: return errorResponse("Element not found: '$target'")
        val center = centerOf(node)
        node.recycle()

        input.tap(center.first, center.second)
        return successResponse("x" to center.first, "y" to center.second)
    }

    private fun handleTapAt(params: JSONObject?): String {
        val x = params?.optInt("x", -1) ?: return errorResponse("Missing x")
        val y = params?.optInt("y", -1) ?: return errorResponse("Missing y")
        if (x < 0 || y < 0) return errorResponse("Invalid coordinates")

        input.tap(x, y)
        return successResponse("x" to x, "y" to y)
    }

    private fun handleLongPress(params: JSONObject?): String {
        val target = params?.optString("target", "") ?: return errorResponse("Missing target")
        val duration = params.optLong("duration", 1000)

        val node = findNode(target) ?: return errorResponse("Element not found: '$target'")
        val center = centerOf(node)
        node.recycle()

        input.longPress(center.first, center.second, duration)
        return successResponse("x" to center.first, "y" to center.second)
    }

    private fun handleDoubleTap(params: JSONObject?): String {
        val target = params?.optString("target", "") ?: return errorResponse("Missing target")

        val node = findNode(target) ?: return errorResponse("Element not found: '$target'")
        val center = centerOf(node)
        node.recycle()

        input.doubleTap(center.first, center.second)
        return successResponse("x" to center.first, "y" to center.second)
    }

    // ── Type ─────────────────────────────────────────────

    private fun handleType(params: JSONObject?): String {
        val text = params?.optString("text", "") ?: return errorResponse("Missing text")
        if (text.isEmpty()) return errorResponse("Empty text")

        input.typeText(text)
        return successResponse("typed" to text.length)
    }

    // ── Swipe ────────────────────────────────────────────

    private fun handleSwipe(params: JSONObject?): String {
        // Dos formas del mensaje, mutuamente excluyentes:
        //   {direction}              — swipe direccional de pantalla completa
        //   {x1,y1,x2,y2[,duration]} — swipe entre coordenadas; la usan
        //                              `scroll <elem> <dir>` y `drag` (AgentBridge)
        if (params == null) return errorResponse("Missing params: direction or x1,y1,x2,y2")

        val hasDirection = params.optString("direction", "").isNotEmpty()
        val coordKeys = listOf("x1", "y1", "x2", "y2")
        val presentCoords = coordKeys.filter { params.has(it) }

        if (hasDirection && presentCoords.isNotEmpty()) {
            return errorResponse("Ambiguous swipe: send either direction or x1,y1,x2,y2, not both")
        }

        if (presentCoords.isNotEmpty()) {
            if (presentCoords.size < coordKeys.size) {
                return errorResponse("Swipe coordinates require all of x1,y1,x2,y2 (got: $presentCoords)")
            }
            // Clamp a >= 0: elementos parcialmente fuera de pantalla producen
            // bounds negativos en boundsInScreen — clampear, no rechazar
            val x1 = params.optInt("x1").coerceAtLeast(0)
            val y1 = params.optInt("y1").coerceAtLeast(0)
            val x2 = params.optInt("x2").coerceAtLeast(0)
            val y2 = params.optInt("y2").coerceAtLeast(0)
            val duration = params.optLong("duration", 300L).coerceIn(1L, 60_000L)
            input.swipe(x1, y1, x2, y2, duration)
            return successResponse("from" to "$x1,$y1", "to" to "$x2,$y2")
        }

        val direction = params.optString("direction", "")
        if (direction.isEmpty()) return errorResponse("Missing direction or coordinates")

        // Get screen size from root window bounds
        val root = getRoot() ?: return errorResponse("No active window")
        val bounds = Rect()
        root.getBoundsInScreen(bounds)
        root.recycle()

        val cx = bounds.centerX()
        val cy = bounds.centerY()
        val dx = bounds.width() * 40 / 100
        val dy = bounds.height() * 40 / 100

        when (direction.lowercase()) {
            "up" -> input.swipe(cx, cy + dy / 2, cx, cy - dy / 2)
            "down" -> input.swipe(cx, cy - dy / 2, cx, cy + dy / 2)
            "left" -> input.swipe(cx + dx / 2, cy, cx - dx / 2, cy)
            "right" -> input.swipe(cx - dx / 2, cy, cx + dx / 2, cy)
            else -> return errorResponse("Invalid direction: $direction. Use up/down/left/right")
        }
        return successResponse("direction" to direction)
    }

    // ── Key event ────────────────────────────────────────

    private fun handleKeyEvent(params: JSONObject?): String {
        val key = params?.optString("key", "") ?: return errorResponse("Missing key")
        val keyCode = when (key.lowercase()) {
            "back" -> AndroidKeyEvent.KEYCODE_BACK
            "home" -> AndroidKeyEvent.KEYCODE_HOME
            "enter" -> AndroidKeyEvent.KEYCODE_ENTER
            "delete", "del" -> AndroidKeyEvent.KEYCODE_DEL
            "tab" -> AndroidKeyEvent.KEYCODE_TAB
            else -> key.toIntOrNull() ?: return errorResponse("Unknown key: $key")
        }
        input.keyEvent(keyCode)
        return successResponse("key" to key)
    }

    // ── Clear ────────────────────────────────────────────

    private fun handleClear(params: JSONObject?): String {
        val target = params?.optString("target", "") ?: return errorResponse("Missing target")

        val node = findNode(target) ?: return errorResponse("Element not found: '$target'")
        val center = centerOf(node)

        // Get current text length
        val textLen = node.text?.length ?: 0
        node.recycle()

        // Tap to focus
        input.tap(center.first, center.second)
        Thread.sleep(100)

        // Move to end + delete all
        input.keyEvent(AndroidKeyEvent.KEYCODE_MOVE_END)
        for (i in 0 until textLen) {
            input.keyEvent(AndroidKeyEvent.KEYCODE_DEL)
        }
        return successResponse("cleared" to textLen)
    }

    // ── Clipboard ────────────────────────────────────

    private fun handleSetClipboard(params: JSONObject?): String {
        val text = params?.optString("text", "") ?: return errorResponse("Missing text")
        if (text.isEmpty()) return errorResponse("Empty text")

        val latch = CountDownLatch(1)
        var error: String? = null

        Handler(Looper.getMainLooper()).post {
            try {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("autopilot", text))
            } catch (e: Exception) {
                error = e.message
            }
            latch.countDown()
        }

        latch.await(3, TimeUnit.SECONDS)
        return if (error != null) {
            errorResponse("Clipboard write failed: $error")
        } else {
            lastClipboardText = text
            successResponse("text" to text)
        }
    }

    private fun handleGetClipboard(): String {
        // Android 10+ restricts clipboard read for non-foreground apps.
        // Strategy: try ClipboardManager first, fallback to cached value.
        val latch = CountDownLatch(1)
        var clipText: String? = null

        Handler(Looper.getMainLooper()).post {
            try {
                val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clipText = cm.primaryClip?.getItemAt(0)?.text?.toString()
            } catch (_: Exception) {}
            latch.countDown()
        }

        latch.await(3, TimeUnit.SECONDS)

        // Use ClipboardManager result if available, otherwise return cached value
        val text = clipText ?: lastClipboardText ?: ""
        val response = JSONObject()
        response.put("result", text)
        return response.toString()
    }

    // ── Camera mock ─────────────────────────────────

    private fun handleCamera(params: JSONObject?): String {
        val action = params?.optString("action", "") ?: return errorResponse("Missing action")

        return when (action) {
            "start" -> cameraStart(params)
            "feed" -> cameraFeed(params)
            "stop" -> cameraStop()
            "status" -> cameraStatus()
            else -> errorResponse("Unknown camera action: $action. Use start/feed/stop/status")
        }
    }

    private fun cameraStart(params: JSONObject?): String {
        val imageBase64 = params?.optString("image", "")
        if (imageBase64.isNullOrEmpty()) return errorResponse("Missing image (base64)")

        val path = "$cameraDir/autopilot-camera.jpg"
        return try {
            val bytes = Base64.decode(imageBase64, Base64.DEFAULT)
            File(path).writeBytes(bytes)
            cameraActive = true
            cameraImagePath = path
            successResponse("active" to true, "path" to path)
        } catch (e: Exception) {
            errorResponse("Camera start failed: ${e.message}")
        }
    }

    private fun cameraFeed(params: JSONObject?): String {
        if (!cameraActive) return errorResponse("Camera not active. Call start first.")

        val imageBase64 = params?.optString("image", "")
        if (imageBase64.isNullOrEmpty()) return errorResponse("Missing image (base64)")

        val path = cameraImagePath ?: return errorResponse("No camera path")
        return try {
            val bytes = Base64.decode(imageBase64, Base64.DEFAULT)
            File(path).writeBytes(bytes)
            successResponse("active" to true, "path" to path)
        } catch (e: Exception) {
            errorResponse("Camera feed failed: ${e.message}")
        }
    }

    private fun cameraStop(): String {
        cameraActive = false
        if (cameraImagePath != null) {
            val file = File(cameraImagePath!!)
            if (file.exists()) file.delete()
        }
        cameraImagePath = null
        return successResponse("active" to false)
    }

    private fun cameraStatus(): String {
        val result = JSONObject()
        val status = JSONObject()
        status.put("active", cameraActive)
        status.put("path", cameraImagePath ?: JSONObject.NULL)
        if (cameraActive && cameraImagePath != null) {
            val file = File(cameraImagePath!!)
            status.put("size", if (file.exists()) file.length() else 0)
        }
        result.put("result", status)
        return result.toString()
    }

    // ── Helpers ──────────────────────────────────────────

    /** Gets rootInActiveWindow with retries (UiAutomation can temporarily lose connection). */
    private fun getRoot(): AccessibilityNodeInfo? {
        for (i in 0 until 5) {
            val root = uiAutomation.rootInActiveWindow
            if (root != null) return root
            Thread.sleep(200)
        }
        return null
    }

    /** Busca un nodo por text, content-desc, o resource-id. Recursivo. */
    private fun findNode(query: String): AccessibilityNodeInfo? {
        val root = getRoot() ?: return null
        val q = query.lowercase()

        // First pass: exact match
        val exact = findRecursive(root, q, exact = true)
        if (exact != null) {
            root.recycle()
            return exact
        }

        // Second pass: contains match
        val contains = findRecursive(root, q, exact = false)
        if (contains != null) {
            root.recycle()
            return contains
        }

        root.recycle()
        return null
    }

    private fun findRecursive(node: AccessibilityNodeInfo, query: String, exact: Boolean): AccessibilityNodeInfo? {
        val text = node.text?.toString()?.lowercase() ?: ""
        val desc = node.contentDescription?.toString()?.lowercase() ?: ""
        val resId = node.viewIdResourceName?.lowercase() ?: ""

        val matches = if (exact) {
            text == query || desc == query || resId == query
        } else {
            text.contains(query) || desc.contains(query) || resId.contains(query)
        }

        if (matches) {
            return AccessibilityNodeInfo.obtain(node)
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findRecursive(child, query, exact)
            child.recycle()
            if (found != null) return found
        }

        return null
    }

    /** Centro de un nodo en coordenadas de pantalla. */
    private fun centerOf(node: AccessibilityNodeInfo): Pair<Int, Int> {
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        return Pair(bounds.centerX(), bounds.centerY())
    }

    private fun successResponse(vararg pairs: Pair<String, Any>): String {
        val result = JSONObject()
        result.put("success", true)
        for ((key, value) in pairs) {
            result.put(key, value)
        }
        val response = JSONObject()
        response.put("result", result)
        return response.toString()
    }

    private fun errorResponse(message: String): String {
        val response = JSONObject()
        response.put("error", message)
        return response.toString()
    }
}
