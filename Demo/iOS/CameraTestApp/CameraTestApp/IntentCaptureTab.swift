import SwiftUI
import UIKit

struct IntentCaptureTab: View {
    @State private var status = "Listo para captura por Intent"
    @State private var capturedImage: UIImage?
    @State private var imageSize: Int?
    @State private var showingPicker = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                // Image display or placeholder
                if let image = capturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(white: 0.961))
                        .frame(height: 280)
                        .overlay {
                            Text("La imagen aparecera aqui")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                }

                // Capture button
                Button {
                    status = "Lanzando camara del sistema..."
                    showingPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                        Text("Capturar por Intent")
                    }
                    .font(.body.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color(red: 0.298, green: 0.686, blue: 0.314), in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.horizontal)

                // Result card
                if let image = capturedImage, let size = imageSize {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Resultado:")
                            .font(.subheadline.bold())
                        Text("Thumbnail: \(Int(image.size.width))x\(Int(image.size.height))")
                            .font(.caption)
                        Text("Tamano JPEG: \(size) bytes")
                            .font(.caption)
                            .foregroundStyle(Color(red: 0.180, green: 0.490, blue: 0.196))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(red: 0.910, green: 0.961, blue: 0.914), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .sheet(isPresented: $showingPicker) {
            ImagePickerView { image in
                if let image {
                    capturedImage = image
                    let jpegData = image.jpegData(compressionQuality: 0.8)
                    imageSize = jpegData?.count ?? 0
                    status = "Intent capturada (\(imageSize ?? 0) bytes)"
                } else {
                    status = "Intent cancelado"
                }
            }
        }
    }
}

struct ImagePickerView: UIViewControllerRepresentable {
    var onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage?) -> Void

        init(onImagePicked: @escaping (UIImage?) -> Void) {
            self.onImagePicked = onImagePicked
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let image = info[.originalImage] as? UIImage
            picker.dismiss(animated: true)
            onImagePicked(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
            onImagePicked(nil)
        }
    }
}
