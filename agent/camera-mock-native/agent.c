/**
 * AutoPilot Camera Mock — JVMTI Agent
 *
 * Minimal native agent that loads a Kotlin DEX file into the target app's
 * process via DexClassLoader, then calls CameraHooks.install(imagePath).
 *
 * Usage:
 *   adb push libcameramock.so /data/local/tmp/
 *   adb push autopilot-camera-mock.dex /data/local/tmp/
 *   adb shell cmd activity attach-agent <package> \
 *       /data/local/tmp/libcameramock.so=/sdcard/autopilot/camera.jpg
 *
 * Requires: Android 8+ (API 26), debuggable app or ro.debuggable=1 (emulator)
 */

#include <jni.h>
#include <android/log.h>
#include <string.h>
#include <stdio.h>

#define TAG "AutoPilotCamera"
#define LOGD(...) __android_log_print(ANDROID_LOG_DEBUG, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

static const char *DEX_FILENAME = "autopilot-camera-mock.dex";
static const char *HOOKS_CLASS = "dev.autopilot.cameramock.CameraHooks";
static const char *DEFAULT_IMAGE = "/sdcard/autopilot/camera.jpg";

/**
 * Get the app's data directory via Context.getFilesDir().
 * Returns a JNI string like "/data/user/0/com.example.app/files".
 */
static jstring getAppDataDir(JNIEnv *env) {
    jclass atClass = (*env)->FindClass(env, "android/app/ActivityThread");
    if (!atClass) return NULL;

    jmethodID currentApp = (*env)->GetStaticMethodID(env, atClass,
        "currentApplication", "()Landroid/app/Application;");
    jobject app = (*env)->CallStaticObjectMethod(env, atClass, currentApp);
    if (!app) return NULL;

    jclass ctxClass = (*env)->FindClass(env, "android/content/Context");
    jmethodID getFilesDir = (*env)->GetMethodID(env, ctxClass,
        "getFilesDir", "()Ljava/io/File;");
    jobject filesDir = (*env)->CallObjectMethod(env, app, getFilesDir);
    if (!filesDir) return NULL;

    jclass fileClass = (*env)->FindClass(env, "java/io/File");
    jmethodID getParent = (*env)->GetMethodID(env, fileClass,
        "getParent", "()Ljava/lang/String;");
    return (jstring)(*env)->CallObjectMethod(env, filesDir, getParent);
}

/**
 * JVMTI entry point — called when the agent is attached to the target process.
 * options: path to mock image (e.g. "/sdcard/autopilot/camera.jpg")
 */
JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM *vm, char *options, void *reserved) {
    const char *imagePath = (options && strlen(options) > 0) ? options : DEFAULT_IMAGE;
    LOGD("Attaching camera mock agent. Image: %s", imagePath);

    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        LOGE("Failed to get JNIEnv");
        return JNI_ERR;
    }

    /* 0. Resolve DEX path relative to app's data directory */
    jstring jAppDir = getAppDataDir(env);
    if (!jAppDir) {
        LOGE("Failed to get app data dir");
        return JNI_ERR;
    }
    const char *appDir = (*env)->GetStringUTFChars(env, jAppDir, NULL);
    char dexPath[512];
    char optDir[512];
    snprintf(dexPath, sizeof(dexPath), "%s/%s", appDir, DEX_FILENAME);
    snprintf(optDir, sizeof(optDir), "%s/code_cache", appDir);
    LOGD("DEX path: %s, opt dir: %s", dexPath, optDir);
    (*env)->ReleaseStringUTFChars(env, jAppDir, appDir);

    /* 1. Get app's ClassLoader as parent for DexClassLoader.
     *    Using the app's classloader (not system) so our DEX can resolve
     *    app dependencies like androidx.camera.* (CameraX) via reflection. */
    jclass atClass2 = (*env)->FindClass(env, "android/app/ActivityThread");
    jmethodID currentApp2 = (*env)->GetStaticMethodID(env, atClass2,
        "currentApplication", "()Landroid/app/Application;");
    jobject app = (*env)->CallStaticObjectMethod(env, atClass2, currentApp2);

    jobject parentCL;
    if (app) {
        jclass ctxClass2 = (*env)->FindClass(env, "android/content/Context");
        jmethodID getCL = (*env)->GetMethodID(env, ctxClass2,
            "getClassLoader", "()Ljava/lang/ClassLoader;");
        parentCL = (*env)->CallObjectMethod(env, app, getCL);
        LOGD("Using app classloader as DexClassLoader parent");
    } else {
        jclass clClass = (*env)->FindClass(env, "java/lang/ClassLoader");
        jmethodID getSysCL = (*env)->GetStaticMethodID(env, clClass,
            "getSystemClassLoader", "()Ljava/lang/ClassLoader;");
        parentCL = (*env)->CallStaticObjectMethod(env, clClass, getSysCL);
        LOGD("Falling back to system classloader");
    }

    /* 1b. Bypass hidden API restrictions (Android 9+).
     *     Our Camera2Interceptor needs to access ImageReader.mListener which is
     *     a hidden field blocked by default. VMRuntime.setHiddenApiExemptions(["L"])
     *     exempts all classes — same approach as FreeReflection/VCAM. */
    {
        jclass vmRuntimeClass = (*env)->FindClass(env, "dalvik/system/VMRuntime");
        if (vmRuntimeClass) {
            jmethodID getRuntime = (*env)->GetStaticMethodID(env, vmRuntimeClass,
                "getRuntime", "()Ldalvik/system/VMRuntime;");
            if (getRuntime) {
                jobject runtime = (*env)->CallStaticObjectMethod(env, vmRuntimeClass, getRuntime);
                if (runtime) {
                    jmethodID setExemptions = (*env)->GetMethodID(env, vmRuntimeClass,
                        "setHiddenApiExemptions", "([Ljava/lang/String;)V");
                    if (setExemptions) {
                        jclass stringClass = (*env)->FindClass(env, "java/lang/String");
                        jobjectArray exemptions = (*env)->NewObjectArray(env, 1, stringClass,
                            (*env)->NewStringUTF(env, "L"));
                        (*env)->CallVoidMethod(env, runtime, setExemptions, exemptions);
                        LOGD("Hidden API exemptions set (all classes)");
                    }
                }
            }
        }
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionDescribe(env);
            (*env)->ExceptionClear(env);
            LOGD("Hidden API bypass failed (non-fatal, may work on some devices)");
        }
    }

    /* 2. Create DexClassLoader to load our Kotlin hooks */
    jclass dexCLClass = (*env)->FindClass(env, "dalvik/system/DexClassLoader");
    if (!dexCLClass) { LOGE("DexClassLoader not found"); return JNI_ERR; }

    jmethodID dexCLInit = (*env)->GetMethodID(env, dexCLClass, "<init>",
        "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;Ljava/lang/ClassLoader;)V");

    jstring jDexPath = (*env)->NewStringUTF(env, dexPath);
    jstring jOptDir = (*env)->NewStringUTF(env, optDir);

    jobject dexLoader = (*env)->NewObject(env, dexCLClass, dexCLInit,
        jDexPath, jOptDir, NULL, parentCL);

    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        LOGE("Failed to create DexClassLoader");
        return JNI_ERR;
    }

    /* 3. Load CameraHooks class from the DEX */
    jmethodID loadClass = (*env)->GetMethodID(env, dexCLClass,
        "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");

    jstring jClassName = (*env)->NewStringUTF(env, HOOKS_CLASS);
    jclass hooksClass = (jclass)(*env)->CallObjectMethod(env, dexLoader,
        loadClass, jClassName);

    if ((*env)->ExceptionCheck(env) || !hooksClass) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        LOGE("Failed to load %s", HOOKS_CLASS);
        return JNI_ERR;
    }

    /* 4. Call CameraHooks.install(imagePath) */
    jmethodID installMethod = (*env)->GetStaticMethodID(env, hooksClass,
        "install", "(Ljava/lang/String;)V");

    if (!installMethod) {
        LOGE("CameraHooks.install(String) not found");
        return JNI_ERR;
    }

    jstring jImagePath = (*env)->NewStringUTF(env, imagePath);
    (*env)->CallStaticVoidMethod(env, hooksClass, installMethod, jImagePath);

    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        LOGE("CameraHooks.install() threw exception");
        return JNI_ERR;
    }

    LOGD("Camera mock installed successfully");
    return JNI_OK;
}
