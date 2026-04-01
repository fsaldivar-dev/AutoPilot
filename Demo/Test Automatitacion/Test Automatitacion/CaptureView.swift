import SwiftUI
import AVFoundation
import AutoPilotAVFoundation
import PhotosUI

// MARK: - Camera Manager

class CameraManager: NSObject, AVCapturePhotoCaptureDelegate {
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    nonisolated(unsafe) private var currentPosition: AVCaptureDevice.Position = .back
    nonisolated(unsafe) var flashMode: AVCaptureDevice.FlashMode = .off

    var onPhotoCaptured: ((UIImage) -> Void)?
    var cameraPermissionGranted = false
    var cameraConfigured = false

    func requestAccessAndConfigure() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraPermissionGranted = true
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    self.cameraPermissionGranted = granted
                    if granted {
                        self.configureAndStart()
                    }
                }
            }
        default:
            cameraPermissionGranted = false
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [self] in
            setupSession()
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    private nonisolated func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        session.inputs.forEach { session.removeInput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            Task { @MainActor in self.cameraConfigured = false }
            return
        }
        session.addInput(input)

        if session.outputs.isEmpty, session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
        }

        session.commitConfiguration()
        Task { @MainActor in self.cameraConfigured = true }
    }

    func startSession() {
        sessionQueue.async { [self] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [self] in
            let settings = AVCapturePhotoSettings()
            if photoOutput.supportedFlashModes.contains(flashMode) {
                settings.flashMode = flashMode
            }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func flipCamera() {
        currentPosition = currentPosition == .back ? .front : .back
        sessionQueue.async { [self] in
            setupSession()
        }
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }
        Task { @MainActor in
            self.onPhotoCaptured?(image)
        }
    }
}

// MARK: - Camera Preview (UIViewRepresentable)

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {}

    class CameraPreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            previewLayer.videoGravity = .resizeAspectFill
            backgroundColor = .black
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}

// MARK: - Capture View

struct CaptureView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedMode = 0
    @State private var cameraManager = CameraManager()
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedPhoto: UIImage?
    @State private var showPhotoDetail = false
    @State private var flashEnabled = false
    @State private var isFrontCamera = false
    @State private var showCaptureFlash = false
    @State private var scannedCode: String?
    @State private var showScannedAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
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
        VStack(spacing: 16) {
            // Live camera preview
            ZStack {
                if cameraManager.cameraPermissionGranted && cameraManager.cameraConfigured {
                    CameraPreview(session: cameraManager.session)
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                        )
                        // Capture flash effect
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(.white)
                                .opacity(showCaptureFlash ? 1 : 0)
                                .animation(.easeOut(duration: 0.15), value: showCaptureFlash)
                        )
                } else {
                    // No permission yet or denied
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black)
                        .frame(height: 340)
                        .overlay(
                            VStack(spacing: 12) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 50))
                                    .foregroundStyle(.gray)
                                Text("Camara no disponible")
                                    .font(.subheadline)
                                    .foregroundStyle(.gray)
                                Text("Otorga permiso en Ajustes")
                                    .font(.caption)
                                    .foregroundStyle(.gray.opacity(0.7))
                            }
                        )
                }
            }
            .padding(.horizontal)
            .onAppear {
                cameraManager.onPhotoCaptured = { image in
                    appState.addCapturedPhoto(image)
                    showCaptureFlash = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        showCaptureFlash = false
                    }
                }
                // Registrar callback para inyeccion de camara (AutoPilot CI/CD)
                AutoPilotCamera.onPhotoCaptured = cameraManager.onPhotoCaptured
                cameraManager.requestAccessAndConfigure()
            }
            .onDisappear {
                cameraManager.stopSession()
            }

            // Control buttons
            HStack(spacing: 28) {
                // Flash toggle
                Button {
                    flashEnabled.toggle()
                    cameraManager.flashMode = flashEnabled ? .on : .off
                    appState.triggerSelectionHaptic()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: flashEnabled ? "bolt.fill" : "bolt.slash")
                            .font(.title2)
                            .foregroundStyle(flashEnabled ? .yellow : .secondary)
                            .frame(width: 48, height: 48)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                        Text("Flash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Capture button
                Button {
                    appState.triggerHaptic(.medium)
                    if AutoPilotCamera.isEnabled || (cameraManager.cameraPermissionGranted && cameraManager.cameraConfigured) {
                        cameraManager.capturePhoto()
                    }
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

                // Flip camera
                Button {
                    isFrontCamera.toggle()
                    cameraManager.flipCamera()
                    appState.triggerSelectionHaptic()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "camera.rotate.fill")
                            .font(.title2)
                            .foregroundStyle(isFrontCamera ? AppTheme.secondary : .secondary)
                            .frame(width: 48, height: 48)
                            .background(Color(.systemGray6))
                            .clipShape(Circle())
                        Text("Voltear")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Gallery picker
            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: 10,
                matching: .images
            ) {
                Label("Seleccionar de galeria", systemImage: "photo.on.rectangle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.secondary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(AppTheme.secondary.opacity(0.1))
                    .clipShape(Capsule())
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

            // Captured photos grid
            if !appState.capturedPhotos.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
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
                                        .frame(width: 80, height: 80)
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
