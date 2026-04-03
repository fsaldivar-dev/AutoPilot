import SwiftUI

enum AppTheme {
    static let primary = Color(hex: "FF6B6B")
    static let accent = Color(hex: "FF8E53")
    static let secondary = Color(hex: "4ECDC4")
    static let secondaryDark = Color(hex: "44B09E")
    static let darkText = Color(hex: "2C3E50")
    static let lightText = Color(hex: "95A5A6")
    static let cardBackground = Color.white

    static let primaryGradient = LinearGradient(
        colors: [primary, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let secondaryGradient = LinearGradient(
        colors: [secondary, secondaryDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let nightGradient = LinearGradient(
        colors: [Color(hex: "2C3E50"), Color(hex: "3498DB")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let sunsetGradient = LinearGradient(
        colors: [Color(hex: "F093FB"), Color(hex: "F5576C")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(AppTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(AppTheme.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardModifier())
    }
}
