#!/bin/bash
# Build camera-mock Kotlin sources into a standalone .dex file
# Requires: kotlinc (via Android Studio), Android SDK with build-tools and platforms
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

# Use Android Studio's bundled JDK if system Java not available
if ! java -version &>/dev/null 2>&1; then
    export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
fi

# Find kotlin-compiler.jar — prefer Android Studio's bundled version
KOTLIN_DIR=""
AS_KOTLIN="/Applications/Android Studio.app/Contents/plugins/Kotlin/kotlinc"
if [ -f "$AS_KOTLIN/lib/kotlin-compiler.jar" ]; then
    KOTLIN_DIR="$AS_KOTLIN"
elif command -v kotlinc &>/dev/null; then
    KOTLIN_DIR="$(dirname "$(dirname "$(command -v kotlinc)")")"
else
    echo "Error: Kotlin compiler not found. Install Kotlin or use Android Studio."
    exit 1
fi
COMPILER_JAR="$KOTLIN_DIR/lib/kotlin-compiler.jar"

# Find latest platform jar (android.jar)
PLATFORM_JAR=$(ls -d "$ANDROID_HOME/platforms/android-"* 2>/dev/null | sort -V | tail -1)/android.jar
if [ ! -f "$PLATFORM_JAR" ]; then
    echo "Error: android.jar not found in $ANDROID_HOME/platforms/"
    exit 1
fi

# Find d8 (DEX compiler)
D8=$(ls -d "$ANDROID_HOME/build-tools/"* 2>/dev/null | sort -V | tail -1)/d8
if [ ! -f "$D8" ]; then
    echo "Error: d8 not found in $ANDROID_HOME/build-tools/"
    exit 1
fi

# Find kotlin-stdlib.jar for compilation
KOTLIN_LIB=""
if [ -f "$KOTLIN_DIR/lib/kotlin-stdlib.jar" ]; then
    KOTLIN_LIB="$KOTLIN_DIR/lib/kotlin-stdlib.jar"
fi

BUILD_DIR="$SCRIPT_DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/classes"

echo "kotlin:   $KOTLIN_DIR"
echo "android:  $PLATFORM_JAR"
echo "d8:       $D8"
echo "stdlib:   ${KOTLIN_LIB:-none}"
echo ""

# Step 1: Compile Kotlin → .class files
echo "Compiling Kotlin..."
CP="$PLATFORM_JAR"
if [ -n "$KOTLIN_LIB" ]; then
    CP="$CP:$KOTLIN_LIB"
fi

java -jar "$COMPILER_JAR" \
    -d "$BUILD_DIR/classes" \
    -cp "$CP" \
    -jvm-target 17 \
    "$SCRIPT_DIR/src/"*.kt 2>&1

# Step 2: Convert .class → .dex
echo "Converting to DEX..."

# Collect all .class files + kotlin-stdlib for d8
CLASS_FILES=$(find "$BUILD_DIR/classes" -name "*.class" -type f)
if [ -n "$KOTLIN_LIB" ]; then
    "$D8" --min-api 26 --output "$BUILD_DIR/" $CLASS_FILES "$KOTLIN_LIB"
else
    "$D8" --min-api 26 --output "$BUILD_DIR/" $CLASS_FILES
fi

# Rename output
mv "$BUILD_DIR/classes.dex" "$BUILD_DIR/autopilot-camera-mock.dex"

echo ""
echo "Built:"
ls -lh "$BUILD_DIR/autopilot-camera-mock.dex"
echo ""
echo "Deploy to device:"
echo "  adb push $BUILD_DIR/autopilot-camera-mock.dex /data/local/tmp/"
