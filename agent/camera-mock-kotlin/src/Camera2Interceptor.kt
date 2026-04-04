package dev.autopilot.cameramock

import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.lang.ref.WeakReference
import java.lang.reflect.InvocationHandler
import java.lang.reflect.Proxy
import android.media.ImageReader
import java.nio.ByteBuffer
import java.util.concurrent.Executor

/**
 * Intercepts CameraX / Camera2 capture output so apps receive mock JPEG bytes.
 *
 * Previous approach (broken): replace ByteBuffer inside Image.Plane — fails because
 * the HAL allocates direct buffers that cannot be swapped with ByteBuffer.wrap().
 *
 * New approach:
 * 1. Find ImageCapture instances from ProcessCameraProvider (shallow scan, 5 levels).
 * 2. Wrap the ImageReader's OnImageAvailableListener (already proven to work).
 * 3. On onImageAvailable: acquire + close the real image (consume it).
 * 4. Find the pending OnImageCapturedCallback via short path through
 *    ImageCapture → TakePictureManager → pending requests → callback.
 * 5. Create a mock ImageProxy via java.lang.reflect.Proxy with our JPEG bytes.
 * 6. Deliver mock ImageProxy directly to the app's callback.
 *
 * This bypasses CameraX's internal pipeline entirely for capture.
 */
object Camera2Interceptor {
    private const val TAG = "AutoPilotCamera"
    private val handler = Handler(Looper.getMainLooper())

    // Tracked ImageReaders (weak references to avoid leaks)
    private val trackedReaders = mutableListOf<WeakReference<Any>>()

    // Original listeners keyed by ImageReader identity hash
    private val originalListeners = mutableMapOf<Int, Any>()

    // Cached ImageCapture instance for callback lookup
    @Volatile private var cachedImageCapture: WeakReference<Any>? = null

    @Volatile private var hasWrappedListener = false
    @Volatile private var rescanRequestedAt = 0L

    fun install() {
        try {
            Log.d(TAG, "Camera2Interceptor: installing hooks (new strategy)")
            startListenerScanner()
        } catch (e: Exception) {
            Log.e(TAG, "Camera2Interceptor install failed", e)
        }
    }

    /**
     * Force a fast re-scan for new ImageReaders.
     * Called from CameraHooks when activity resumes (tab change = new camera binding).
     */
    fun requestRescan() {
        rescanRequestedAt = System.currentTimeMillis()
        cachedImageCapture = null
    }

    /**
     * Periodically scan for ImageReader instances and wrap their listeners.
     * Fast-polls (500ms) for 5s after a rescan request, then slows down.
     */
    private fun startListenerScanner() {
        Thread {
            while (true) {
                try {
                    val timeSinceRescan = System.currentTimeMillis() - rescanRequestedAt
                    val interval = when {
                        timeSinceRescan < 5_000 -> 500L
                        !hasWrappedListener -> 2_000L
                        else -> 3_000L
                    }
                    Thread.sleep(interval)
                    scanAndWrapListeners()
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    Log.w(TAG, "Camera2Interceptor scan error: ${e.message}")
                }
            }
        }.apply {
            isDaemon = true
            name = "autopilot-camerax-scanner"
        }.start()
    }

    private fun scanAndWrapListeners() {
        try {
            val irClass = Class.forName("android.media.ImageReader")
            val listenerField = irClass.getDeclaredField("mListener")
            listenerField.isAccessible = true

            // Find ImageReaders via CameraX/Camera2
            findImageReaders()?.forEach { reader ->
                wrapListener(reader, irClass, listenerField)
            }

            // Check previously tracked readers
            val iter = trackedReaders.iterator()
            while (iter.hasNext()) {
                val reader = iter.next().get()
                if (reader == null) { iter.remove(); continue }
                wrapListener(reader, irClass, listenerField)
            }
        } catch (_: Exception) {}
    }

    private fun wrapListener(reader: Any, irClass: Class<*>, listenerField: java.lang.reflect.Field) {
        val readerId = System.identityHashCode(reader)
        if (originalListeners.containsKey(readerId)) return

        val currentListener = listenerField.get(reader) ?: return
        if (Proxy.isProxyClass(currentListener.javaClass)) return

        originalListeners[readerId] = currentListener

        val listenerInterface = Class.forName("android.media.ImageReader\$OnImageAvailableListener")
        val wrapper = createListenerWrapper(currentListener, listenerInterface, reader)
        listenerField.set(reader, wrapper)

        trackedReaders.add(WeakReference(reader))
        hasWrappedListener = true

        // New ImageReader means CameraX rebound — invalidate cached ImageCapture
        cachedImageCapture = null
        Log.d(TAG, "Camera2Interceptor: invalidated ImageCapture cache (new ImageReader)")

        try {
            val ir = reader as ImageReader
            Log.d(TAG, "Camera2Interceptor: wrapped listener on ImageReader #$readerId " +
                "(${ir.width}x${ir.height}, format=${ir.imageFormat}, max=${ir.maxImages})")
        } catch (_: Exception) {
            Log.d(TAG, "Camera2Interceptor: wrapped listener on ImageReader #$readerId")
        }
    }

    /**
     * Wrapper that intercepts onImageAvailable:
     * - Consumes the real image (acquire + close)
     * - Finds the app's pending callback
     * - Delivers a mock ImageProxy with our JPEG bytes
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

                            // Pre-check: can we find the callback BEFORE consuming the image?
                            // This avoids losing the real image if we can't deliver the mock.
                            val callback = findPendingCallback()
                            if (callback == null) {
                                // Invalidate cache and try once more
                                cachedImageCapture = null
                                val retryCallback = findPendingCallback()
                                if (retryCallback == null) {
                                    Log.w(TAG, "Camera2Interceptor: no callback found, passing through")
                                    method.invoke(originalListener, *(args ?: emptyArray()))
                                    return@handler null
                                }
                            }

                            // Step 1: Consume the real image so CameraX doesn't process it
                            val realImage = imageReader.acquireNextImage()
                            if (realImage != null) {
                                val width = realImage.width
                                val height = realImage.height
                                val format = realImage.format
                                realImage.close()

                                // Step 2: Deliver mock to the callback we already found
                                if (deliverMockToCallback(mockBytes, width, height, format)) {
                                    return@handler null // Success — skip original listener
                                }
                            }
                        } catch (e: Exception) {
                            Log.w(TAG, "Camera2Interceptor: mock delivery failed: ${e.message}")
                        }
                    }
                }
                // Fallback: pass through to original listener
                method.invoke(originalListener, *(args ?: emptyArray()))
            }
        )
    }

    /**
     * Find the app's pending OnImageCapturedCallback and deliver a mock ImageProxy.
     * Returns true on success.
     */
    private fun deliverMockToCallback(mockBytes: ByteArray, width: Int, height: Int, format: Int): Boolean {
        // Try to find the callback via known CameraX internal path
        val callback = findPendingCallback()
        if (callback == null) {
            Log.w(TAG, "Camera2Interceptor: no pending callback found")
            return false
        }

        // Find the executor associated with the callback (or use main)
        val executor = findCallbackExecutor() ?: Executor { handler.post(it) }

        // Create mock ImageProxy
        val mockProxy = createMockImageProxy(mockBytes, width, height, format)

        // Invoke onCaptureSuccess on the callback
        try {
            val callbackClass = callback.javaClass
            // Try direct method first, then search in superclasses
            val onSuccess = findMethod(callbackClass, "onCaptureSuccess",
                "androidx.camera.core.ImageProxy")

            if (onSuccess != null) {
                onSuccess.isAccessible = true
                executor.execute {
                    try {
                        onSuccess.invoke(callback, mockProxy)
                        Log.d(TAG, "Camera2Interceptor: mock capture delivered (${mockBytes.size} bytes)")
                    } catch (e: Exception) {
                        Log.w(TAG, "Camera2Interceptor: callback invocation error: ${e.message}")
                    }
                }
                return true
            }
        } catch (e: Exception) {
            Log.w(TAG, "Camera2Interceptor: callback delivery setup error: ${e.message}")
        }
        return false
    }

    /**
     * Find the pending OnImageCapturedCallback via CameraX internal path.
     *
     * Known paths (CameraX 1.3-1.4):
     *   ImageCapture → mTakePictureManager → mNewPendingRequests/mPendingRequests → request.mCallback
     *   ImageCapture → mTakePictureManager → mIssuedRequest → callback
     *
     * We try multiple field name variants since CameraX internals change between versions.
     */
    private fun findPendingCallback(): Any? {
        var imageCapture = cachedImageCapture?.get()
        if (imageCapture == null) {
            imageCapture = findAndCacheImageCapture()
        }
        if (imageCapture == null) {
            Log.w(TAG, "Camera2Interceptor: ImageCapture not found")
            return null
        }

        // Path: ImageCapture → TakePictureManager
        val manager = getFieldByNames(imageCapture,
            "mTakePictureManager", "takePictureManager", "mImagePipeline") ?: run {
            // Fallback: deep scan from ImageCapture (max 8 levels, much shorter than before)
            return deepScanForCallback(imageCapture)
        }

        // Path: TakePictureManager → pending requests
        val requests = getCollectionField(manager,
            "mNewPendingRequests", "mPendingRequests", "mIssuedRequests",
            "pendingRequests", "mProcessingRequests")

        if (requests != null && requests.isNotEmpty()) {
            val lastRequest = requests.last()
            if (lastRequest != null) {
                // Path: request → callback
                val callback = getFieldByNames(lastRequest,
                    "mCallback", "callback", "mAppCallback", "mCaptureCallback")
                if (callback != null) {
                    Log.d(TAG, "Camera2Interceptor: found callback via TakePictureManager path")
                    return callback
                }
                // If the request itself has callback nested deeper
                return deepScanForCallback(lastRequest, maxDepth = 5)
            }
        }

        // Path: TakePictureManager → currently issued request
        val issuedRequest = getFieldByNames(manager,
            "mIssuedRequest", "mCurrentRequest", "issuedRequest")
        if (issuedRequest != null) {
            val callback = getFieldByNames(issuedRequest,
                "mCallback", "callback", "mAppCallback", "mCaptureCallback")
            if (callback != null) {
                Log.d(TAG, "Camera2Interceptor: found callback via issued request")
                return callback
            }
        }

        // Fallback: deep scan from manager (limited depth)
        return deepScanForCallback(manager, maxDepth = 8)
    }

    /**
     * Deep scan for OnImageCapturedCallback from a root object.
     */
    private fun deepScanForCallback(root: Any, maxDepth: Int = 8): Any? {
        try {
            val callbackClass = Class.forName("androidx.camera.core.ImageCapture\$OnImageCapturedCallback")
            val results = mutableListOf<Any>()
            scanForInstances(root, callbackClass, maxDepth, results, mutableSetOf())
            if (results.isNotEmpty()) {
                Log.d(TAG, "Camera2Interceptor: found callback via deep scan (${results.size})")
                return results.last() // Last is most likely the most recently queued
            }
        } catch (_: Exception) {}
        return null
    }

    /**
     * Find the executor for the callback (CameraX stores it alongside the callback).
     */
    private fun findCallbackExecutor(): Executor? {
        val imageCapture = cachedImageCapture?.get() ?: return null
        val manager = getFieldByNames(imageCapture,
            "mTakePictureManager", "takePictureManager") ?: return null

        val requests = getCollectionField(manager,
            "mNewPendingRequests", "mPendingRequests", "mIssuedRequests",
            "pendingRequests", "mProcessingRequests")

        if (requests != null && requests.isNotEmpty()) {
            val lastRequest = requests.last()
            if (lastRequest != null) {
                val executor = getFieldByNames(lastRequest,
                    "mAppExecutor", "mExecutor", "executor", "mCallbackExecutor")
                if (executor is Executor) return executor
            }
        }
        return null
    }

    /**
     * Find and cache the ImageCapture instance from ProcessCameraProvider.
     */
    private fun findAndCacheImageCapture(): Any? {
        try {
            val providerClass = Class.forName("androidx.camera.lifecycle.ProcessCameraProvider")
            // Try known static fields
            for (fieldName in listOf("sAppInstance", "sInstance", "INSTANCE")) {
                try {
                    val field = providerClass.getDeclaredField(fieldName)
                    field.isAccessible = true
                    val provider = field.get(null) ?: continue
                    val imageCaptureClass = Class.forName("androidx.camera.core.ImageCapture")
                    val captures = mutableListOf<Any>()
                    scanForInstances(provider, imageCaptureClass, 8, captures, mutableSetOf())
                    if (captures.isNotEmpty()) {
                        val ic = captures.first()
                        cachedImageCapture = WeakReference(ic)
                        Log.d(TAG, "Camera2Interceptor: cached ImageCapture instance")
                        return ic
                    }
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}
        return null
    }

    // ----- Mock ImageProxy creation -----

    /**
     * Create a Proxy-based ImageProxy that returns our mock JPEG bytes.
     * The mock is self-contained — no reference to a real Image needed.
     */
    private fun createMockImageProxy(mockBytes: ByteArray, width: Int, height: Int, format: Int): Any {
        val imageProxyClass = Class.forName("androidx.camera.core.ImageProxy")
        val planeProxyClass = Class.forName("androidx.camera.core.ImageProxy\$PlaneProxy")

        val mockBuffer = ByteBuffer.wrap(mockBytes)
        val planeProxy = Proxy.newProxyInstance(
            planeProxyClass.classLoader,
            arrayOf(planeProxyClass)
        ) { _, m, _ ->
            when (m.name) {
                "getBuffer" -> { mockBuffer.rewind(); mockBuffer }
                "getPixelStride" -> 0
                "getRowStride" -> mockBytes.size
                else -> null
            }
        }

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

        // Decode bitmap for dimensions if the mock is JPEG
        val bmp = BitmapFactory.decodeByteArray(mockBytes, 0, mockBytes.size)
        val mockWidth = bmp?.width ?: width
        val mockHeight = bmp?.height ?: height

        var closed = false

        return Proxy.newProxyInstance(
            imageProxyClass.classLoader,
            arrayOf(imageProxyClass, AutoCloseable::class.java)
        ) { _, m, mArgs ->
            when (m.name) {
                "getPlanes" -> planesArray
                "close" -> { closed = true; Unit }
                "getWidth" -> mockWidth
                "getHeight" -> mockHeight
                "getFormat", "getImageFormat" -> format
                "getImage" -> null // No real Image backing this mock
                "getImageInfo" -> imageInfo
                "getCropRect" -> android.graphics.Rect(0, 0, mockWidth, mockHeight)
                "setCropRect" -> Unit
                "toString" -> "MockImageProxy[${mockWidth}x${mockHeight}, ${mockBytes.size} bytes]"
                "hashCode" -> System.identityHashCode(mockBytes)
                "equals" -> false
                else -> null
            }
        }
    }

    // ----- ImageReader discovery (reused from previous version) -----

    private fun findImageReaders(): List<Any>? {
        val readers = mutableListOf<Any>()
        val visited = mutableSetOf<Int>()

        // Strategy 1: ProcessCameraProvider static fields
        try {
            val providerClass = Class.forName("androidx.camera.lifecycle.ProcessCameraProvider")
            for (field in providerClass.declaredFields) {
                if (!java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                try {
                    field.isAccessible = true
                    val value = field.get(null) ?: continue
                    findFieldsOfType(value, "android.media.ImageReader", 15, readers, visited)
                } catch (_: Exception) {}
            }
        } catch (_: Exception) {}

        // Strategy 2: CameraX core singleton
        if (readers.isEmpty()) {
            try {
                val cameraXClass = Class.forName("androidx.camera.core.CameraX")
                for (field in cameraXClass.declaredFields) {
                    if (!java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    try {
                        field.isAccessible = true
                        val value = field.get(null) ?: continue
                        findFieldsOfType(value, "android.media.ImageReader", 15, readers, visited)
                    } catch (_: Exception) {}
                }
            } catch (_: Exception) {}
        }

        // Strategy 3: Activity fields
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

        // Strategy 4: Direct field-name scan + cache ImageCapture
        if (readers.isEmpty()) {
            try {
                val providerClass = Class.forName("androidx.camera.lifecycle.ProcessCameraProvider")
                for (fn in listOf("sAppInstance", "sInstance", "INSTANCE")) {
                    try {
                        val sAppField = providerClass.getDeclaredField(fn)
                        sAppField.isAccessible = true
                        val provider = sAppField.get(null) ?: continue
                        val directReaders = mutableListOf<Any>()
                        findByFieldName(provider, "mImageReader", "android.media.ImageReader",
                            20, directReaders, mutableSetOf())
                        readers.addAll(directReaders)

                        // Also cache ImageCapture instance
                        if (cachedImageCapture?.get() == null) {
                            findAndCacheImageCapture()
                        }
                        break
                    } catch (_: Exception) {}
                }
            } catch (_: Exception) {}
        }

        if (readers.isNotEmpty()) {
            Log.d(TAG, "Camera2Interceptor: found ${readers.size} ImageReader(s)")
        }
        return readers
    }

    // ----- Reflection utilities -----

    /**
     * Get a field's value by trying multiple possible names.
     */
    private fun getFieldByNames(obj: Any, vararg names: String): Any? {
        var clazz: Class<*>? = obj.javaClass
        while (clazz != null && clazz != Any::class.java) {
            for (name in names) {
                try {
                    val field = clazz!!.getDeclaredField(name)
                    field.isAccessible = true
                    return field.get(obj)
                } catch (_: NoSuchFieldException) {}
            }
            clazz = clazz!!.superclass
        }
        return null
    }

    /**
     * Get a Collection from a field, trying multiple names.
     */
    private fun getCollectionField(obj: Any, vararg names: String): List<Any?>? {
        val value = getFieldByNames(obj, *names) ?: return null
        return when (value) {
            is List<*> -> value
            is Collection<*> -> value.toList()
            is Array<*> -> value.toList()
            else -> null
        }
    }

    /**
     * Find a method by name, trying to match a parameter type by class name.
     */
    private fun findMethod(clazz: Class<*>, methodName: String, paramTypeName: String): java.lang.reflect.Method? {
        var c: Class<*>? = clazz
        while (c != null && c != Any::class.java) {
            for (m in c.declaredMethods) {
                if (m.name == methodName && m.parameterTypes.size == 1 &&
                    m.parameterTypes[0].name == paramTypeName) {
                    return m
                }
            }
            c = c.superclass
        }
        return null
    }

    // ----- Graph scanning utilities -----

    private fun scanForInstances(
        obj: Any, targetClass: Class<*>, maxDepth: Int,
        results: MutableList<Any>, visited: MutableSet<Int>
    ) {
        if (maxDepth <= 0 || visited.size > 20000) return
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

    private fun findFieldsOfType(
        obj: Any, targetClassName: String, maxDepth: Int,
        results: MutableList<Any>, visited: MutableSet<Int> = mutableSetOf()
    ) {
        if (maxDepth <= 0 || visited.size > 5000) return
        val id = System.identityHashCode(obj)
        if (visited.contains(id)) return
        visited.add(id)

        if (obj.javaClass.name == targetClassName) {
            if (!results.any { System.identityHashCode(it) == System.identityHashCode(obj) }) {
                results.add(obj)
            }
            return
        }

        try {
            if (obj is Collection<*>) {
                for (e in obj) { if (e != null) findFieldsOfType(e, targetClassName, maxDepth - 1, results, visited) }
                return
            }
            if (obj is Map<*, *>) {
                for (v in obj.values) { if (v != null) findFieldsOfType(v, targetClassName, maxDepth - 1, results, visited) }
                return
            }

            var clazz: Class<*>? = obj.javaClass
            while (clazz != null && clazz != Any::class.java) {
                for (field in clazz.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    try {
                        field.isAccessible = true
                        val value = field.get(obj) ?: continue
                        if (value.javaClass.name == targetClassName) {
                            if (!results.any { System.identityHashCode(it) == System.identityHashCode(obj) }) {
                                results.add(value)
                            }
                        } else if (!field.type.isPrimitive && !field.type.isEnum) {
                            val tn = field.type.name
                            if (tn.startsWith("java.lang.")) continue
                            if (field.type.isArray && field.type.componentType?.isPrimitive != true) {
                                @Suppress("UNCHECKED_CAST")
                                (value as? Array<Any?>)?.forEach { e ->
                                    if (e != null) findFieldsOfType(e, targetClassName, maxDepth - 1, results, visited)
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

    private fun findByFieldName(
        obj: Any, fieldName: String, targetClassName: String,
        maxDepth: Int, results: MutableList<Any>, visited: MutableSet<Int>
    ) {
        if (maxDepth <= 0 || visited.size > 10000) return
        val id = System.identityHashCode(obj)
        if (visited.contains(id)) return
        visited.add(id)

        try {
            if (obj is Collection<*>) {
                for (e in obj) { if (e != null) findByFieldName(e, fieldName, targetClassName, maxDepth - 1, results, visited) }
                return
            }
            if (obj is Map<*, *>) {
                for (v in obj.values) { if (v != null) findByFieldName(v, fieldName, targetClassName, maxDepth - 1, results, visited) }
                return
            }

            var clazz: Class<*>? = obj.javaClass
            while (clazz != null && clazz != Any::class.java) {
                for (field in clazz.declaredFields) {
                    if (java.lang.reflect.Modifier.isStatic(field.modifiers)) continue
                    try {
                        field.isAccessible = true
                        val value = field.get(obj) ?: continue
                        if (field.name == fieldName && value.javaClass.name == targetClassName) {
                            if (!results.any { System.identityHashCode(it) == System.identityHashCode(value) }) {
                                results.add(value)
                            }
                        }
                        if (!field.type.isPrimitive && !field.type.isEnum) {
                            val tn = value.javaClass.name
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
}
