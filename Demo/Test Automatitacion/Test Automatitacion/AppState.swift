import SwiftUI
import Observation
import LocalAuthentication
import UserNotifications

@Observable
class AppState {
    var isAuthenticated = false
    var authError: String?
    var showPinFallback = false
    var pinCode: String = ""
    var entries: [JournalEntry] = []
    var profile = UserProfile()
    var scannedQRs: [ScannedQR] = []
    var capturedPhotos: [UIImage] = []
    var searchText: String = ""
    var selectedCategory: TravelCategory?
    var clipboardContent: String = ""

    private let correctPin = "1234"

    var filteredEntries: [JournalEntry] {
        var result = entries
        if !searchText.isEmpty {
            result = result.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.description.localizedCaseInsensitiveContains(searchText) ||
                $0.locationName.localizedCaseInsensitiveContains(searchText)
            }
        }
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        return result.sorted { $0.date > $1.date }
    }

    var favoriteEntries: [JournalEntry] {
        entries.filter(\.isFavorite)
    }

    var entriesByCategory: [TravelCategory: Int] {
        Dictionary(grouping: entries, by: \.category).mapValues(\.count)
    }

    var uniqueLocations: Int {
        Set(entries.map(\.locationName)).count
    }

    init() {
        loadSampleData()
    }

    // MARK: - Authentication

    func authenticateWithBiometrics() {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            authError = "Biometría no disponible: \(error?.localizedDescription ?? "error desconocido")"
            showPinFallback = true
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Desbloquea tu diario de viajes"
        ) { success, authenticationError in
            Task { @MainActor in
                if success {
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                        self.isAuthenticated = true
                        self.authError = nil
                    }
                } else {
                    self.authError = authenticationError?.localizedDescription ?? "Autenticación fallida"
                    self.showPinFallback = true
                }
            }
        }
    }

    func authenticateWithPin() {
        if pinCode == correctPin {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                isAuthenticated = true
                authError = nil
                pinCode = ""
                showPinFallback = false
            }
        } else {
            authError = "PIN incorrecto"
            pinCode = ""
            triggerHaptic(.error)
        }
    }

    func logout() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
            isAuthenticated = false
            authError = nil
            showPinFallback = false
            pinCode = ""
        }
    }

    // MARK: - Entries

    func addEntry(_ entry: JournalEntry) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            entries.insert(entry, at: 0)
        }
        triggerHaptic(.success)
    }

    func deleteEntry(_ entry: JournalEntry) {
        withAnimation {
            entries.removeAll { $0.id == entry.id }
        }
    }

    func toggleFavorite(_ entry: JournalEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index].isFavorite.toggle()
            triggerHaptic(.light)
        }
    }

    // MARK: - QR

    func addScannedQR(_ content: String) {
        let qr = ScannedQR(content: content, date: Date())
        scannedQRs.insert(qr, at: 0)
        triggerHaptic(.success)
    }

    func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        clipboardContent = text
        triggerHaptic(.light)
    }

    // MARK: - Photos

    func addCapturedPhoto(_ image: UIImage) {
        capturedPhotos.insert(image, at: 0)
        triggerHaptic(.success)
    }

    // MARK: - Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            Task { @MainActor in
                self.profile.notificationsEnabled = granted
                if granted {
                    self.scheduleReminder()
                }
            }
        }
    }

    func scheduleReminder() {
        let content = UNMutableNotificationContent()
        content.title = "Explorea"
        content.body = "Viviste algo increible hoy? Anadelo a tu diario!"
        content.sound = .default

        let comps = Calendar.current.dateComponents([.hour, .minute], from: profile.dailyReminderTime)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request = UNNotificationRequest(identifier: "daily_reminder", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Haptics

    func triggerHaptic(_ style: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(style)
    }

    func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    func triggerSelectionHaptic() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: - Sample Data

    private func loadSampleData() {
        entries = [
            JournalEntry(
                id: UUID(), title: "Atardecer en Santorini",
                description: "El cielo se pinto de naranja y rosa mientras el sol se hundia en el mar Egeo. Las casas blancas de Oia brillaban con la ultima luz del dia. Un momento magico que quedara grabado para siempre.",
                date: Calendar.current.date(byAdding: .day, value: -2, to: Date())!,
                category: .nature, mood: 5, isFavorite: true,
                locationName: "Santorini, Grecia",
                latitude: 36.3932, longitude: 25.4615, photos: []
            ),
            JournalEntry(
                id: UUID(), title: "Tacos al pastor en CDMX",
                description: "Encontre el mejor puesto de tacos en la Roma Norte. El trompo giraba hipnoticamente mientras el taquero cortaba la carne con precision quirurgica. La salsa verde era perfecta.",
                date: Calendar.current.date(byAdding: .day, value: -5, to: Date())!,
                category: .food, mood: 4, isFavorite: true,
                locationName: "Ciudad de Mexico, Mexico",
                latitude: 19.4194, longitude: -99.1626, photos: []
            ),
            JournalEntry(
                id: UUID(), title: "Museo del Louvre",
                description: "Tres horas no fueron suficientes. La Mona Lisa es mas pequena de lo esperado, pero la Victoria de Samotracia me dejo sin aliento. Las galerias de arte egipcio son subestimadas.",
                date: Calendar.current.date(byAdding: .day, value: -10, to: Date())!,
                category: .culture, mood: 4, isFavorite: false,
                locationName: "Paris, Francia",
                latitude: 48.8606, longitude: 2.3376, photos: []
            ),
            JournalEntry(
                id: UUID(), title: "Noche en Shibuya",
                description: "El cruce mas famoso del mundo no decepciona. Las luces de neon, el ruido constante, la energia de miles de personas cruzando al mismo tiempo. Despues cenamos ramen en un local diminuto con 8 asientos.",
                date: Calendar.current.date(byAdding: .day, value: -15, to: Date())!,
                category: .nightlife, mood: 5, isFavorite: true,
                locationName: "Tokio, Japon",
                latitude: 35.6595, longitude: 139.7004, photos: []
            ),
            JournalEntry(
                id: UUID(), title: "Senderismo en los Alpes",
                description: "Ruta de 12km por el sendero del Eiger. El aire fresco de montana, las vacas con cencerros, y las vistas del Jungfrau. Mis piernas me odiaron al dia siguiente pero valio cada paso.",
                date: Calendar.current.date(byAdding: .day, value: -20, to: Date())!,
                category: .adventure, mood: 4, isFavorite: false,
                locationName: "Grindelwald, Suiza",
                latitude: 46.6244, longitude: 8.0413, photos: []
            ),
            JournalEntry(
                id: UUID(), title: "Spa en Bali",
                description: "Un masaje balines de 90 minutos con vista al arrozal. Despues, bano de flores y te de jengibre. El sonido del agua y los pajaros crearon la banda sonora perfecta para desconectar.",
                date: Calendar.current.date(byAdding: .day, value: -25, to: Date())!,
                category: .relaxation, mood: 5, isFavorite: true,
                locationName: "Ubud, Bali",
                latitude: -8.5069, longitude: 115.2625, photos: []
            ),
            JournalEntry(
                id: UUID(), title: "Gran Bazar de Estambul",
                description: "Me perdi tres veces en los 4,000 puestos del bazar. Compre especias, un farol de mosaico y una alfombra que no necesitaba pero no pude resistir. El arte de regatear es toda una experiencia.",
                date: Calendar.current.date(byAdding: .day, value: -30, to: Date())!,
                category: .shopping, mood: 3, isFavorite: false,
                locationName: "Estambul, Turquia",
                latitude: 41.0106, longitude: 28.9680, photos: []
            ),
        ]
    }
}
