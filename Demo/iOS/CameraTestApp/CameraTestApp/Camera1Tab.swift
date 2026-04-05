import SwiftUI
import AVFoundation

struct Camera1Tab: View {
    @State private var viewModel = Camera1ViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
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
                        Text("Capturar (Camera1)")
                    }
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(red: 0.475, green: 0.333, blue: 0.282), in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!viewModel.isReady)
                .padding(.horizontal)

                // Result
                if let data = viewModel.photoData {
                    Text("Camera1 capturada (\(data.count) bytes)")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.298, green: 0.686, blue: 0.314))
                }
            }
            .padding(.vertical)
        }
        .onAppear { viewModel.setup() }
    }
}

@Observable
class Camera1ViewModel: NSObject, AVCapturePhotoCaptureDelegate {
    var status = "Listo para Camera1 (legacy)"
    var capturedImage: UIImage?
    var photoData: Data?
    var isReady = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera1.queue")

    func setup() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard authStatus == .authorized || authStatus == .notDetermined else {
            status = "Se requiere permiso de camara"
            return
        }
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.configureSession() }
                    else { self.status = "Permiso denegado" }
                }
            }
        } else {
            configureSession()
        }
    }

    private func configureSession() {
        sessionQueue.async { [self] in
            session.beginConfiguration()
            // Use front camera as the "alternate" config to differentiate from CameraX tab
            let position: AVCaptureDevice.Position = .front
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                Task { @MainActor in
                    self.status = "Error abriendo Camera1: dispositivo no disponible"
                }
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()
            session.startRunning()
            Task { @MainActor in
                self.status = "Camera1 preview activo"
                self.isReady = true
            }
        }
    }

    func capturePhoto() {
        status = "Capturando con Camera1..."
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        Task { @MainActor in
            if let error {
                self.status = "Error Camera1: \(error.localizedDescription)"
                return
            }
            if let data = photo.fileDataRepresentation() {
                self.photoData = data
                self.capturedImage = UIImage(data: data)
                self.status = "Camera1 capturada (\(data.count) bytes)"
            } else {
                self.status = "Error: no se pudo decodificar Camera1 JPEG"
            }
        }
    }
}
