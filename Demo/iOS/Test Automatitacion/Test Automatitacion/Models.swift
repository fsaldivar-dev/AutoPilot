import Foundation
import UIKit
import SwiftUI
import CoreLocation

enum TravelCategory: String, CaseIterable, Identifiable, Codable {
    case adventure = "Aventura"
    case food = "Gastronomia"
    case culture = "Cultura"
    case nature = "Naturaleza"
    case nightlife = "Vida Nocturna"
    case shopping = "Compras"
    case relaxation = "Relax"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adventure: return "figure.hiking"
        case .food: return "fork.knife"
        case .culture: return "building.columns"
        case .nature: return "leaf.fill"
        case .nightlife: return "moon.stars.fill"
        case .shopping: return "bag.fill"
        case .relaxation: return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .adventure: return .orange
        case .food: return .red
        case .culture: return .purple
        case .nature: return .green
        case .nightlife: return .indigo
        case .shopping: return .pink
        case .relaxation: return .cyan
        }
    }
}

struct JournalEntry: Identifiable, Hashable {
    static func == (lhs: JournalEntry, rhs: JournalEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: UUID
    var title: String
    var description: String
    var date: Date
    var category: TravelCategory
    var mood: Double
    var isFavorite: Bool
    var locationName: String
    var latitude: Double?
    var longitude: Double?
    var photos: [UIImage]

    var coordinate: CLLocationCoordinate2D? {
        guard let lat = latitude, let lon = longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var moodEmoji: String {
        switch Int(mood.rounded()) {
        case 0: return "😴"
        case 1: return "😐"
        case 2: return "🙂"
        case 3: return "😊"
        case 4: return "😄"
        default: return "🤩"
        }
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.locale = Locale(identifier: "es_MX")
        return formatter.string(from: date)
    }
}

struct UserProfile {
    var name: String = "Viajero"
    var email: String = ""
    var avatar: UIImage? = nil
    var notificationsEnabled: Bool = false
    var dailyReminderTime: Date = Calendar.current.date(from: DateComponents(hour: 9)) ?? Date()
    var useMetricSystem: Bool = true
    var prefersDarkMode: Bool = false
}

struct ScannedQR: Identifiable {
    let id = UUID()
    let content: String
    let date: Date
}
