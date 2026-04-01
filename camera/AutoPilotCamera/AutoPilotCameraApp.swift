import SwiftUI
import SystemExtensions

@main
struct AutoPilotCameraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 400, height: 200)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        installExtension()
    }

    func installExtension() {
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: "dev.autopilot.camera.extension",
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        print("Se requiere aprobacion del usuario en Preferencias del Sistema > Seguridad")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            print("Extension de camara instalada correctamente")
        case .willCompleteAfterReboot:
            print("Extension se completara despues de reiniciar")
        @unknown default:
            print("Resultado desconocido: \(result)")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        print("Error instalando extension: \(error.localizedDescription)")
    }
}

struct ContentView: View {
    @State private var status = "Instalando camara virtual..."

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundColor(.cyan)

            Text("AutoPilot Camera")
                .font(.title2)
                .bold()

            Text(status)
                .foregroundColor(.secondary)

            Text("Una vez instalada, usa desde la terminal:")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("auto camera start imagen.jpg")
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .background(Color.black.opacity(0.05))
                .cornerRadius(6)
        }
        .padding(24)
    }
}
