import Foundation

// MARK: - ViewFingerprint
//
// Cheap structural hash of a UI snapshot, used to detect whether a tap
// (or any mutating action) had any effect — without paying for a full
// tree dump. Two fingerprints comparing equal do NOT prove the UI is
// identical (a keyboard appearing without a VC change can leave it
// stable). But two fingerprints that DIFFER reliably prove something
// changed. That asymmetry is exactly what post-tap verification needs:
// if pre == post after a short delay, the tap silently dropped.
//
// The value type lives in AutoCore so it's trivially testable. The
// iOS-specific capture from an AXUIElement root lives in AutoLibiOS as
// an extension.

public struct ViewFingerprint: Equatable {
    public let rootChildCount: Int
    public let topLevelSignature: String

    public init(rootChildCount: Int, topLevelSignature: String) {
        self.rootChildCount = rootChildCount
        self.topLevelSignature = topLevelSignature
    }
}
