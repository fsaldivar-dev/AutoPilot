import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCodeScanned = { code in
            Task { @MainActor in
                context.coordinator.handleCode(code)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    class Coordinator {
        let onCodeScanned: (String) -> Void
        private var lastScanned: String?
        private var lastScanTime: Date?

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func handleCode(_ code: String) {
            let now = Date()
            if code != lastScanned || (lastScanTime.map { now.timeIntervalSince($0) > 3 } ?? true) {
                lastScanned = code
                lastScanTime = now
                onCodeScanned(code)
            }
        }
    }
}

// MARK: - QR Scanner UIKit Controller

class QRScannerViewController: UIViewController {
    var onCodeScanned: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let metadataQueue = DispatchQueue(label: "qr.metadata")
    private var metadataDelegate: MetadataDelegate?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func setupCamera() {
        // AutoPilot: QR inyectado via variable de entorno (CI/CD sin camara)
        if let code = ProcessInfo.processInfo.environment["AUTOPILOT_QR_CODE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.onCodeScanned?(code)
            }
            return
        }

        let session = AVCaptureSession()
        captureSession = session

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showPlaceholder()
            return
        }

        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showPlaceholder()
            return
        }

        session.addOutput(output)

        let callback = self.onCodeScanned
        let delegate = MetadataDelegate { code in
            callback?(code)
        }
        metadataDelegate = delegate
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr, .ean8, .ean13, .pdf417, .code128]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        startSession()
    }

    private func startSession() {
        guard let session = captureSession, !session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func stopSession() {
        guard let session = captureSession, session.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
    }

    private func showPlaceholder() {
        let label = UILabel()
        label.text = "Camara no disponible"
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
}

// MARK: - Metadata Delegate (nonisolated for AVFoundation)

private nonisolated class MetadataDelegate: NSObject, AVCaptureMetadataOutputObjectsDelegate {
    let onDetected: @Sendable (String) -> Void

    init(onDetected: @escaping @Sendable (String) -> Void) {
        self.onDetected = onDetected
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = metadata.stringValue else { return }
        onDetected(code)
    }
}
