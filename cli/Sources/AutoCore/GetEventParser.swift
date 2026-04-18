import Foundation

// MARK: - Touch Calibration

/// Maps raw kernel touchscreen coordinates to logical screen pixels.
/// Raw values come from `adb shell getevent -p` (ABS_MT_POSITION_X/Y min/max).
/// Screen size comes from `adb shell wm size`.
public struct TouchCalibration {
    public let minX: Int
    public let maxX: Int
    public let minY: Int
    public let maxY: Int
    public let screenWidth: Int
    public let screenHeight: Int

    public init(minX: Int, maxX: Int, minY: Int, maxY: Int, screenWidth: Int, screenHeight: Int) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }

    /// Transform raw hardware coordinates to logical screen coordinates.
    public func transform(rawX: Int, rawY: Int) -> (x: Int, y: Int) {
        let rangeX = maxX - minX
        let rangeY = maxY - minY
        guard rangeX > 0, rangeY > 0 else { return (rawX, rawY) }

        let x = (rawX - minX) * screenWidth / rangeX
        let y = (rawY - minY) * screenHeight / rangeY
        return (max(0, min(screenWidth, x)), max(0, min(screenHeight, y)))
    }

    /// Parse calibration from `adb shell getevent -p` and `adb shell wm size` output.
    public static func parse(getEventInfo: String, wmSize: String) -> TouchCalibration? {
        // Parse screen size: "Physical size: 1080x2400"
        var screenW = 1080, screenH = 2400
        for line in wmSize.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match "Physical size:" or "Override size:" or just "NxN"
            if let match = trimmed.range(of: #"(\d+)x(\d+)"#, options: .regularExpression) {
                let dims = trimmed[match].split(separator: "x")
                if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) {
                    screenW = w
                    screenH = h
                    break
                }
            }
        }

        // Parse getevent -p for touchscreen device
        // Look for ABS_MT_POSITION_X and ABS_MT_POSITION_Y ranges
        var minX = 0, maxX = 32767
        var minY = 0, maxY = 32767

        // getevent -p format:
        //   0035  : value 0, min 0, max 32767, fuzz 0, flat 0, resolution 0
        //   0036  : value 0, min 0, max 32767, fuzz 0, flat 0, resolution 0
        // The hex code and range are on the SAME line.
        // 0035 = ABS_MT_POSITION_X, 0036 = ABS_MT_POSITION_Y
        // Must match exactly "0035  :" to avoid matching 0037 etc.
        let lines = getEventInfo.components(separatedBy: .newlines)
        var foundX = false, foundY = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Match "0035  : value..." (ABS_MT_POSITION_X) — values on same line
            if !foundX && (trimmed.hasPrefix("0035") && trimmed.contains("min") && trimmed.contains("max")) {
                if let range = parseAbsRange(trimmed) {
                    minX = range.min
                    maxX = range.max
                    foundX = true
                }
            }

            // Match "0036  : value..." (ABS_MT_POSITION_Y)
            if !foundY && (trimmed.hasPrefix("0036") && trimmed.contains("min") && trimmed.contains("max")) {
                if let range = parseAbsRange(trimmed) {
                    minY = range.min
                    maxY = range.max
                    foundY = true
                }
            }

            if foundX && foundY { break }
        }

        return TouchCalibration(
            minX: minX, maxX: maxX,
            minY: minY, maxY: maxY,
            screenWidth: screenW, screenHeight: screenH
        )
    }

    /// Parse "value N, min N, max N, ..." line from getevent -p
    private static func parseAbsRange(_ line: String) -> (min: Int, max: Int)? {
        var minVal: Int?
        var maxVal: Int?

        let parts = line.components(separatedBy: ",")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("min ") {
                minVal = Int(trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces))
            } else if trimmed.hasPrefix("max ") {
                maxVal = Int(trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces))
            }
        }

        if let min = minVal, let max = maxVal {
            return (min, max)
        }
        return nil
    }
}

// MARK: - Raw Event Types

public enum AndroidTouchPhase {
    case down(x: Int, y: Int)   // finger touched screen
    case move(x: Int, y: Int)   // finger moved
    case up                      // finger lifted
}

public struct AndroidRawEvent {
    public let phase: AndroidTouchPhase
    public let timestamp: Double   // kernel timestamp in seconds
}

// MARK: - GetEvent Parser

/// Parses `adb shell getevent -lt` output line-by-line into touch events.
///
/// getevent output format:
/// ```
/// [  12345.678901] /dev/input/event2: EV_ABS  ABS_MT_POSITION_X    00001f4a
/// [  12345.678901] /dev/input/event2: EV_KEY  BTN_TOUCH            DOWN
/// [  12345.678901] /dev/input/event2: EV_SYN  SYN_REPORT           00000000
/// ```
public final class GetEventParser {

    private let calibration: TouchCalibration

    // Accumulate position within a SYN_REPORT frame
    private var currentRawX: Int?
    private var currentRawY: Int?
    private var currentTimestamp: Double = 0
    private var touchIsDown = false
    private var positionUpdated = false

    // Last known position (for UP events that don't carry coordinates)
    private var lastX: Int = 0
    private var lastY: Int = 0

    public init(calibration: TouchCalibration) {
        self.calibration = calibration
    }

    /// Parse a single line from getevent output.
    /// Returns an event when a SYN_REPORT completes a touch frame.
    public func parseLine(_ line: String) -> AndroidRawEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Parse timestamp: [  12345.678901]
        var timestamp = currentTimestamp
        if let tsStart = trimmed.firstIndex(of: "["),
           let tsEnd = trimmed.firstIndex(of: "]") {
            let tsStr = trimmed[trimmed.index(after: tsStart)..<tsEnd]
                .trimmingCharacters(in: .whitespaces)
            if let ts = Double(tsStr) {
                timestamp = ts
                currentTimestamp = ts
            }
        }

        // Parse event type and code
        if trimmed.contains("ABS_MT_POSITION_X") || trimmed.contains("ABS (0035)") {
            if let hex = extractHexValue(trimmed) {
                currentRawX = hex
                positionUpdated = true
            }
        } else if trimmed.contains("ABS_MT_POSITION_Y") || trimmed.contains("ABS (0036)") {
            if let hex = extractHexValue(trimmed) {
                currentRawY = hex
                positionUpdated = true
            }
        } else if trimmed.contains("BTN_TOUCH") {
            if trimmed.contains("DOWN") {
                touchIsDown = true
            } else if trimmed.contains("UP") {
                touchIsDown = false
            }
        } else if trimmed.contains("ABS_MT_TRACKING_ID") {
            if let hex = extractHexValue(trimmed) {
                if hex == 0xFFFFFFFF || hex == -1 {
                    touchIsDown = false
                } else {
                    // Positive tracking ID = new finger down
                    touchIsDown = true
                }
            }
        } else if trimmed.contains("SYN_REPORT") {
            // End of event frame — emit event if we have data
            return emitFrame(timestamp: timestamp)
        }

        return nil
    }

    // MARK: - Private

    // Track whether we already emitted a down for the current touch
    private var hasEmittedDown = false

    private func emitFrame(timestamp: Double) -> AndroidRawEvent? {
        defer {
            positionUpdated = false
        }

        if !touchIsDown {
            // Touch up — only emit if we had a down
            if hasEmittedDown {
                hasEmittedDown = false
                currentRawX = nil
                currentRawY = nil
                return AndroidRawEvent(phase: .up, timestamp: timestamp)
            }
            return nil
        }

        // Touch is down — need coordinates
        guard let rawX = currentRawX, let rawY = currentRawY else { return nil }
        let (x, y) = calibration.transform(rawX: rawX, rawY: rawY)
        lastX = x
        lastY = y

        if !hasEmittedDown {
            // First frame with coordinates = touch down
            hasEmittedDown = true
            return AndroidRawEvent(phase: .down(x: x, y: y), timestamp: timestamp)
        } else if positionUpdated {
            // Subsequent frames with new position = move
            return AndroidRawEvent(phase: .move(x: x, y: y), timestamp: timestamp)
        }

        return nil
    }

    /// Extract hex value from the end of a getevent line.
    /// "EV_ABS  ABS_MT_POSITION_X    00001f4a" → 0x1f4a = 8010
    private func extractHexValue(_ line: String) -> Int? {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let last = parts.last else { return nil }
        let hexStr = String(last)

        // Try hex first (getevent -lt uses hex for ABS values)
        if let val = UInt32(hexStr, radix: 16) {
            // Handle signed values (tracking ID ffffffff = -1)
            if val > 0x7FFFFFFF {
                return Int(Int32(bitPattern: val))
            }
            return Int(val)
        }

        // Try decimal
        if let val = Int(hexStr) {
            return val
        }

        return nil
    }
}
