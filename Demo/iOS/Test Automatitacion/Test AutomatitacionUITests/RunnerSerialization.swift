import Foundation
import XCTest

// MARK: - Element Serialization
//
// Converts XCUIElement tree into JSON-compatible dictionaries.
// Output format matches ElementIndexShared.swift expectations:
//   { role, label, identifier, value, frame, enabled, children }

extension RunnerHandlers {

    /// Serialize the full element tree starting from a root element.
    func serializeElement(_ element: XCUIElement, depth: Int = 0, maxDepth: Int = 15) -> [String: Any] {
        var dict = serializeSingleElement(element)

        if depth < maxDepth {
            var children: [[String: Any]] = []
            // Query all direct children
            let childCount = element.children(matching: .any).count
            for i in 0..<min(childCount, 200) { // Cap at 200 per level
                let child = element.children(matching: .any).element(boundBy: i)
                if child.exists {
                    children.append(serializeElement(child, depth: depth + 1, maxDepth: maxDepth))
                }
            }
            if !children.isEmpty {
                dict["children"] = children
            }
        }

        return dict
    }

    /// Serialize a single element (no children).
    func serializeSingleElement(_ element: XCUIElement) -> [String: Any] {
        var dict: [String: Any] = [:]

        // Role — map XCUIElement.ElementType to string matching AutoPilot conventions
        dict["role"] = roleString(for: element.elementType)

        // Label (accessibility label / description)
        let label = element.label
        if !label.isEmpty { dict["label"] = label }

        // Identifier (accessibility identifier)
        let identifier = element.identifier
        if !identifier.isEmpty { dict["identifier"] = identifier }

        // Value
        if let value = element.value {
            let valueStr = "\(value)"
            if !valueStr.isEmpty { dict["value"] = valueStr }
        }

        // Title (often same as label for buttons, but can differ)
        let title = element.title
        if !title.isEmpty && title != label { dict["title"] = title }

        // Frame — format matching SimulatorBridge: [x, y, width, height]
        let frame = element.frame
        if frame != .zero {
            dict["frame"] = [
                "x": Int(frame.origin.x),
                "y": Int(frame.origin.y),
                "width": Int(frame.size.width),
                "height": Int(frame.size.height)
            ]
        }

        // Enabled
        dict["enabled"] = element.isEnabled

        // Placeholder (for text fields)
        if let placeholder = element.placeholderValue, !placeholder.isEmpty {
            dict["placeholder"] = placeholder
        }

        return dict
    }

    /// Map XCUIElement.ElementType to a string matching AutoPilot/SimulatorBridge conventions.
    private func roleString(for type: XCUIElement.ElementType) -> String {
        switch type {
        case .application:    return "Application"
        case .window:         return "Window"
        case .group:          return "Group"
        case .button:         return "Button"
        case .staticText:     return "StaticText"
        case .textField:      return "TextField"
        case .secureTextField: return "SecureTextField"
        case .image:          return "Image"
        case .cell:           return "Cell"
        case .table:          return "Table"
        case .collectionView: return "CollectionView"
        case .scrollView:     return "ScrollView"
        case .navigationBar:  return "NavigationBar"
        case .tabBar:         return "TabBar"
        case .toolbar:        return "Toolbar"
        case .switch:         return "Switch"
        case .slider:         return "Slider"
        case .picker:         return "Picker"
        case .alert:          return "Alert"
        case .sheet:          return "Sheet"
        case .link:           return "Link"
        case .menuItem:       return "MenuItem"
        case .menu:           return "Menu"
        case .webView:        return "WebView"
        case .searchField:    return "SearchField"
        case .segmentedControl: return "SegmentedControl"
        case .activityIndicator: return "ActivityIndicator"
        case .pageIndicator:  return "PageIndicator"
        case .progressIndicator: return "ProgressIndicator"
        case .stepper:        return "Stepper"
        case .textView:       return "TextView"
        case .datePicker:     return "DatePicker"
        case .popover:        return "Popover"
        case .map:            return "Map"
        case .toggle:         return "Toggle"
        case .other:          return "Other"
        default:              return "Other"
        }
    }
}
