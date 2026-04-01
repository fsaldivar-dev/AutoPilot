import SwiftUI
import PhotosUI

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @State private var showAvatarPicker = false
    @State private var showCamera = false
    @State private var showLogoutAlert = false
    @State private var showExportAlert = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var showAvatarActionSheet = false

    var body: some View {
        @Bindable var appState = appState

        NavigationStack {
            Form {
                // Avatar & name header
                profileHeaderSection

                // Preferences
                preferencesSection

                // Statistics
                statisticsSection

                // Clipboard
                clipboardSection

                // Account actions
                accountSection

                // About
                aboutSection
            }
            .navigationTitle("Perfil")
            .sheet(isPresented: $showCamera) {
                ImagePickerView(sourceType: .camera) { image in
                    appState.profile.avatar = image
                }
            }
            .alert("Cerrar sesion", isPresented: $showLogoutAlert) {
                Button("Cancelar", role: .cancel) {}
                Button("Cerrar sesion", role: .destructive) {
                    appState.logout()
                }
            } message: {
                Text("Tendras que autenticarte de nuevo con Face ID o tu PIN para acceder a tu diario.")
            }
            .alert("Datos exportados", isPresented: $showExportAlert) {
                Button("OK") {}
            } message: {
                Text("Se exportaron \(appState.entries.count) entradas exitosamente. (Demo)")
            }
        }
    }

    // MARK: - Profile Header

    private var profileHeaderSection: some View {
        @Bindable var appState = appState

        return Section {
            VStack(spacing: 16) {
                // Avatar
                Button {
                    showAvatarActionSheet = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        if let avatar = appState.profile.avatar {
                            Image(uiImage: avatar)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 90, height: 90)
                                .clipShape(Circle())
                        } else {
                            Circle()
                                .fill(AppTheme.primaryGradient)
                                .frame(width: 90, height: 90)
                                .overlay(
                                    Text(String(appState.profile.name.prefix(1)).uppercased())
                                        .font(.system(size: 36, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                        }

                        Circle()
                            .fill(AppTheme.secondary)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white)
                            )
                            .offset(x: 2, y: 2)
                    }
                }
                .buttonStyle(.plain)
                .confirmationDialog("Cambiar foto", isPresented: $showAvatarActionSheet) {
                    Button("Tomar foto") {
                        showCamera = true
                    }
                    PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                        Text("Elegir de galeria")
                    }
                    if appState.profile.avatar != nil {
                        Button("Eliminar foto", role: .destructive) {
                            withAnimation { appState.profile.avatar = nil }
                        }
                    }
                }
                .onChange(of: selectedAvatarItem) { _, item in
                    Task {
                        if let item,
                           let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            appState.profile.avatar = image
                        }
                        selectedAvatarItem = nil
                    }
                }

                // Name & email fields
                TextField("Tu nombre", text: $appState.profile.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                TextField("correo@ejemplo.com", text: $appState.profile.email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Preferences

    private var preferencesSection: some View {
        @Bindable var appState = appState

        return Section("Preferencias") {
            Toggle(isOn: Binding(
                get: { appState.profile.notificationsEnabled },
                set: { newValue in
                    if newValue {
                        appState.requestNotificationPermission()
                    } else {
                        appState.profile.notificationsEnabled = false
                    }
                }
            )) {
                Label("Notificaciones", systemImage: "bell.fill")
            }
            .tint(AppTheme.primary)

            if appState.profile.notificationsEnabled {
                DatePicker(
                    selection: $appState.profile.dailyReminderTime,
                    displayedComponents: .hourAndMinute
                ) {
                    Label("Recordatorio diario", systemImage: "clock.fill")
                }
                .onChange(of: appState.profile.dailyReminderTime) { _, _ in
                    appState.scheduleReminder()
                }
            }

            Toggle(isOn: $appState.profile.useMetricSystem) {
                Label("Sistema metrico", systemImage: "ruler.fill")
            }
            .tint(AppTheme.secondary)

            Toggle(isOn: $appState.profile.prefersDarkMode) {
                Label("Modo oscuro", systemImage: "moon.fill")
            }
            .tint(.indigo)
        }
    }

    // MARK: - Statistics

    private var statisticsSection: some View {
        Section("Estadisticas") {
            StatRow(icon: "book.fill", color: AppTheme.primary,
                    label: "Total de entradas", value: "\(appState.entries.count)")

            StatRow(icon: "globe.americas.fill", color: .blue,
                    label: "Ciudades visitadas", value: "\(appState.uniqueLocations)")

            StatRow(icon: "heart.fill", color: .pink,
                    label: "Favoritos", value: "\(appState.favoriteEntries.count)")

            StatRow(icon: "camera.fill", color: AppTheme.secondary,
                    label: "Fotos capturadas", value: "\(appState.capturedPhotos.count)")

            if let topCategory = appState.entriesByCategory.max(by: { $0.value < $1.value }) {
                StatRow(icon: topCategory.key.icon, color: topCategory.key.color,
                        label: "Categoria favorita", value: topCategory.key.rawValue)
            }
        }
    }

    // MARK: - Clipboard

    private var clipboardSection: some View {
        Section("Portapapeles") {
            if appState.clipboardContent.isEmpty {
                Label("Nada copiado aun", systemImage: "doc.on.clipboard")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ultimo copiado:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(appState.clipboardContent)
                        .font(.subheadline)
                        .lineLimit(2)
                }

                Button {
                    if let text = UIPasteboard.general.string {
                        appState.clipboardContent = text
                    }
                } label: {
                    Label("Pegar del sistema", systemImage: "doc.on.clipboard.fill")
                }
            }
        }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Cuenta") {
            Button {
                showExportAlert = true
                appState.triggerHaptic(.success)
            } label: {
                Label("Exportar mis datos", systemImage: "square.and.arrow.up")
            }

            Button(role: .destructive) {
                showLogoutAlert = true
            } label: {
                Label("Cerrar sesion", systemImage: "rectangle.portrait.and.arrow.right")
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("Acerca de") {
            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Desarrollador")
                Spacer()
                Text("Explorea Team")
                    .foregroundStyle(.secondary)
            }

            Link(destination: URL(string: "https://example.com")!) {
                Label("Sitio web", systemImage: "globe")
            }

            Link(destination: URL(string: "mailto:soporte@explorea.app")!) {
                Label("Contacto", systemImage: "envelope.fill")
            }
        }
    }
}

// MARK: - Stat Row Component

struct StatRow: View {
    let icon: String
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(label)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
