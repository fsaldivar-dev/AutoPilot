import SwiftUI
import MapKit

struct EntryDetailView: View {
    let entry: JournalEntry
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteAlert = false
    @State private var showShareSheet = false
    @State private var selectedPhoto: UIImage?
    @State private var showPhotoViewer = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero header
                headerSection

                VStack(alignment: .leading, spacing: 24) {
                    // Meta info
                    metaSection

                    // Description
                    Text(entry.description)
                        .font(.body)
                        .foregroundStyle(AppTheme.darkText)
                        .lineSpacing(4)

                    // Photos
                    if !entry.photos.isEmpty {
                        photosSection
                    }

                    // Map section
                    if entry.coordinate != nil {
                        mapSection
                    }

                    // Actions
                    actionsSection
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("Eliminar entrada", isPresented: $showDeleteAlert) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar", role: .destructive) {
                appState.deleteEntry(entry)
                dismiss()
            }
        } message: {
            Text("Esta accion no se puede deshacer. Se eliminara permanentemente esta entrada de tu diario.")
        }
        .sheet(isPresented: $showPhotoViewer) {
            if let photo = selectedPhoto {
                PhotoViewerSheet(image: photo)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        ZStack(alignment: .bottomLeading) {
            if let firstPhoto = entry.photos.first {
                Image(uiImage: firstPhoto)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 260)
                    .clipped()
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    )
            } else {
                LinearGradient(
                    colors: [entry.category.color, entry.category.color.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(height: 260)
                .overlay(
                    Image(systemName: entry.category.icon)
                        .font(.system(size: 60))
                        .foregroundStyle(.white.opacity(0.3))
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: entry.category.icon)
                    Text(entry.category.rawValue)
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial.opacity(0.6))
                .clipShape(Capsule())

                Text(entry.title)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
            }
            .padding(20)
        }
    }

    // MARK: - Meta

    private var metaSection: some View {
        HStack(spacing: 20) {
            metaItem(icon: "mappin.circle.fill", text: entry.locationName, color: .red)
            Spacer()
            metaItem(icon: "calendar", text: entry.formattedDate, color: .blue)
            Spacer()
            VStack(spacing: 4) {
                Text(entry.moodEmoji)
                    .font(.title)
                Text("Mood")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if entry.isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(AppTheme.primary)
                    .font(.title2)
            }
        }
        .padding(16)
        .cardStyle()
    }

    private func metaItem(icon: String, text: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: - Photos

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fotos")
                .font(.headline)
                .foregroundStyle(AppTheme.darkText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(entry.photos.enumerated()), id: \.offset) { _, photo in
                        Button {
                            selectedPhoto = photo
                            showPhotoViewer = true
                        } label: {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    // MARK: - Map

    private var mapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ubicacion")
                .font(.headline)
                .foregroundStyle(AppTheme.darkText)

            if let coord = entry.coordinate {
                Map {
                    Marker(entry.locationName, coordinate: coord)
                        .tint(entry.category.color)
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 12) {
            Button {
                appState.toggleFavorite(entry)
            } label: {
                Label(
                    entry.isFavorite ? "Quitar de favoritos" : "Agregar a favoritos",
                    systemImage: entry.isFavorite ? "heart.fill" : "heart"
                )
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(entry.isFavorite ? AppTheme.primary.opacity(0.1) : Color(.systemGray6))
                .foregroundStyle(entry.isFavorite ? AppTheme.primary : AppTheme.darkText)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button {
                let text = "\(entry.title)\n\(entry.locationName)\n\(entry.description)"
                appState.copyToClipboard(text)
            } label: {
                Label("Copiar al portapapeles", systemImage: "doc.on.doc")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray6))
                    .foregroundStyle(AppTheme.darkText)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Button(role: .destructive) {
                showDeleteAlert = true
            } label: {
                Label("Eliminar entrada", systemImage: "trash")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.red.opacity(0.1))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.top, 8)
    }
}

// MARK: - Photo Viewer

struct PhotoViewerSheet: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = lastScale * value.magnification
                            }
                            .onEnded { _ in
                                lastScale = scale
                                if scale < 1.0 {
                                    withAnimation { scale = 1.0 }
                                    lastScale = 1.0
                                }
                            }
                    )
                    .gesture(
                        TapGesture(count: 2)
                            .onEnded {
                                withAnimation(.spring()) {
                                    if scale > 1.0 {
                                        scale = 1.0
                                        lastScale = 1.0
                                    } else {
                                        scale = 2.5
                                        lastScale = 2.5
                                    }
                                }
                            }
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}
