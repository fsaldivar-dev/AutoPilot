import SwiftUI
import AVFoundation

struct QrScanTab: View {
    @State private var viewModel = QrScanViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(viewModel.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Result — ARRIBA del preview: el payload decodificado visible
                // en el mirror sin scrollear. Es lo que el test verifica.
                if let result = viewModel.qrResult {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("QR detectado:")
                            .font(.subheadline.bold())
                        Text(result)
                            .font(.body)
                            .foregroundStyle(Color(red: 0.180, green: 0.490, blue: 0.196))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(red: 0.910, green: 0.961, blue: 0.914), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }

                // Camera preview
                CameraPreview(session: viewModel.session)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)

                // Scan button
                Button {
                    viewModel.scanQR()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("Escanear QR")
                    }
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(red: 0.612, green: 0.153, blue: 0.690), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
        }
        .onAppear { viewModel.setup() }
    }
}

@Observable
class QrScanViewModel: NSObject, AVCapturePhotoCaptureDelegate {
    var status = "Listo para escanear QR"
    var qrResult: String?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let metadataOutput = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "qrscan.queue")

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
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func scanQR() {
        status = "Capturando..."
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        Task { @MainActor in
            if let error {
                self.status = "Error captura: \(error.localizedDescription)"
                return
            }
            guard let data = photo.fileDataRepresentation(),
                  let ciImage = CIImage(data: data) else {
                self.status = "Error: no se pudo decodificar imagen"
                return
            }
            self.status = "Analizando QR..."
            let detector = CIDetector(ofType: CIDetectorTypeQRCode,
                                       context: nil,
                                       options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            let features = detector?.features(in: ciImage) as? [CIQRCodeFeature] ?? []
            if let qr = features.first?.messageString, !qr.isEmpty {
                self.qrResult = qr
                self.status = "QR detectado"
            } else {
                self.status = "No se detecto QR"
            }
        }
    }
}
