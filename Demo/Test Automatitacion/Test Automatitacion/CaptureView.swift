import SwiftUI
import PhotosUI

struct CaptureView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMode = 0
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedPhoto: UIImage?
    @State private var showPhotoDetail = false
    @State private var flashEnabled = false
    @State private var scannedCode: String?
    @State private var showScannedAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Mode selector
                Picker("Modo", selection: $selectedMode) {
                    Label("Fotos", systemImage: "camera").tag(0)
                    Label("Escaner QR", systemImage: "qrcode.viewfinder").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedMode == 0 {
                    photoMode
                } else {
                    qrMode
                }
            }
            .navigationTitle("Capturar")
            .sheet(isPresented: $showCamera) {
                ImagePickerView(sourceType: .camera) { image in
                    appState.addCapturedPhoto(image)
                }
            }
            .sheet(isPresented: $showPhotoDetail) {
                if let photo = selectedPhoto {
                    PhotoViewerSheet(image: photo)
                }
            }
            .alert("Codigo QR Detectado", isPresented: $showScannedAlert) {
                Button("Copiar") {
                    if let code = scannedCode {
                        appState.copyToClipboard(code)
                    }
                }
                Button("Guardar") {
                    if let code = scannedCode {
                        appState.addScannedQR(code)
                    }
                }
                Button("Cerrar", role: .cancel) {}
            } message: {
                Text(scannedCode ?? "")
            }
        }
    }

    // MARK: - Photo Mode

    private var photoMode: some View {
        VStack(spacing: 20) {
            // Camera preview placeholder / action area
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [Color(.systemGray5), Color(.systemGray6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 280)

                VStack(spacing: 20) {
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 60))
                        .foregroundStyle(AppTheme.lightText)

                    Text("Captura momentos de tus viajes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)

            // Action buttons
            HStack(spacing: 24) {
                // Flash toggle
                Button {
                    flashEnabled.toggle()
                    appState.triggerSelectionHaptic()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: flashEnabled ? "bolt.fill" : "bolt.slash")
                            .font(.title2)
                            .foregroundStyle(flashEnabled ? .yellow : .secondary)
                            .frame(width: 50, height: 50)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())

                        Text("Flash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Capture button
                Button {
                    showCamera = true
                    appState.triggerHaptic(.medium)
                } label: {
                    ZStack {
                        Circle()
                            .fill(AppTheme.primaryGradient)
                            .frame(width: 76, height: 76)
                            .shadow(color: AppTheme.primary.opacity(0.4), radius: 10, y: 4)

                        Circle()
                            .strokeBorder(.white, lineWidth: 3)
                            .frame(width: 66, height: 66)

                        Image(systemName: "camera.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                }

                // Gallery picker
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 10,
                    matching: .images
                ) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2)
                            .foregroundStyle(AppTheme.secondary)
                            .frame(width: 50, height: 50)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())

                        Text("Galeria")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: selectedPhotoItems) { _, items in
                    Task {
                        for item in items {
                            if let data = try? await item.loadTransferable(type: Data.self),
                               let image = UIImage(data: data) {
                                appState.addCapturedPhoto(image)
                            }
                        }
                        selectedPhotoItems = []
                    }
                }
            }

            // Captured photos grid
            if !appState.capturedPhotos.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Fotos capturadas")
                            .font(.headline)
                        Spacer()
                        Text("\(appState.capturedPhotos.count) fotos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(appState.capturedPhotos.enumerated()), id: \.offset) { _, photo in
                                Button {
                                    selectedPhoto = photo
                                    showPhotoDetail = true
                                } label: {
                                    Image(uiImage: photo)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 90, height: 90)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }

            Spacer()
        }
        .padding(.bottom, 80)
    }

    // MARK: - QR Mode

    private var qrMode: some View {
        VStack(spacing: 16) {
            // Scanner area
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.black)
                    .frame(height: 300)
                    .overlay(
                        QRScannerView { code in
                            scannedCode = code
                            showScannedAlert = true
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    )

                // Scan frame overlay
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AppTheme.secondary, lineWidth: 3)
                    .frame(width: 200, height: 200)
                    .overlay(
                        VStack {
                            HStack {
                                scanCorner(rotation: 0)
                                Spacer()
                                scanCorner(rotation: 90)
                            }
                            Spacer()
                            HStack {
                                scanCorner(rotation: 270)
                                Spacer()
                                scanCorner(rotation: 180)
                            }
                        }
                        .padding(4)
                    )
            }
            .padding(.horizontal)

            Text("Apunta la camara hacia un codigo QR")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Scanned results
            if !appState.scannedQRs.isEmpty {
                List {
                    Section("Codigos escaneados") {
                        ForEach(appState.scannedQRs) { qr in
                            HStack {
                                Image(systemName: "qrcode")
                                    .foregroundStyle(AppTheme.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(qr.content)
                                        .font(.subheadline)
                                        .lineLimit(1)

                                    Text(qr.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    appState.copyToClipboard(qr.content)
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.subheadline)
                                        .foregroundStyle(AppTheme.primary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            appState.scannedQRs.remove(atOffsets: indexSet)
                        }
                    }
                }
                .listStyle(.plain)
            }

            Spacer()
        }
        .padding(.bottom, 80)
    }

    private func scanCorner(rotation: Double) -> some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 15))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 15, y: 0))
        }
        .stroke(AppTheme.primary, lineWidth: 4)
        .frame(width: 15, height: 15)
        .rotationEffect(.degrees(rotation))
    }
}
