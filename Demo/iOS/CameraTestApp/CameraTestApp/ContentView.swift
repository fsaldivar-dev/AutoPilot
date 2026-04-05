import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var selectedTab = 0
    private let tabs = ["CameraX", "QR", "OCR", "Intent", "Camera1", "ID"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            Text("Camera Test")
                .font(.title.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color(.systemBackground))

            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedTab = index
                            }
                        } label: {
                            Text(tab)
                                .font(.subheadline.weight(selectedTab == index ? .semibold : .regular))
                                .foregroundStyle(selectedTab == index ? Color.accentColor : .secondary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .overlay(alignment: .bottom) {
                                    if selectedTab == index {
                                        Rectangle()
                                            .fill(Color.accentColor)
                                            .frame(height: 2)
                                    }
                                }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .background(Color(.systemBackground))

            Divider()

            // Tab content
            TabView(selection: $selectedTab) {
                CameraXTab().tag(0)
                QrScanTab().tag(1)
                OcrTab().tag(2)
                IntentCaptureTab().tag(3)
                Camera1Tab().tag(4)
                IdCaptureTab().tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }
}

// MARK: - Shared Camera Preview

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
