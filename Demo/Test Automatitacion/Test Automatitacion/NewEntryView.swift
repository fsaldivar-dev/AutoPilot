import SwiftUI
import PhotosUI
import CoreLocation

struct NewEntryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var description = ""
    @State private var category: TravelCategory = .adventure
    @State private var mood: Double = 3
    @State private var isFavorite = false
    @State private var locationName = ""
    @State private var date = Date()
    @State private var photos: [UIImage] = []
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showValidationError = false

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !description.trimmingCharacters(in: .whitespaces).isEmpty &&
        !locationName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // Photos section
                photosSection

                // Basic info
                basicInfoSection

                // Category selection
                categorySection

                // Location & Date
                locationDateSection

                // Mood & Favorite
                moodSection
            }
            .navigationTitle("Nueva Entrada")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        saveEntry()
                    }
                    .font(.headline)
                    .disabled(!isValid)
                }
            }
            .sheet(isPresented: $showCamera) {
                ImagePickerView(sourceType: .camera) { image in
                    photos.append(image)
                }
            }
            .alert("Campos requeridos", isPresented: $showValidationError) {
                Button("OK") {}
            } message: {
                Text("Por favor completa el titulo, descripcion y ubicacion para guardar tu entrada.")
            }
        }
    }

    // MARK: - Photos Section

    private var photosSection: some View {
        Section {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { index, photo in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: photo)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 100, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))

                                Button {
                                    withAnimation { let _ = photos.remove(at: index) }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.white, .red)
                                        .font(.title3)
                                }
                                .offset(x: 6, y: -6)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack(spacing: 16) {
                Button {
                    showCamera = true
                } label: {
                    Label("Camara", systemImage: "camera.fill")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AppTheme.primary.opacity(0.1))
                        .foregroundStyle(AppTheme.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 5,
                    matching: .images
                ) {
                    Label("Galeria", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(AppTheme.secondary.opacity(0.1))
                        .foregroundStyle(AppTheme.secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .buttonStyle(.plain)
            .onChange(of: selectedPhotoItems) { _, newItems in
                Task {
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            photos.append(image)
                        }
                    }
                    selectedPhotoItems = []
                }
            }
        } header: {
            Label("Fotos", systemImage: "photo.stack")
        }
    }

    // MARK: - Basic Info

    private var basicInfoSection: some View {
        Section {
            TextField("Titulo de tu experiencia", text: $title)
                .font(.headline)

            ZStack(alignment: .topLeading) {
                if description.isEmpty {
                    Text("Describe tu experiencia con detalle...")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                }
                TextEditor(text: $description)
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
            }
        } header: {
            Label("Detalles", systemImage: "text.alignleft")
        }
    }

    // MARK: - Category

    private var categorySection: some View {
        Section {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                ForEach(TravelCategory.allCases) { cat in
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            category = cat
                        }
                        appState.triggerSelectionHaptic()
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(category == cat ? cat.color : cat.color.opacity(0.15))
                                    .frame(width: 44, height: 44)

                                Image(systemName: cat.icon)
                                    .font(.system(size: 18))
                                    .foregroundStyle(category == cat ? .white : cat.color)
                            }

                            Text(cat.rawValue)
                                .font(.caption2)
                                .foregroundStyle(category == cat ? cat.color : .secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Label("Categoria", systemImage: "tag")
        }
    }

    // MARK: - Location & Date

    private var locationDateSection: some View {
        Section {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(AppTheme.primary)
                TextField("Ciudad, Pais", text: $locationName)
            }

            DatePicker(
                "Fecha",
                selection: $date,
                displayedComponents: [.date]
            )
        } header: {
            Label("Ubicacion y Fecha", systemImage: "location")
        }
    }

    // MARK: - Mood

    private var moodSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack {
                    Text("Estado de animo")
                    Spacer()
                    Text(moodEmojiForValue(mood))
                        .font(.title)
                }

                Slider(value: $mood, in: 0...5, step: 1) {
                    Text("Mood")
                } minimumValueLabel: {
                    Text("😴")
                } maximumValueLabel: {
                    Text("🤩")
                }
                .tint(AppTheme.primary)
                .onChange(of: mood) { _, _ in
                    appState.triggerSelectionHaptic()
                }
            }

            Toggle(isOn: $isFavorite) {
                Label("Marcar como favorito", systemImage: isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(isFavorite ? AppTheme.primary : .primary)
            }
            .tint(AppTheme.primary)
        } header: {
            Label("Estado de animo", systemImage: "face.smiling")
        }
    }

    // MARK: - Helpers

    private func moodEmojiForValue(_ value: Double) -> String {
        switch Int(value.rounded()) {
        case 0: return "😴"
        case 1: return "😐"
        case 2: return "🙂"
        case 3: return "😊"
        case 4: return "😄"
        default: return "🤩"
        }
    }

    private func saveEntry() {
        guard isValid else {
            showValidationError = true
            appState.triggerHaptic(.error)
            return
        }

        let entry = JournalEntry(
            id: UUID(),
            title: title.trimmingCharacters(in: .whitespaces),
            description: description.trimmingCharacters(in: .whitespaces),
            date: date,
            category: category,
            mood: mood,
            isFavorite: isFavorite,
            locationName: locationName.trimmingCharacters(in: .whitespaces),
            photos: photos
        )

        appState.addEntry(entry)
        dismiss()
    }
}

// MARK: - Image Picker (UIKit Bridge)

struct ImagePickerView: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    let onImagePicked: (UIImage) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void

        init(onImagePicked: @escaping (UIImage) -> Void) {
            self.onImagePicked = onImagePicked
        }

        nonisolated func imagePickerController(_ picker: UIImagePickerController,
                                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            Task { @MainActor in
                if let image {
                    self.onImagePicked(image)
                }
                picker.dismiss(animated: true)
            }
        }

        nonisolated func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            Task { @MainActor in
                picker.dismiss(animated: true)
            }
        }
    }
}
