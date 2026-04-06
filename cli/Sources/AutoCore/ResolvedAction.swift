import Foundation

/// A resolved user action with a semantic selector.
/// Shared between iOS and Android recorders.
public struct ResolvedAction {
    public let command: String        // "tap", "longPress", "doubleTap", "type", "scroll", "tapAt"
    public let selector: String       // "Login", "Camera[2]", "loginBtn", "308 515"
    public let role: String?          // "button" (short form for [role] syntax)
    public let within: String?        // scope parent label
    public let occurrence: Int?       // nil if unique, N if label[N]
    public let identifier: String?    // accessibility identifier (when available)
    public let fragile: Bool          // true if no identifier and needs occurrence
    public let coordinate: CGPoint    // original touch coordinate (fallback)

    public init(
        command: String,
        selector: String,
        role: String?,
        within: String?,
        occurrence: Int?,
        identifier: String?,
        fragile: Bool,
        coordinate: CGPoint
    ) {
        self.command = command
        self.selector = selector
        self.role = role
        self.within = within
        self.occurrence = occurrence
        self.identifier = identifier
        self.fragile = fragile
        self.coordinate = coordinate
    }
}
