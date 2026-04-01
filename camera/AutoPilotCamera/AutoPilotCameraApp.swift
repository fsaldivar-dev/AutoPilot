import SwiftUI
import CoreMediaIO
import os.log

private let log = Logger(subsystem: "dev.autopilot.camera", category: "App")

@main
struct AutoPilotCameraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(delegate: appDelegate)
                .frame(width: 400, height: 250)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    @Published var status: String = "Iniciando camara virtual..."
    private var providerSource: CameraProviderSource?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Iniciando CMIOExtensionProvider en proceso de la app...")
        startCameraProvider()
    }

    func startCameraProvider() {
        providerSource = CameraProviderSource(clientQueue: nil)
        log.info("Provider creado, iniciando servicio...")

        // startService no retorna — se queda en run loop
        // Lo ejecutamos en background
        DispatchQueue.global(qos: .userInitiated).async {
            CMIOExtensionProvider.startService(provider: self.providerSource!.provider)
            // Si llega aqui, algo fallo
            log.error("startService retorno inesperadamente")
        }

        // Verificar despues de un momento
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            log.info("Camara virtual deberia estar activa")
            self.status = "Camara virtual activa"
        }
    }
}

struct ContentView: View {
    @ObservedObject var delegate: AppDelegate

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundColor(delegate.status.contains("activa") ? .green : .cyan)

            Text("AutoPilot Camera")
                .font(.title2)
                .bold()

            Text(delegate.status)
                .foregroundColor(delegate.status.contains("activa") ? .green : .secondary)
                .multilineTextAlignment(.center)

            Divider()

            Text("Usa desde la terminal:")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("auto camera start imagen.jpg")
                Text("auto camera feed otra.jpg")
                Text("auto camera stop")
            }
            .font(.system(.caption, design: .monospaced))
            .padding(8)
            .background(Color.black.opacity(0.05))
            .cornerRadius(6)
        }
        .padding(24)
    }
}
