package dev.autopilot.cameramock

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.lang.ref.WeakReference
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import android.media.ImageReader
import java.nio.ByteBuffer

/**
 * Intercepts Camera2 API capture output, covering both raw Camera2 and CameraX.
 *
 * Strategy (proven by VCAM Xposed module):
 * 1. Track ImageReader instances by hooking setOnImageAvailableListener via reflection
 * 2. Wrap the listener to intercept onImageAvailable callbacks
 * 3. When the app acquires an Image, we replace the buffer contents with our mock data
 *
 * For CameraX apps: CameraX internally uses Camera2 + ImageReader, so this
 * interceptor covers CameraX ImageCapture.takePicture() automatically.
 *
 * Key insight: ImageProxy (CameraX) wraps android.media.Image (Camera2).
 * By intercepting at the Image/ImageReader level, we cover both APIs.
 */
object Camera2Interceptor {
    private const val TAG = "AutoPilotCamera"
    private val handler = Handler(Looper.getMainLooper())

    // Tracked ImageReaders (weak references to avoid leaks)
    private val trackedReaders = mutableListOf<WeakReference<Any>>()

    // Original listeners keyed by ImageReader identity hash
    private val originalListeners = mutableMapOf<Int, Any>()

    // Cached ImageCapture instance for faster callback scanning
    @Volatile private var cachedImageCapture: WeakReference<Any>? = null

    fun install() {
        try {
            Log.d(TAG, "Camera2Interceptor: installing hooks")
            startListenerScanner()
        } catch (e: Exception) {
            Log.e(TAG, "Camera2Interceptor install failed", e)
        }
    }

    // Track whether we've found and wrapped at least one listener
    @Volatile private var hasWrappedListener = false

    /**
     * Periodically scan for ImageReader instances and wrap their listeners.
     * Scans every 2s until an ImageReader is found, then every 10s for new ones.
     */
    private fun startListenerScanner() {
        Thread {
            while (true) {
                try {
                    Thread.sleep(if (hasWrappedListener) 10_000 else 2_000)
                    scanAndWrapListeners()
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.w(TAG, "Camera2Interceptor scan error: ${e.message}")
                }
            }
        }.apply {
            isDaemon = true
            name = "autopilot-camera2-scanner"
        }.start()
    }

    /**
     * Find ImageReader instances in the current app and wrap their listeners.
     *
     * Approach: scan ProcessCameraProvider's bound use cases to find ImageCapture's
     * internal ImageReader. Also scan via ImageReader's static tracking if available.
     */
    private fun scanAndWrapListeners() {
        try {
            val irClass = Class.forName("android.media.ImageReader")
            val listenerField = irClass.getDeclaredField("mListener")
            listenerField.isAccessible = true

            // Try to find ImageReaders via CameraX's ProcessCameraProvider
            findCameraXImageReaders()?.forEach { reader ->
                wrapListener(reader, irClass, listenerField)
            }

            // Also check any previously tracked readers
            val iter = trackedReaders.iterator()
            while (iter.hasNext()) {
                val reader = iter.next().get()
                if (reader == null) {
                    iter.remove()
                    continue
                }
                wrapListener(reader, irClass, listenerField)
            }
        } catch (e: Exception) {
            // Expected on first few attempts while camera initializes
        }
    }

    /**
     * Wrap the OnImageAvailableListener on an ImageReader with our interceptor.
     */
    private fun wrapListener(reader: Any, irClass: Class<*>, listenerField: java.lang.reflect.Field) {
        val readerId = System.identityHashCode(reader)

        // Skip if already wrapped
        if (originalListeners.containsKey(readerId)) return

        val currentListener = listenerField.get(reader) ?: return

        // Check if it's already our proxy
        if (Proxy.isProxyClass(currentListener.javaClass)) return

        // Store original listener
        originalListeners[readerId] = currentListener

        // Create wrapper that intercepts the image
        val listenerInterface = Class.forName("android.media.ImageReader\$OnImageAvailableListener")
        val wrapper = createListenerWrapper(currentListener, listenerInterface, reader)

        // Replace the listener
        listenerField.set(reader, wrapper)

        // Track the reader
        trackedReaders.add(WeakReference(reader))
        hasWrappedListener = true
        // Log reader details for debugging
        try {
            val ir = reader as ImageReader
            Log.d(TAG, "Camera2Interceptor: wrapped listener on ImageReader #$readerId " +
                "(${ir.width}x${ir.height}, format=${ir.getImageFormat()}, max=${ir.maxImages})")
        } catch (_: Exception) {
            Log.d(TAG, "Camera2Interceptor: wrapped listener on ImageReader #$readerId")
        }
    }

    /**
     * Create a proxy OnImageAvailableListener that intercepts image delivery.
     *
     * Strategy: Bypass CameraX entirely for capture:
     * 1. Acquire the Image before CameraX does (consume the camera frame)
     * 2. Create a mock ImageProxy (via java.lang.reflect.Proxy) with our JPEG bytes
     * 3. Find the app's OnImageCapturedCallback via reflection
     * 4. Deliver our mock ImageProxy directly to the app's callback
     *
     * This works because CameraX stores the app's callback in its ImageCapture
     * pipeline, which we can find via deep reflection scanning.
     */
    private fun createListenerWrapper(
        originalListener: Any,
        listenerInterface: Class<*>,
        reader: Any
    ): Any {
        return Proxy.newProxyInstance(
            listenerInterface.classLoader,
            arrayOf(listenerInterface),
            InvocationHandler handler@{ _, method, args ->
                if (method.name == "onImageAvailable" && args != null) {
                    val mockBytes = ImageWatcher.currentJpegBytes
                    if (mockBytes != null) {
                        try {
                            val imageReader = reader as ImageReader
                            val image = imageReader.acquireNextImage()
                            if (image != null) {
                                deliverMockCapture(image, mockBytes)
                                return@handler null // Skip CameraX's listener
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Camera2Interceptor: mock delivery failed: ${e.message}")
                        }
                    }
                }
                // No mock or error → pass through to CameraX
                method.invoke(originalListener, *(args ?: emptyArray()))
            }
        )
    }

    /**
     * Deliver a mock capture by modifying the real Image's plane buffer data,
     * then letting CameraX process normally.
     *
     * Strategy: Replace the ByteBuffer inside the Image's SurfacePlane with our
     * mock JPEG bytes. CameraX wraps the Image as ImageProxy and delivers it
     * to the app's callback — which now reads our mock data.
     */
    private fun deliverMockCapture(realImage: android.media.Image, mockBytes: ByteArray) {
        try {
            val planes = realImage.planes
            if (planes.isEmpty()) {
                Log.w(TAG, "Camera2Interceptor: no planes in image")
                realImage.close()
                return
            }

            val plane = planes[0]
            // Replace the plane's internal ByteBuffer with our mock data
            val planeClass = plane.javaClass
            val bufferField = planeClass.getDeclaredField("mBuffer")
            bufferField.isAccessible = true
            bufferField.set(plane, ByteBuffer.wrap(mockBytes))
            val callbackClass = Class.forName("androidx.camera.core.ImageCapture\$OnImageCapturedCallback")

            // Try finding callback from cached ImageCapture (shorter path, more reliable)
            var callbacks = findCallbackFromImageCapture(callbackClass)

            // Fallback: scan from ProcessCameraProvider
            if (callbacks.isEmpty()) {
                callbacks = findInstancesOfClass(callbackClass)
            }

            if (callbacks.isEmpty()) {
                Log.w(TAG, "Camera2Interceptor: no OnImageCapturedCallback found")
                // Last resort: close image and let CameraX handle error
                realImage.close()
                return
            }

            // Create mock ImageProxy wrapping our JPEG bytes
            val mockProxy = createMockImageProxy(realImage, mockBytes)

            // Call the app's callback on the main thread
            val callback = callbacks.first()
            val onCaptureSuccess = callbackClass.getDeclaredMethod("onCaptureSuccess",
                Class.forName("androidx.camera.core.ImageProxy"))
            onCaptureSuccess.isAccessible = true

            handler.post {
                try {
                    onCaptureSuccess.invoke(callback, mockProxy)
                    Log.d(TAG, "Camera2Interceptor: mock capture delivered (${mockBytes.size} bytes)")
                } catch (e: Exception) {
                    Log.w(TAG, "Camera2Interceptor: callback delivery error: ${e.message}")
                    realImage.close()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Camera2Interceptor: deliverMockCapture failed: ${e.message}")
            realImage.close()
        }
    }

    /**
     * Find OnImageCapturedCallback by scanning from the cached ImageCapture instance.
     * This is a shorter path (~4-5 levels) compared to scanning from ProcessCameraProvider.
     */
    private fun findCallbackFromImageCapture(targetClass: Class<*>): List<Any> {
        val results = mutableListOf<Any>()
        val imageCapture = cachedImageCapture?.get() ?: return results
        try {
            scanForInstances(imageCapture, targetClass, 15, results, mutableSetOf())
        } catch (_: Exception) {}
        return results
    }

    /**
     * Create a Proxy-based ImageProxy that returns our mock JPEG bytes
     * when the app calls getPlanes()[0].getBuffer().
     */
    private fun createMockImageProxy(image: android.media.Image, mockBytes: ByteArray): Any {
        val imageProxyClass = Class.forName("androidx.camera.core.ImageProxy")
        val planeProxyClass = Class.forName("androidx.camera.core.ImageProxy\$PlaneProxy")

        // Create mock PlaneProxy
        val mockBuffer = ByteBuffer.wrap(mockBytes)
        val planeProxy = Proxy.newProxyInstance(
            planeProxyClass.classLoader,
            arrayOf(planeProxyClass)
        ) { _, m, _ ->
            when (m.name) {
                "getBuffer" -> mockBuffer
                "getPixelStride" -> 0
                "getRowStride" -> mockBytes.size
                else -> null
            }
        }

        // Create mock ImageInfo
        val imageInfoClass = Class.forName("androidx.camera.core.ImageInfo")
        val imageInfo = Proxy.newProxyInstance(
            imageInfoClass.classLoader,
            arrayOf(imageInfoClass)
        ) { _, m, _ ->
            when (m.name) {
                "getTimestamp" -> System.nanoTime()
                "getRotationDegrees" -> 0
                "getTagBundle" -> null
                "getSensorToBufferTransformMatrix" -> null
                else -> null
            }
        }

        val planesArray = java.lang.reflect.Array.newInstance(planeProxyClass, 1)
        java.lang.reflect.Array.set(planesArray, 0, planeProxy)

        // Create mock ImageProxy
        return Proxy.newProxyInstance(
            imageProxyClass.classLoader,
            arrayOf(imageProxyClass)
        ) { _, m, mArgs ->
            when (m.name) {
                "getPlanes" -> planesArray
                "close" -> { image.close(); Unit }
                "getWidth" -> image.width
                "getHeight" -> image.height
                "getFormat", "getImageFormat" -> image.format
                "getImage" -> image
                "getImageInfo" -> imageInfo
                "getCropRect" -> image.cropRect
                "setCropRect" -> { if (mArgs != null) image.cropRect = mArgs[0] as android.graphics.Rect; Unit }
                else -> null
            }
        }
    }

    /**
     * Find instances of a specific class by scanning from ProcessCameraProvider.
     * Used to locate the app's OnImageCapturedCallback.
     */
    private fun findInstancesOfClass(targetClass: Class<*>): List<Any> {
        val results = mutableListOf<Any>()
        try {
            val providerClass = Class.forName("androidx.camera.lifecycle.ProcessCameraProvider")
            val sAppField = providerClass.getDeclaredField("sAppInstance")
            sAppField.isAccessible = true
            val provider = sAppField.get(null) ?: return results
            scanForInstances(provider, targetClass, 20, results, mutableSetOf())
        } catch (_: Exception) {}
        return results
    }

    /**
     * Recursively scan an object graph for instances assignable to a target class.
     */
    private fun scanForInstances(
        obj: Any, targetClass: Class<*>, maxDepth: Int,
        results: MutableList<Any>, visited: MutableSet<Int>
    ) {
        if (maxDepth <= 0 || visited.size > 50000) return
        val id = System.identityHashCode(obj)
        if (visited.contains(id)) return
        visited.add(id)

        if (targetClass.isInstance(obj)) {
            results.add(obj)
            return
        }

        try {
            if (obj is Collection<*>) {
                for (e in obj) { if (e != null) scanForInstances(e, targetClass, maxDepth - 1, results, visited) }
                return
            }
            if (obj is Map<*, *>) {
                for (v in obj.values) { if (v != null) scanForInstances(v, targetClass, maxDepth - 1, results, visited) }
                return
            }

            var clazz: Class<*>? = obj.javaClass
            while (clazz != null && clazz != Any::class.java) {
                for (field in clazz.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    try {
                        field.isAccessible = true
                        val value = field.get(obj) ?: continue
                        if (!field.type.isPrimitive && !field.type.isEnum) {
                            val tn = value.javaClass.name
                            if (tn.startsWith("java.lang.") && tn != "java.lang.Object") continue
                            if (tn.startsWith("java.math.")) continue
                            if (field.type.isArray && field.type.componentType?.isPrimitive != true) {
                                @Suppress("UNCHECKED_CAST")
                                (value as? Array<Any?>)?.forEach { e ->
                                    if (e != null) scanForInstances(e, targetClass, maxDepth - 1, results, visited)
                                }
                            } else if (!field.type.isArray) {
                                scanForInstances(value, targetClass, maxDepth - 1, results, visited)
                            }
                        }
                    } catch (_: Exception) {}
                }
                clazz = clazz.superclass
            }
        } catch (_: Exception) {}
    }

    /**
     * Find ImageReader instances created by CameraX's ImageCapture use case.
     *
     * CameraX stores ImageReaders deep in its internal structure (~10 levels).
     * We scan from multiple entry points:
     * 1. ProcessCameraProvider static fields (CameraX singleton)
     * 2. CameraX core singleton
     * 3. Activity fields (fallback for non-CameraX apps)
     */
    private fun findCameraXImageReaders(): List<Any>? {
        val readers = mutableListOf<Any>()
        val visited = mutableSetOf<Int>()

        // Strategy 1: Scan from ProcessCameraProvider (CameraX lifecycle-aware entry point)
        try {
            val providerClass = Class.forName("androidx.camera.lifecycle.ProcessCameraProvider")
            val staticFields = providerClass.declaredFields.filter {
                java.lang.reflect.Modifier.isStatic(it.modifiers)
            }
            for (field in staticFields) {
                try {
                    field.isAccessible = true
                    val value = field.get(null) ?: continue
                    findFieldsOfType(value, "android.media.ImageReader", 15, readers, visited)
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}

        // Strategy 2: Scan from CameraX core singleton
        if (readers.isEmpty()) {
            try {
                val cameraXClass = Class.forName("androidx.camera.core.CameraX")
                for (field in cameraXClass.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) {
                        try {
                            field.isAccessible = true
                            val value = field.get(null) ?: continue
                            findFieldsOfType(value, "android.media.ImageReader", 15, readers, visited)
                        } catch (_: Exception) {}
                    }
                }
            } catch (_: Exception) {}
        }

        // Strategy 3: Scan from Activity fields (for non-CameraX or direct Camera2 apps)
        if (readers.isEmpty()) {
            try {
                val atClass = Class.forName("android.app.ActivityThread")
                val at = atClass.getMethod("currentActivityThread").invoke(null) ?: return readers
                val activitiesField = atClass.getDeclaredField("mActivities")
                activitiesField.isAccessible = true
                @Suppress("UNCHECKED_CAST")
                val activities = activitiesField.get(at) as? android.util.ArrayMap<*, *> ?: return readers

                for (record in activities.values) {
                    if (record == null) continue
                    try {
                        val activityField = record.javaClass.getDeclaredField("activity")
                        activityField.isAccessible = true
                        val activity = activityField.get(record) ?: continue
                        findFieldsOfType(activity, "android.media.ImageReader", 15, readers, visited)
                    } catch (_: Exception) {}
                }
            } catch (_: Exception) {}
        }

        // Strategy 4: Direct field-name scan — find any field named "mImageReader"
        //             in reachable objects from ProcessCameraProvider
        //             Also caches the ImageCapture instance for callback scanning
        if (readers.isEmpty()) {
            try {
                val providerClass = Class.forName("androidx.camera.lifecycle.ProcessCameraProvider")
                val sAppField = providerClass.getDeclaredField("sAppInstance")
                sAppField.isAccessible = true
                val provider = sAppField.get(null)
                if (provider != null) {
                    val directReaders = mutableListOf<Any>()
                    findByFieldName(provider, "mImageReader", "android.media.ImageReader",
                        20, directReaders, mutableSetOf())
                    readers.addAll(directReaders)

                    // Also find and cache ImageCapture instance for faster callback lookup
                    if (cachedImageCapture?.get() == null) {
                        try {
                            val imageCaptureClass = Class.forName("androidx.camera.core.ImageCapture")
                            val captures = mutableListOf<Any>()
                            scanForInstances(provider, imageCaptureClass, 10, captures, mutableSetOf())
                            if (captures.isNotEmpty()) {
                                cachedImageCapture = WeakReference(captures.first())
                                Log.d(TAG, "Camera2Interceptor: cached ImageCapture instance")
                            }
                        } catch (_: Exception) {}
                    }
                }
            } catch (_: Exception) {}
        }

        if (readers.isNotEmpty()) {
            Log.d(TAG, "Camera2Interceptor: found ${readers.size} ImageReader(s)")
        }
        return readers
    }

    /**
     * Find objects by a specific field name pattern, traversing deeply.
     * Less restrictive than findFieldsOfType — follows ALL non-primitive fields.
     */
    private fun findByFieldName(
        obj: Any,
        fieldName: String,
        targetClassName: String,
        maxDepth: Int,
        results: MutableList<Any>,
        visited: MutableSet<Int>
    ) {
        if (maxDepth <= 0 || visited.size > 10000) return
        val id = System.identityHashCode(obj)
        if (visited.contains(id)) return
        visited.add(id)

        try {
            // Handle collections
            if (obj is Collection<*>) {
                for (e in obj) {
                    if (e != null) findByFieldName(e, fieldName, targetClassName, maxDepth - 1, results, visited)
                }
                return
            }
            if (obj is Map<*, *>) {
                for (v in obj.values) {
                    if (v != null) findByFieldName(v, fieldName, targetClassName, maxDepth - 1, results, visited)
                }
                return
            }

            var clazz: Class<*>? = obj.javaClass
            while (clazz != null && clazz != Any::class.java) {
                for (field in clazz.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    try {
                        field.isAccessible = true
                        val value = field.get(obj) ?: continue

                        // Check if this is the target field
                        if (field.name == fieldName && value.javaClass.name == targetClassName) {
                            if (!results.any { System.identityHashCode(it) == System.identityHashCode(value) }) {
                                results.add(value)
                            }
                        }

                        // Recurse into non-primitive fields
                        if (!field.type.isPrimitive && !field.type.isEnum) {
                            val tn = value.javaClass.name
                            // Skip only truly terminal types
                            if (tn.startsWith("java.lang.") && tn != "java.lang.Object") continue
                            if (tn.startsWith("java.math.")) continue
                            if (tn == "java.net.URI" || tn == "java.net.URL") continue

                            if (field.type.isArray && field.type.componentType?.isPrimitive != true) {
                                @Suppress("UNCHECKED_CAST")
                                (value as? Array<Any?>)?.forEach { e ->
                                    if (e != null) findByFieldName(e, fieldName, targetClassName, maxDepth - 1, results, visited)
                                }
                            } else if (!field.type.isArray) {
                                findByFieldName(value, fieldName, targetClassName, maxDepth - 1, results, visited)
                            }
                        }
                    } catch (_: Exception) {}
                }
                clazz = clazz.superclass
            }
        } catch (_: Exception) {}
    }

    /**
     * Recursively scan an object's fields for instances of a target type.
     *
     * Key improvements over naive scanning:
     * - Traverses into Collections (ArrayList, ArrayMap, etc.) and Maps
     * - Traverses into Object arrays (CameraX stores use cases in lists)
     * - Depth 15 to reach CameraX's deeply nested ImageReaders
     * - Visited set with size limit to prevent runaway scanning
     */
    private fun findFieldsOfType(
        obj: Any,
        targetClassName: String,
        maxDepth: Int,
        results: MutableList<Any>,
        visited: MutableSet<Int> = mutableSetOf()
    ) {
        if (maxDepth <= 0 || visited.size > 5000) return
        val id = System.identityHashCode(obj)
        if (visited.contains(id)) return
        visited.add(id)

        // Check if this object IS the target type
        if (obj.javaClass.name == targetClassName) {
            if (!results.any { System.identityHashCode(it) == System.identityHashCode(obj) }) {
                results.add(obj)
            }
            return
        }

        try {
            // Special handling: traverse Collection elements (ArrayList, ArrayDeque, etc.)
            if (obj is Collection<*>) {
                for (element in obj) {
                    if (element != null) {
                        findFieldsOfType(element, targetClassName, maxDepth - 1, results, visited)
                    }
                }
                return
            }

            // Special handling: traverse Map values
            if (obj is Map<*, *>) {
                for (value in obj.values) {
                    if (value != null) {
                        findFieldsOfType(value, targetClassName, maxDepth - 1, results, visited)
                    }
                }
                return
            }

            // Regular field scanning
            var clazz: Class<*>? = obj.javaClass
            while (clazz != null && clazz != Any::class.java) {
                for (field in clazz.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    try {
                        field.isAccessible = true
                        val value = field.get(obj) ?: continue

                        if (value.javaClass.name == targetClassName) {
                            if (!results.any { System.identityHashCode(it) == System.identityHashCode(value) }) {
                                results.add(value)
                            }
                        } else if (!field.type.isPrimitive && !field.type.isEnum) {
                            val typeName = field.type.name
                            // Skip java.lang.* (String, Integer, etc.) but NOT java.util.* or android.*
                            if (typeName.startsWith("java.lang.")) continue

                            if (field.type.isArray && !field.type.componentType!!.isPrimitive) {
                                // Traverse object arrays
                                @Suppress("UNCHECKED_CAST")
                                val array = value as? Array<Any?>
                                array?.forEach { element ->
                                    if (element != null) {
                                        findFieldsOfType(element, targetClassName, maxDepth - 1, results, visited)
                                    }
                                }
                            } else if (!field.type.isArray) {
                                findFieldsOfType(value, targetClassName, maxDepth - 1, results, visited)
                            }
                        }
                    } catch (_: Exception) {}
                }
                clazz = clazz.superclass
            }
        } catch (_: Exception) {}
    }

}
