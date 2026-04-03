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

    /** Swipe de (x1,y1) a (x2,y2) en durationMs milisegundos. */
    fun swipe(x1: Int, y1: Int, x2: Int, y2: Int, durationMs: Long = 300) {
        val steps = 20
        val now = SystemClock.uptimeMillis()
        val stepDuration = durationMs / steps

        // Down
        inject(MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, x1.toFloat(), y1.toFloat(), 0))

        // Move
        for (i in 1..steps) {
            val fraction = i.toFloat() / steps
            val x = x1 + ((x2 - x1) * fraction).toInt()
            val y = y1 + ((y2 - y1) * fraction).toInt()
            val time = now + stepDuration * i
            Thread.sleep(stepDuration)
            inject(MotionEvent.obtain(now, time, MotionEvent.ACTION_MOVE, x.toFloat(), y.toFloat(), 0))
        }

        // Up
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

    private fun inject(event: InputEvent) {
        uiAutomation.injectInputEvent(event, true) // true = sync
        if (event is MotionEvent) event.recycle()
    }
}
