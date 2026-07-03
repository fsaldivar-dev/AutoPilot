package dev.autopilot.agent

import android.app.UiAutomation
import android.os.SystemClock
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent

/**
 * Inyecta eventos de input via UiAutomation.injectInputEvent().
 *
 * Latencia: 1-3ms por evento (vs ~200ms con adb shell input).
 */
class InputInjector(private val uiAutomation: UiAutomation) {

    /** Tap en coordenadas absolutas. */
    fun tap(x: Int, y: Int) {
        val now = SystemClock.uptimeMillis()
        inject(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x.toFloat(), y.toFloat(), 0))
        inject(MotionEvent.obtain(now, now + 50, MotionEvent.ACTION_UP, x.toFloat(), y.toFloat(), 0))
    }

    /** Long press en coordenadas por duration milisegundos. */
    fun longPress(x: Int, y: Int, durationMs: Long) {
        val now = SystemClock.uptimeMillis()
        inject(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x.toFloat(), y.toFloat(), 0))
        Thread.sleep(durationMs)
        inject(MotionEvent.obtain(now, now + durationMs, MotionEvent.ACTION_UP, x.toFloat(), y.toFloat(), 0))
    }

    /** Double tap. */
    fun doubleTap(x: Int, y: Int) {
        tap(x, y)
        Thread.sleep(100)
        tap(x, y)
    }

    /**
     * Swipe de (x1,y1) a (x2,y2) en durationMs milisegundos.
     *
     * Pacing (#168): el coste real de un swipe no es solo el `durationMs` del gesto,
     * sino el overhead de cada `injectInputEvent(event, true)` (sincrono: bloquea hasta
     * que el evento se despacha). Con 20 MOVEs (22 injects sync + 20 sleeps) el swipe
     * tardaba ~685ms — 1.8x mas lento que `adb input swipe` (~370ms).
     *
     * Optimizacion (#168): el grueso del wall-clock eran los injects SINCRONOS.
     * `injectInputEvent(event, true)` bloquea ~23ms/evento hasta que se despacha;
     * con 12 injects (DOWN + 10 MOVE + UP) son ~276ms de puro bloqueo, mas los
     * sleeps. Pero los MOVE intermedios NO necesitan ser sincronos: UiAutomation
     * los encola y la velocidad que ve el VelocityTracker la dan los TIMESTAMPS
     * del MotionEvent (de `now` a `now+durationMs`), no el tiempo real de inyeccion.
     * Inyectamos los MOVE async (sync=false) y solo DOWN/UP sincronos para
     * bracketear el gesto. Los sleeps mantienen un espaciado real minimo para que
     * el input system no colapse la secuencia. Resultado: ~150ms vs ~450ms, sin
     * degradar el gesto (sigue siendo swipe reconocible, no tap ni fling).
     */
    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long = 150) {
        val steps = 10
        val now = SystemClock.uptimeMillis()
        val stepDuration = durationMs / steps

        // Down (sync: abre el gesto)
        inject(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x1.toFloat(), y1.toFloat(), 0))

        // Move (async: encolados; el timestamp lleva la velocidad, no el wall-clock)
        for (i in 1..steps) {
            val fraction = i.toFloat() / steps
            val x = x1 + ((x2 - x1) * fraction).toInt()
            val y = y1 + ((y2 - y1) * fraction).toInt()
            val time = now + stepDuration * i
            if (stepDuration > 0) Thread.sleep(stepDuration)
            inject(MotionEvent.obtain(now, time, MotionEvent.ACTION_MOVE, x.toFloat(), y.toFloat(), 0), sync = false)
        }

        // Up (sync: cierra el gesto y garantiza que se despacho antes de responder)
        val endTime = now + durationMs
        inject(MotionEvent.obtain(now, endTime, MotionEvent.ACTION_UP, x2.toFloat(), y2.toFloat(), 0))
    }

    /** Key event (BACK, HOME, ENTER, etc). */
    fun keyEvent(keyCode: Int) {
        val now = SystemClock.uptimeMillis()
        inject(KeyEvent(now, now, KeyEvent.ACTION_DOWN, keyCode, 0))
        inject(KeyEvent(now, now, KeyEvent.ACTION_UP, keyCode, 0))
    }

    /** Escribe texto caracter por caracter via key events. */
    fun typeText(text: String) {
        val kcm = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
        val events = kcm.getEvents(text.toCharArray())
        if (events != null) {
            for (event in events) {
                inject(event)
            }
        }
    }

    private fun inject(event: InputEvent, sync: Boolean = true) {
        uiAutomation.injectInputEvent(event, sync)
        if (event is MotionEvent) event.recycle()
    }
}
