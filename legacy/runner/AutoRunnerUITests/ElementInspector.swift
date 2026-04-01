import XCTest

/// Reads the accessibility tree from XCUIApplication and serializes it to JSON-compatible dictionaries.
final class ElementInspector {

    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    // MARK: - Full tree

    /// Returns the complete accessibility tree as a dictionary.
    func tree() -> [[String: Any]] {
        return serializeChildren(of: app)
    }

    // MARK: - Search

    /// Searches the tree for elements matching a query string.
    /// Matches against identifier, label, and element type.
    func search(query: String) -> [[String: Any]] {
        let lowered = query.lowercased()
        var results: [[String: Any]] = []
        searchRecursive(element: app, query: lowered, results: &results)
        return results
    }

    // MARK: - Element at coordinate

    /// Returns the element at a given screen coordinate.
    func elementAt(x: Double, y: Double) -> [String: Any]? {
        let point = CGPoint(x: x, y: y)
        return findElementAt(point: point, in: app)
    }

    // MARK: - Find element by identifier or label

    /// Finds an element by accessibility identifier.
    func findByIdentifier(_ identifier: String) -> XCUIElement? {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier))
        let element = query.firstMatch
        return element.exists ? element : nil
    }

    /// Finds an element by label text.
    func findByLabel(_ label: String) -> XCUIElement? {
        let query = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
        let element = query.firstMatch
        return element.exists ? element : nil
    }

    /// Finds an element by identifier first, then falls back to label.
    func findElement(_ target: String) -> XCUIElement? {
        if let el = findByIdentifier(target) { return el }
        if let el = findByLabel(target) { return el }
        return nil
    }

    // MARK: - Serialization

    private func serializeElement(_ element: XCUIElement) -> [String: Any] {
        let frame = element.frame
        var dict: [String: Any] = [
            "type": elementTypeName(element.elementType),
            "identifier": element.identifier,
            "label": element.label,
            "enabled": element.isEnabled,
            "frame": [
                "x": Int(frame.origin.x),
                "y": Int(frame.origin.y),
                "width": Int(frame.size.width),
                "height": Int(frame.size.height)
            ]
        ]

        if !element.value.debugDescription.contains("nil") {
            if let strValue = element.value as? String {
                dict["value"] = strValue
            }
        }

        if !element.placeholderValue.debugDescription.contains("nil") {
            if let placeholder = element.placeholderValue {
                dict["placeholder"] = placeholder
            }
        }

        return dict
    }

    private func serializeChildren(of element: XCUIElement) -> [[String: Any]] {
        var results: [[String: Any]] = []

        for i in 0..<element.children(matching: .any).count {
            let child = element.children(matching: .any).element(boundBy: i)

            guard child.exists else { continue }

            var dict = serializeElement(child)

            let children = serializeChildren(of: child)
            if !children.isEmpty {
                dict["children"] = children
            }

            results.append(dict)
        }

        return results
    }

    private func searchRecursive(element: XCUIElement, query: String, results: inout [[String: Any]]) {
        for i in 0..<element.children(matching: .any).count {
            let child = element.children(matching: .any).element(boundBy: i)
            guard child.exists else { continue }

            let matches = child.identifier.lowercased().contains(query)
                || child.label.lowercased().contains(query)
                || elementTypeName(child.elementType).lowercased().contains(query)

            if matches {
                results.append(serializeElement(child))
            }

            searchRecursive(element: child, query: query, results: &results)
        }
    }

    private func findElementAt(point: CGPoint, in element: XCUIElement) -> [String: Any]? {
        var bestMatch: (element: XCUIElement, area: CGFloat)?

        for i in 0..<element.children(matching: .any).count {
            let child = element.children(matching: .any).element(boundBy: i)
            guard child.exists else { continue }

            let frame = child.frame
            if frame.contains(point) {
                let area = frame.width * frame.height

                // Prefer the smallest (most specific) element containing the point
                if bestMatch == nil || area < bestMatch!.area {
                    bestMatch = (child, area)
                }

                // Search deeper
                if let deeper = findElementAt(point: point, in: child) {
                    return deeper
                }
            }
        }

        if let match = bestMatch {
            return serializeElement(match.element)
        }
        return nil
    }

    // MARK: - Type names

    private func elementTypeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .button: return "Button"
        case .staticText: return "StaticText"
        case .textField: return "TextField"
        case .secureTextField: return "SecureTextField"
        case .image: return "Image"
        case .switch: return "Switch"
        case .slider: return "Slider"
        case .cell: return "Cell"
        case .table: return "Table"
        case .collectionView: return "CollectionView"
        case .scrollView: return "ScrollView"
        case .navigationBar: return "NavigationBar"
        case .tabBar: return "TabBar"
        case .toolbar: return "Toolbar"
        case .window: return "Window"
        case .alert: return "Alert"
        case .sheet: return "Sheet"
        case .other: return "Other"
        case .application: return "Application"
        case .group: return "Group"
        case .link: return "Link"
        case .picker: return "Picker"
        case .searchField: return "SearchField"
        case .textView: return "TextView"
        case .webView: return "WebView"
        case .map: return "Map"
        case .toggle: return "Toggle"
        case .activityIndicator: return "ActivityIndicator"
        case .pageIndicator: return "PageIndicator"
        case .progressIndicator: return "ProgressIndicator"
        case .segmentedControl: return "SegmentedControl"
        case .stepper: return "Stepper"
        case .datePicker: return "DatePicker"
        case .menu: return "Menu"
        case .menuItem: return "MenuItem"
        case .menuButton: return "MenuButton"
        case .popUpButton: return "PopUpButton"
        case .icon: return "Icon"
        @unknown default: return "Unknown(\(type.rawValue))"
        }
    }
}
