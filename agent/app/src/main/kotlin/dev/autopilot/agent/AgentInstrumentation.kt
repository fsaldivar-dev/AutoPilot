package dev.autopilot.agent

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.Instrumentation
import android.app.UiAutomation
import android.os.Bundle
import android.util.Log

/**
 * Entry point del agente AutoPilot.
 *
 * Se lanza con:
 *   adb shell am instrument -w dev.autopilot.agent/.AgentInstrumentation
 *
 * Obtiene UiAutomation (system-wide) y abre un LocalServerSocket
 * que acepta comandos JSON y responde con datos de la UI.
 */
class AgentInstrumentation : Instrumentation() {

    companion object {
        const val TAG = "AutoPilot"
    }

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        Log.i(TAG, "Agent starting...")
        start() // lanza onStart() en thread separado
    }

    override fun onStart() {
        val uiAutomation: UiAutomation = uiAutomation
        Log.i(TAG, "UiAutomation acquired")

        // Sin FLAG_RETRIEVE_INTERACTIVE_WINDOWS, uiAutomation.windows devuelve
        // una lista vacía y las ventanas IME/overlay son invisibles (issue #130).
        try {
            val info = uiAutomation.serviceInfo ?: AccessibilityServiceInfo()
            info.flags = info.flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            uiAutomation.serviceInfo = info
            Log.i(TAG, "FLAG_RETRIEVE_INTERACTIVE_WINDOWS enabled")
        } catch (e: Exception) {
            Log.w(TAG, "Could not enable interactive windows: ${e.message}")
        }

        val server = SocketServer(uiAutomation, targetContext)
        try {
            server.start() // bloquea indefinidamente
        } catch (e: Exception) {
            Log.e(TAG, "Server error: ${e.message}", e)
        }

        // Si llegamos aquí, el server se detuvo
        finish(0, Bundle())
    }
}
