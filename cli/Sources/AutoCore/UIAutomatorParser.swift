import Foundation

/// Parses Android uiautomator XML dump into the [[String: Any]] tree format
/// used by TreePrinter and CommandDispatcher.
public final class UIAutomatorParser: NSObject, XMLParserDelegate {

    private var stack: [NSMutableDictionary] = []
    private var rootNodes: [[String: Any]] = []
    private var parseError: Error?

    /// Parse uiautomator XML string into element tree.
    public static func parse(_ xml: String) throws -> [[String: Any]] {
        // Strip preamble and suffix from uiautomator output
        var cleanXML = xml

        // Strip prefix: find start of XML
        if let xmlStart = xml.range(of: "<?xml") {
            cleanXML = String(xml[xmlStart.lowerBound...])
        } else if let hierStart = xml.range(of: "<hierarchy") {
            cleanXML = String(xml[hierStart.lowerBound...])
        } else {
            throw BridgeError.adbFailed("Invalid uiautomator XML output")
        }

        // Strip suffix: "UI hierchary dumped to: ..." appended after </hierarchy>
        if let hierEnd = cleanXML.range(of: "</hierarchy>") {
            cleanXML = String(cleanXML[cleanXML.startIndex..<hierEnd.upperBound])
        }

        guard let data = cleanXML.data(using: .utf8) else {
            throw BridgeError.adbFailed("Failed to encode XML as UTF-8")
        }

        let handler = UIAutomatorParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()

        if let error = handler.parseError {
            throw BridgeError.adbFailed("XML parse error: \(error.localizedDescription)")
        }

        return handler.rootNodes
    }

    // MARK: - XMLParserDelegate

    public func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?,
        attributes: [String: String]
    ) {
        guard elementName == "node" else { return }

        let node = NSMutableDictionary()

        // Map Android attributes to iOS-compatible format
        let className = attributes["class"] ?? ""
        node["role"] = stripPackagePrefix(className)
        node["title"] = attributes["text"] ?? ""
        node["label"] = attributes["content-desc"] ?? ""
        node["identifier"] = attributes["resource-id"] ?? ""
        node["value"] = attributes["text"] ?? ""
        node["enabled"] = attributes["enabled"] == "true"
        node["clickable"] = attributes["clickable"] == "true"
        node["scrollable"] = attributes["scrollable"] == "true"
        node["focused"] = attributes["focused"] == "true"
        node["package"] = attributes["package"] ?? ""

        // Parse bounds "[x1,y1][x2,y2]"
        if let bounds = attributes["bounds"] {
            node["frame"] = parseBounds(bounds)
        }

        // Store raw bounds string for coordinate calculations
        node["_bounds"] = attributes["bounds"] ?? ""
        node["children"] = NSMutableArray()

        stack.append(node)
    }

    public func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard elementName == "node" else { return }
        guard let node = stack.popLast() else { return }

        // Convert mutable children to immutable
        let children = (node["children"] as? NSMutableArray)?.compactMap { $0 as? [String: Any] } ?? []
        node["children"] = children

        let dict = node as! [String: Any]

        if let parent = stack.last {
            (parent["children"] as? NSMutableArray)?.add(dict)
        } else {
            rootNodes.append(dict)
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred error: Error) {
        parseError = error
    }

    // MARK: - Helpers

    /// "android.widget.TextView" → "TextView"
    private func stripPackagePrefix(_ className: String) -> String {
        if let lastDot = className.lastIndex(of: ".") {
            return String(className[className.index(after: lastDot)...])
        }
        return className
    }

    /// "[0,66][1080,1920]" → ["x": 0, "y": 66, "width": 1080, "height": 1854]
    private func parseBounds(_ bounds: String) -> [String: Int] {
        // Pattern: [x1,y1][x2,y2]
        let numbers = bounds
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .compactMap { Int($0) }

        guard numbers.count == 4 else { return [:] }

        let x1 = numbers[0], y1 = numbers[1], x2 = numbers[2], y2 = numbers[3]
        return [
            "x": x1,
            "y": y1,
            "width": x2 - x1,
            "height": y2 - y1
        ]
    }
}
