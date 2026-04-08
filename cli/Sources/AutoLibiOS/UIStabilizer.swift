import Foundation
import ApplicationServices
import AppKit

/// Monitors AX layout changes to detect when the UI has stabilized.
/// Uses AXObserver to get real-time notifications without polling.
public final class UIStabilizer {

    private var observer: AXObserver?
    private var lastChangeTime: CFAbsoluteTime = 0
    private var changeCount: Int = 0
    private let lock = NSLock()

    public init() {}

    /// Start observing AX changes for the Simulator process.
    public func attach(pid: pid_t) {
        var obs: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let result = AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let stabilizer = Unmanaged<UIStabilizer>.fromOpaque(refcon).takeUnretainedValue()
            stabilizer.lock.lock()
            stabilizer.lastChangeTime = CFAbsoluteTimeGetCurrent()
            stabilizer.changeCount += 1
            stabilizer.lock.unlock()
        }, &obs)

        guard result == .success, let obs else { return }

        let app = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(obs, app, kAXLayoutChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, app, kAXFocusedUIElementChangedNotification as CFString, refcon)
        AXObserverAddNotification(obs, app, kAXValueChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    /// Wait until no AX changes have occurred for `quietPeriod` seconds.
    /// Returns immediately if UI is already stable.
    /// Times out after `timeout` seconds.
    public func waitForStable(quietPeriod: TimeInterval = 0.15, timeout: TimeInterval = 5.0) {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout

        while CFAbsoluteTimeGetCurrent() < deadline {
            // Pump the run loop to receive AX notifications
            CFRunLoopRunInMode(.defaultMode, 0.05, true)

            lock.lock()
            let elapsed = CFAbsoluteTimeGetCurrent() - lastChangeTime
            lock.unlock()

            // If enough quiet time has passed, UI is stable
            if elapsed >= quietPeriod && lastChangeTime > 0 {
                return
            }

            // If no events received yet, short wait then return
            if lastChangeTime == 0 {
                usleep(100_000) // 100ms initial wait
                return
            }
        }
    }

    /// Reset the change counter (useful for tracking changes after an action).
    public func resetCounter() {
        lock.lock()
        changeCount = 0
        lastChangeTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    /// Number of changes since last reset.
    public var changes: Int {
        lock.lock()
        defer { lock.unlock() }
        return changeCount
    }

    public func detach() {
        observer = nil
    }
}
