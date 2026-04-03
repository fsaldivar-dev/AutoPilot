package dev.autopilot.agent

import android.graphics.Rect
import android.view.accessibility.AccessibilityNodeInfo
import org.json.JSONArray
import org.json.JSONObject

/**
 * Serializa AccessibilityNodeInfo a JSON compatible con TreePrinter de AutoPilot.
 *
 * Formato de salida (mismas keys que UIAutomatorParser en Swift):
 * {
 *   "role": "TextView",
 *   "title": "Explorea",
 *   "label": "",
 *   "identifier": "com.app:id/title",
 *   "frame": {"x": 423, "y": 1359, "width": 434, "height": 126},
 *   "clickable": false,
 *   "enabled": true,
 *   "children": [...]
 * }
 */
object TreeSerializer {

    fun serialize(root: AccessibilityNodeInfo?): JSONArray {
        val result = JSONArray()
        if (root != null) {
            result.put(serializeNode(root))
        }
        return result
    }

    private fun serializeNode(node: AccessibilityNodeInfo): JSONObject {
        val obj = JSONObject()

        // role — class name sin package prefix
        val className = node.className?.toString() ?: ""
        obj.put("role", stripPackagePrefix(className))

        // title — text content
        obj.put("title", node.text?.toString() ?: "")

        // label — content description (accessibility)
        obj.put("label", node.contentDescription?.toString() ?: "")

        // identifier — resource id
        obj.put("identifier", node.viewIdResourceName ?: "")

        // value — same as title for compatibility
        obj.put("value", node.text?.toString() ?: "")

        // state
        obj.put("enabled", node.isEnabled)
        obj.put("clickable", node.isClickable)
        obj.put("scrollable", node.isScrollable)
        obj.put("focused", node.isFocused)
        obj.put("package", node.packageName?.toString() ?: "")

        // frame — bounds as {x, y, width, height}
        val bounds = Rect()
        node.getBoundsInScreen(bounds)
        val frame = JSONObject()
        frame.put("x", bounds.left)
        frame.put("y", bounds.top)
        frame.put("width", bounds.width())
        frame.put("height", bounds.height())
        obj.put("frame", frame)

        // children — recursive
        val children = JSONArray()
        for (i in 0 until node.childCount) {
            val child = node.getChild(i)
            if (child != null) {
                children.put(serializeNode(child))
                child.recycle()
            }
        }
        obj.put("children", children)

        return obj
    }

    /** "android.widget.TextView" → "TextView" */
    private fun stripPackagePrefix(className: String): String {
        val lastDot = className.lastIndexOf('.')
        return if (lastDot >= 0) className.substring(lastDot + 1) else className
    }
}
