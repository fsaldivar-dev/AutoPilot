import SwiftUI
import AVFoundation

struct CameraXTab: View {
    @State private var viewModel = CameraXViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Status
                Text(viewModel.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Camera preview
                CameraPreview(session: viewModel.session)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                // Captured image
                if let image = viewModel.capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 80)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Capture button
                Button {
                    viewModel.capturePhoto()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                        Text("Capturar Foto")
                    }
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(red: 0, green: 0.478, blue: 1), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Result — fingerprint verificable de la imagen capturada
                // (dimensiones + hash), para que el test compruebe que llegó
                // la imagen inyectada correcta, no solo "N bytes".
                if let data = viewModel.photoData, let image = viewModel.capturedImage {
                    VStack(spacing: 2) {
                        Text("Foto capturada:")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(ImageFingerprint.of(image, data: data))
                            .font(.caption.monospaced().bold())
                            .foregroundStyle(Color(red: 0.298, green: 0.686, blue: 0.314))
                    }
                }
            }
            .padding(.vertical)
        }
        .onAppear { viewModel.setup() }
    }
}

@Observable
class CameraXViewModel: NSObject, AVCapturePhotoCaptureDelegate {
    var status = "Camara lista"
    var capturedImage: UIImage?
    var photoData: Data?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camerax.queue")

    func setup() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .authorized:
            configureSession()
        case .notDetermined:
            status = "Solicitando permiso..."
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted {
                        self.configureSession()
                    } else {
                        self.status = "Permiso denegado"
                    }
                }
            }
        default:
            status = "Se requiere permiso de camara"
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
                self.status = "Foto capturada"
            }
        }
    }
}
