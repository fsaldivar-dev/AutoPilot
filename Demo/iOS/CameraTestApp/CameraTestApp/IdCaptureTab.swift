import SwiftUI
import AVFoundation

enum IdStep: Int, CaseIterable {
    case front = 0
    case back = 1
    case selfie = 2

    var label: String {
        switch self {
        case .front: return "Frente de ID"
        case .back: return "Reverso de ID"
        case .selfie: return "Selfie"
        }
    }

    var buttonText: String {
        switch self {
        case .front: return "Capturar Frente de ID"
        case .back: return "Capturar Reverso de ID"
        case .selfie: return "Capturar Selfie"
        }
    }

    var buttonColor: Color {
        switch self {
        case .front: return Color(red: 0.098, green: 0.463, blue: 0.824)
        case .back: return Color(red: 0, green: 0.592, blue: 0.655)
        case .selfie: return Color(red: 0.914, green: 0.118, blue: 0.388)
        }
    }

    var cameraPosition: AVCaptureDevice.Position {
        switch self {
        case .front, .back: return .back
        case .selfie: return .front
        }
    }
}

struct IdCaptureTab: View {
    @State private var viewModel = IdCaptureViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(viewModel.status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Step indicators
                HStack(spacing: 8) {
                    ForEach(IdStep.allCases, id: \.rawValue) { step in
                        let isCompleted = viewModel.captures[step] != nil
                        let isActive = step == viewModel.currentStep && !viewModel.isComplete

                        HStack(spacing: 4) {
                            if isCompleted {
                                Image(systemName: "checkmark")
                                    .font(.caption2.bold())
                            }
                            Text(step.label)
                                .font(.caption2)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            if isCompleted {
                                Capsule().fill(Color(red: 0.298, green: 0.686, blue: 0.314))
                            } else if isActive {
                                Capsule().strokeBorder(Color(red: 0.098, green: 0.463, blue: 0.824), lineWidth: 2)
                            } else {
                                Capsule().strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                            }
                        }
                        .foregroundStyle(isCompleted ? .white : (isActive ? Color(red: 0.098, green: 0.463, blue: 0.824) : .secondary))
                    }
                }
                .padding(.horizontal)

                // Camera preview
                if !viewModel.isComplete {
                    CameraPreview(session: viewModel.session)
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                }

                // Capture button
                if let step = viewModel.currentStep, !viewModel.isComplete {
                    Button {
                        viewModel.captureCurrentStep()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: step == .selfie ? "person.fill" : "person.text.rectangle")
                            Text(step.buttonText)
                        }
                        .font(.body.bold())
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(step.buttonColor, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                }

                // Captures grid
                if !viewModel.captures.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(viewModel.isComplete ? "Verificacion completa" : "Capturas realizadas")
                            .font(.subheadline.bold())
                            .foregroundStyle(viewModel.isComplete ? Color(red: 0.180, green: 0.490, blue: 0.196) : .primary)

                        HStack(spacing: 8) {
                            ForEach(IdStep.allCases, id: \.rawValue) { step in
                                if let capture = viewModel.captures[step] {
                                    VStack(spacing: 4) {
                                        Image(uiImage: capture.image)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 80, height: 80)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                        Text(step.label)
                                            .font(.caption2)
                                        // Fingerprint verificable por paso
                                        // (dimensiones + hash).
                                        Text(capture.image.jpegData(compressionQuality: 0.8)
                                            .map { ImageFingerprint.of(capture.image, data: $0) }
                                            ?? "\(capture.size) bytes")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(Color(red: 0.298, green: 0.686, blue: 0.314))
                                            .multilineTextAlignment(.center)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        viewModel.isComplete
                            ? Color(red: 0.910, green: 0.961, blue: 0.914)
                            : Color(white: 0.980),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .onAppear { viewModel.setup() }
    }
}

struct IdCapture {
    let image: UIImage
    let size: Int
}

@Observable
class IdCaptureViewModel: NSObject, AVCapturePhotoCaptureDelegate {
    var status = "Paso 1/3: Captura frente de ID"
    var currentStep: IdStep? = .front
    var captures: [IdStep: IdCapture] = [:]
    var isComplete = false

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "idcapture.queue")
    private var currentInput: AVCaptureDeviceInput?

    func setup() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        guard authStatus == .authorized || authStatus == .notDetermined else {
            status = "Se requiere permiso de camara"
            return
        }
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in
                    if granted { self.configureSession(position: .back) }
                    else { self.status = "Permiso denegado" }
                }
            }
        } else {
            configureSession(position: .back)
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) {
        sessionQueue.async { [self] in
            session.beginConfiguration()

            if let existing = currentInput {
                session.removeInput(existing)
            }

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            currentInput = input

            if photoOutput.connections.isEmpty, session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            session.commitConfiguration()

            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func captureCurrentStep() {
        guard let step = currentStep else { return }
        status = "Capturando \(step.label)..."
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        Task { @MainActor in
            guard let step = self.currentStep else { return }

            if let error {
                self.status = "Error: \(error.localizedDescription)"
                return
            }

            guard let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data) else {
                self.status = "Error: no se pudo decodificar"
                return
            }

            self.captures[step] = IdCapture(image: image, size: data.count)

            // Advance to next step
            let allSteps = IdStep.allCases
            if let nextIndex = allSteps.firstIndex(of: step).map({ $0 + 1 }),
               nextIndex < allSteps.count {
                let nextStep = allSteps[nextIndex]
                self.currentStep = nextStep
                self.status = "Paso \(nextStep.rawValue + 1)/3: Captura \(nextStep.label)"

                // Switch camera if needed
                if nextStep.cameraPosition != step.cameraPosition {
                    self.configureSession(position: nextStep.cameraPosition)
                }
            } else {
                self.isComplete = true
                self.currentStep = nil
                self.status = "Verificacion completa (\(self.captures.count)/3 capturas)"
            }
        }
    }
}
