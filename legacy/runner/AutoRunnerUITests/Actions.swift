import XCTest

/// Executes UI actions on elements found by the ElementInspector.
final class Actions {

    private let inspector: ElementInspector
    private let app: XCUIApplication

    init(app: XCUIApplication, inspector: ElementInspector) {
        self.app = app
        self.inspector = inspector
    }

    // MARK: - Tap

    func tap(target: String) throws -> [String: Any] {
        guard let element = inspector.findElement(target) else {
            throw ActionError.elementNotFound(target)
        }
        element.tap()
        return ["action": "tap", "target": target]
    }

    func doubleTap(target: String) throws -> [String: Any] {
        guard let element = inspector.findElement(target) else {
            throw ActionError.elementNotFound(target)
        }
        element.doubleTap()
        return ["action": "doubleTap", "target": target]
    }

    func longPress(target: String, duration: Double) throws -> [String: Any] {
        guard let element = inspector.findElement(target) else {
            throw ActionError.elementNotFound(target)
        }
        element.press(forDuration: duration)
        return ["action": "longPress", "target": target, "duration": duration]
    }

    // MARK: - Type text

    func typeText(target: String?, text: String) throws -> [String: Any] {
        if let target = target {
            guard let element = inspector.findElement(target) else {
                throw ActionError.elementNotFound(target)
            }
            element.tap()
            element.typeText(text)
        } else {
            // Type into currently focused element
            app.typeText(text)
        }
        return ["action": "type", "text": text]
    }

    // MARK: - Swipe

    func swipe(direction: String, target: String?) throws -> [String: Any] {
        let element: XCUIElement
        if let target = target {
            guard let found = inspector.findElement(target) else {
                throw ActionError.elementNotFound(target)
            }
            element = found
        } else {
            element = app
        }

        switch direction.lowercased() {
        case "up": element.swipeUp()
        case "down": element.swipeDown()
        case "left": element.swipeLeft()
        case "right": element.swipeRight()
        default: throw ActionError.invalidDirection(direction)
        }

        return ["action": "swipe", "direction": direction]
    }

    // MARK: - Screenshot

    func screenshot() -> [String: Any] {
        let screenshot = XCUIScreen.main.screenshot()
        let pngData = screenshot.pngRepresentation
        let base64 = pngData.base64EncodedString()
        return ["action": "screenshot", "data": base64, "format": "png"]
    }

    // MARK: - App lifecycle

    func launch(bundleId: String) -> [String: Any] {
        let targetApp = XCUIApplication(bundleIdentifier: bundleId)
        targetApp.launch()
        return ["action": "launch", "bundleId": bundleId]
    }

    func terminate(bundleId: String) -> [String: Any] {
        let targetApp = XCUIApplication(bundleIdentifier: bundleId)
        targetApp.terminate()
        return ["action": "terminate", "bundleId": bundleId]
    }

    // MARK: - Wait

    func waitFor(target: String, timeout: Double) throws -> [String: Any] {
        let predicate = NSPredicate(format: "exists == true")
        let element: XCUIElement

        if let found = inspector.findByIdentifier(target) {
            element = found
        } else {
            // Create a query that will resolve when the element appears
            element = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier == %@ OR label == %@", target, target))
                .firstMatch
        }

        let result = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let waitResult = XCTWaiter.wait(for: [result], timeout: timeout)

        if waitResult == .completed {
            return ["action": "waitFor", "target": target, "found": true]
        } else {
            throw ActionError.waitTimeout(target, timeout)
        }
    }

    // MARK: - Element queries

    func exists(target: String) -> [String: Any] {
        let found = inspector.findElement(target) != nil
        return ["action": "exists", "target": target, "exists": found]
    }

    func getAttribute(target: String, attribute: String) throws -> [String: Any] {
        guard let element = inspector.findElement(target) else {
            throw ActionError.elementNotFound(target)
        }

        var value: Any = ""
        switch attribute.lowercased() {
        case "label": value = element.label
        case "value": value = element.value ?? ""
        case "identifier": value = element.identifier
        case "enabled": value = element.isEnabled
        case "selected": value = element.isSelected
        case "frame":
            let f = element.frame
            value = ["x": Int(f.origin.x), "y": Int(f.origin.y),
                     "width": Int(f.size.width), "height": Int(f.size.height)]
        case "placeholder": value = element.placeholderValue ?? ""
        default: throw ActionError.unknownAttribute(attribute)
        }

        return ["action": "getAttribute", "target": target, "attribute": attribute, "value": value]
    }
}

// MARK: - Errors

enum ActionError: Error, CustomStringConvertible {
    case elementNotFound(String)
    case invalidDirection(String)
    case waitTimeout(String, Double)
    case unknownAttribute(String)

    var description: String {
        switch self {
        case .elementNotFound(let t): return "Element not found: \(t)"
        case .invalidDirection(let d): return "Invalid swipe direction: \(d). Use up/down/left/right"
        case .waitTimeout(let t, let s): return "Timeout waiting for '\(t)' after \(s)s"
        case .unknownAttribute(let a): return "Unknown attribute: \(a)"
        }
    }
}
