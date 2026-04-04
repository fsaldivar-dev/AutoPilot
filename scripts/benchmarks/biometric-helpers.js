// Helper para Maestro: biometric via xcrun simctl
// Maestro no tiene comandos nativos de biometric,
// asi que usamos runScript con java.lang.Runtime

const action = ACTION;

if (action === 'unenroll') {
    java.lang.Runtime.getRuntime()
        .exec('xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 0')
        .waitFor();
} else if (action === 'enroll') {
    java.lang.Runtime.getRuntime()
        .exec('xcrun simctl spawn booted notifyutil -s com.apple.BiometricKit.enrollmentChanged 1')
        .waitFor();
} else if (action === 'match') {
    java.lang.Runtime.getRuntime()
        .exec('xcrun simctl spawn booted notifyutil -p com.apple.BiometricKit.fingerTouch.ack')
        .waitFor();
}
