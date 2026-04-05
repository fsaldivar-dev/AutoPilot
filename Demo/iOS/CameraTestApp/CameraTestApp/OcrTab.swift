import SwiftUI
import AVFoundation
import Vision

struct OcrTab: View {
    @State private var viewModel = OcrViewModel()

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

                // OCR button
                Button {
                    viewModel.recognizeText()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "text.viewfinder")
                        Text("Reconocer Texto")
                    }
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(red: 1, green: 0.341, blue: 0.133), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Result
                if let text = viewModel.recognizedText {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Texto detectado:")
                            .font(.subheadline.bold())
                        ScrollView {
                            Text(text)
                                .font(.body)
                                .foregroundStyle(Color(red: 0.902, green: 0.318, blue: 0))
                        }
                        .frame(maxHeight: 200)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(red: 1, green: 0.953, blue: 0.878), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .onAppear { viewModel.setup() }
    }
}

@Observable
class OcrViewModel: NSObject, AVCapturePhotoCaptureDelegate {
    var status = "Listo para OCR"
    var recognizedText: String?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "ocr.queue")

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

    func recognizeText() {
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
                  let cgImage = UIImage(data: data)?.cgImage else {
                self.status = "Error: no se pudo decodificar imagen"
                return
            }
            self.status = "Reconociendo texto..."
            let request = VNRecognizeTextRequest { request, error in
                Task { @MainActor in
                    if let error {
                        self.status = "Error Vision: \(error.localizedDescription)"
                        return
                    }
                    let observations = request.results as? [VNRecognizedTextObservation] ?? []
                    let texts = observations.compactMap { $0.topCandidates(1).first?.string }
                    if texts.isEmpty {
                        self.status = "No se detecto texto"
                    } else {
                        self.recognizedText = texts.joined(separator: "\n")
                        self.status = "Texto detectado (\(observations.count) bloques)"
                    }
                }
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["es", "en"]
            let handler = VNImageRequestHandler(cgImage: cgImage)
            try? handler.perform([request])
        }
    }
}
