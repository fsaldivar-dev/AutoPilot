import Foundation
import ApplicationServices

// MARK: - Raw Event Types

public enum RawEventKind {
    case mouseDown
    case mouseUp
    case keyDown(UInt16)           // virtual key code
    case scrollWheel(deltaY: Double)
}

public struct RawEvent {
    public let kind: RawEventKind
    public let location: CGPoint   // screen coordinates
    public let timestamp: CFAbsoluteTime
    public let flags: CGEventFlags
}

// MARK: - EventRecorder

/// Passively captures mouse/keyboard events targeting the Simulator.
/// Uses CGEventTap in `.listenOnly` mode — never blocks or modifies events.
public final class EventRecorder {

    public typealias EventHandler = (RawEvent) -> Void

    private let simulatorPID: pid_t
    private var handler: EventHandler?
    private var thread: Thread?
    private var tapRunLoop: CFRunLoop?
    fileprivate var eventTap: CFMachPort?
    private let lock = NSLock()

    /// Window frame for coordinate-based filtering (more reliable than PID filtering)
    public var windowFrame: CGRect = .zero

    public init(simulatorPID: pid_t) {
        self.simulatorPID = simulatorPID
    }

    public func start(handler: @escaping EventHandler) {
        self.handler = handler

        let thread = Thread {
            self.runEventLoop()
        }
        thread.name = "autopilot.event-recorder"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    public func stop() {
        lock.lock()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }
        lock.unlock()

        thread = nil
        eventTap = nil
        tapRunLoop = nil
        handler = nil
    }

    // MARK: - Private

    private func runEventLoop() {
        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        // Store self as unretained pointer for the C callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventCallback,
            userInfo: refcon
        ) else {
            fputs("[record] ERROR: CGEvent.tapCreate failed. Grant Accessibility permissions.\n", stderr)
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let currentRunLoop = CFRunLoopGetCurrent()!

        lock.lock()
        self.eventTap = tap
        self.tapRunLoop = currentRunLoop
        lock.unlock()

        CFRunLoopAddSource(currentRunLoop, runLoopSource, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)

        // Block this thread pumping events
        CFRunLoopRun()
    }

    /// Decide la delta Y normalizada (en unidades de línea) para un scroll event.
    ///
    /// **#50**: el trackpad smooth scroll emite `scrollWheelEventDeltaAxis1 = 0`
    /// y pone la delta real (en píxeles) en `scrollWheelEventPointDeltaAxis1`.
    /// Mouse wheel tradicional usa el primero. Preferimos `lineDelta` si no-cero;
    /// fallback a `pointDelta / 10` (~10px ≈ 1 línea) para mantener semántica
    /// consistente con el resto del recorder.
    ///
    /// Función pura para poder testearla sin CGEvent real.
    public static func scrollDeltaYFrom(lineDelta: Double, pointDelta: Double) -> Double {
        if abs(lineDelta) > 0 { return lineDelta }
        return pointDelta / 10.0
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) {
        let location = event.location

        // Filter mouse events by Simulator window bounds (more reliable than PID)
        if type == .leftMouseDown || type == .leftMouseUp || type == .scrollWheel {
            guard windowFrame != .zero && windowFrame.contains(location) else { return }
        }
        let timestamp = CFAbsoluteTimeGetCurrent()
        let flags = event.flags

        let kind: RawEventKind
        switch type {
        case .leftMouseDown:
            kind = .mouseDown
        case .leftMouseUp:
            kind = .mouseUp
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            kind = .keyDown(keyCode)
        case .scrollWheel:
            let lineDelta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let pointDelta = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            kind = .scrollWheel(deltaY: EventRecorder.scrollDeltaYFrom(lineDelta: lineDelta, pointDelta: pointDelta))
        default:
            return
        }

        let rawEvent = RawEvent(kind: kind, location: location, timestamp: timestamp, flags: flags)
        handler?(rawEvent)
    }
}

// MARK: - C Callback

private func eventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }

    // Re-enable tap if it gets disabled by the system (happens under load)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let recorder = Unmanaged<EventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
        if let tap = recorder.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let recorder = Unmanaged<EventRecorder>.fromOpaque(userInfo).takeUnretainedValue()
    recorder.handleEvent(proxy, type, event)

    return Unmanaged.passUnretained(event)
}
