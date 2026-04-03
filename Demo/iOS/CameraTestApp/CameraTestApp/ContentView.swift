import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var viewModel = CameraViewModel()

    var body: some View {
        VStack(spacing: 20) {
            Text("Camera Test")
                .font(.largeTitle.bold())

            // Status
            Text(viewModel.status)
                .foregroundStyle(.secondary)

            // Live preview
            CameraPreview(session: viewModel.session)
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal)

            // Captured image
            if let image = viewModel.capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            // Capture button
            Button {
                viewModel.capturePhoto()
            } label: {
                Label("Capturar Foto", systemImage: "camera.circle.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal)

            // Info
            if let data = viewModel.photoData {
                Text("\(data.count) bytes capturados")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Spacer()
        }
        .padding(.top)
        .onAppear {
            viewModel.setup()
        }
    }
}

// MARK: - ViewModel with pure AVFoundation (NO AutoPilot)

@Observable
class CameraViewModel: NSObject, AVCapturePhotoCaptureDelegate {
    var status = "Inicializando..."
    var capturedImage: UIImage?
    var photoData: Data?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.queue")

    func setup() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .authorized:
            status = "Autorizado. Configurando..."
            configureSession()
        case .notDetermined:
            status = "Solicitando permiso..."
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        self.status = "Permiso concedido. Configurando..."
                        self.configureSession()
                    } else {
                        self.status = "Permiso denegado"
                    }
                }
            }
        default:
            status = "Sin permiso de camara"
        }
    }

    private func configureSession() {
        sessionQueue.async { [self] in
            session.beginConfiguration()

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                Task { @MainActor in self.status = "No se pudo configurar camara" }
                session.commitConfiguration()
                return
            }

            session.addInput(input)

            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }

            session.commitConfiguration()
            session.startRunning()

            Task { @MainActor in self.status = "Camara lista" }
        }
    }

    func capturePhoto() {
        status = "Capturando..."
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - AVCapturePhotoCaptureDelegate

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        Task { @MainActor in
            if let error {
                self.status = "Error: \(error.localizedDescription)"
                return
            }

            if let data = photo.fileDataRepresentation() {
                self.photoData = data
                self.capturedImage = UIImage(data: data)
                self.status = "Foto capturada (\(data.count) bytes)"
            } else {
                self.status = "Sin datos en la foto"
            }
        }
    }
}

// MARK: - Live Preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> UIView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
