import Foundation

/// Mensaje de uso del binario `auto`.
public enum iOSUsage {

    public static func printUsage() {
        print("""
        AutoPilot — iOS Simulator automation

        Usage: auto <command> [arguments]

        Commands:
          ping                              Check Simulator is running
          tree                              Print accessibility tree
          tree -s "query"                   Search elements
          tree deep                         Deep tree via XCUI runner (slow, sees NavBar SwiftUI)
          tree full                         Fast + deep tree side by side
          layout [tipo] [deep]              Wireframe ASCII del layout de pantalla (#107)
                                            flags: --compact (solo labeled), --region <label> (zoom)
          list <type>                       Fast typed UI listing via XCUI runner (~1s vs 13s tree deep)
                                            type: all | buttons | labels | textfields | cells |
                                                  switches | links | images | navbars
                                            (sin args → lista simuladores, ver abajo)
          launch <bundleId> [--inject img]   Launch app (--inject for camera mock)
          tap <id|title|label>              Tap element
          tap[role] "label" within "scope"  Tap with role verification + scoped search
          longPress <id|title|label> [secs]  Long press element
          doubleTap <id|title|label>        Double tap element
          clear <id|title|label>            Clear text field
          type [target] <text>              Type text
          scroll <id|label> <direction>     Scroll element
          swipe <up|down|left|right>        Swipe
          drag <from> <to> [secs]            Drag between elements (default 0.5s)
          drag x1,y1 x2,y2 [secs]           Drag between coordinates
          exists <id|title|label>           Check if element exists
          assertOCR <text> [--region x,y,w,h]  Assert text visible on screen via OCR
                                            (Vision.framework — sirve para canvas/webviews/
                                            imagenes sin AX; region en pixeles, origen arriba-izq)
          list                              List simulators
          apps [--all]                      Installed apps on booted simulator (bundleId + name)
          boot <name|udid>                  Boot simulator
          shutdown <name|udid>              Shutdown simulator
          install <path/to/app.app>        Install app on simulator
          elementAt <x> <y>                 Element at coordinate
          screenshot [filename.png]         Screenshot (via simctl)
          assertScreen <baseline.png> [tol] Visual diff vs baseline (dHash 64 bits)
                                            tol: max bits distintos, default 10
                                            --create: guarda baseline si no existe
          inspect <query> --context           Parent chain + within suggestions
          inject <image.jpg>                 Change mock camera image (hot-swap)
          camera start <image>              Start virtual camera feed
          camera feed <image>               Update camera image
          camera stop                       Stop virtual camera
          camera status                     Check camera status
          terminate <bundleId>              Kill app
          permission <grant|revoke|reset> <service> <bundleId>  Manage app permissions
          logs [bundleId] [--lines N]       Get device logs (last 50 lines)
          logs --system                     Get system logs
          rotate <left|right|portrait|landscape>  Rotate device orientation
          pressKey <key>                     Press hardware key (home, enter, delete, tab, escape, volumeUp, volumeDown)
          hideKeyboard                       Dismiss on-screen keyboard
          eraseText [N]                      Delete N characters (default 1)
          copyTextFrom <element>             Read text content from element
          clearState <bundleId>              Clear app data and permissions
          uninstall <bundleId>               Uninstall app from simulator
          waitFor <label> [timeout]           Wait for element to appear (default 10s)
          waitUntilGone <label> [timeout]     Wait for element to disappear
          scrollTo <element> [direction]     Scroll until element is visible in viewport
          scrollUntilVisible <element> [dir] Alias of scrollTo (semantic name, emitted by recorder)
          startRecording                     Start screen recording
          stopRecording <file.mp4>           Stop recording and save
          setLocation <lat> <lon>            Set simulated GPS location
          setAppearance <dark|light>         Switch dark/light mode
          lockDevice                         Lock device screen
          unlockDevice                       Unlock device screen
          pushFile <local> <remote>          Push file to app data container
          pullFile <remote> <local>          Pull file from app data container
                                            remote: ruta absoluta o <bundleId>/<ruta>
                                            (ej: com.example.app/Documents/foto.jpg)
          config                             Show all config
          config <key> <value>              Set config value
          config <key>                      Get config value
          build                             Build with camera mock (uses .autopilot)
          build <xcodebuild args...>        Build with explicit args
          record <output.auto>               Record interactions to script (Ctrl+C to stop)
          run <script.auto>                 Run automation script
          doctor                            Check environment setup (Simulator, AX, xcrun)
          setup                             Full bootstrap — sim + runner + daemon (idempotente)
          daemon start [--udid U] [--timeout S]  Start sidecar daemon for XCTest runner
          daemon stop [--udid U]             Stop sidecar daemon
          daemon status [--udid U]           Show daemon and runner status
          runner install <Runner.app> [--udid U]  Install XCTest runner bundle
          runner status                      Show installed runner info

        Script format (.auto):
          # Comments start with #
          launch com.example.app
          waitFor "Login"
          tap "Username"
          type "user@test.com"
          screenshot result.png

        Examples:
          auto launch com.apple.Preferences
          auto tap "General"
          auto tap[button] "Login"
          auto tap "Camera" within "Toolbar"
          auto tap[button] "Camera[2]" within "Toolbar"
          auto inspect "Camera" --context
          auto tree -s "Información"
          auto swipe down
          auto waitFor "Login" 5
          auto pushFile foto.jpg com.example.app/Documents/foto.jpg
          auto run test-flow.auto

        Requirements:
          - Simulator.app must be running
          - Accessibility permissions (System Settings > Privacy > Accessibility)
        """)
    }
}
