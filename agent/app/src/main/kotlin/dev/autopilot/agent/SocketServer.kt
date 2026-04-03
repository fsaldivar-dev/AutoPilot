package dev.autopilot.agent

import android.app.UiAutomation
import android.graphics.Rect
import android.net.LocalServerSocket
import android.net.LocalSocket
import android.os.Build
import android.util.Log
import android.view.KeyEvent as AndroidKeyEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.io.PrintWriter

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
class SocketServer(private val uiAutomation: UiAutomation) {

    companion object {
        const val TAG = "AutoPilot"
        const val SOCKET_NAME = "autopilot"
    }

    private val input = InputInjector(uiAutomation)

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
        val root = uiAutomation.rootInActiveWindow
            ?: return errorResponse("No active window")

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
        val direction = params?.optString("direction", "") ?: return errorResponse("Missing direction")

        // Get screen size from root window bounds
        val root = uiAutomation.rootInActiveWindow ?: return errorResponse("No active window")
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

    // ── Helpers ──────────────────────────────────────────

    /** Busca un nodo por text, content-desc, o resource-id. Recursivo. */
    private fun findNode(query: String): AccessibilityNodeInfo? {
        val root = uiAutomation.rootInActiveWindow ?: return null
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
