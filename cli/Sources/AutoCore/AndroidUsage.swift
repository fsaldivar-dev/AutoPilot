import Foundation

/// Mensaje de uso del binario `auto-android`.
public enum AndroidUsage {

    public static func printUsage() {
        print("""
        AutoPilot Android — Android device automation via native agent

        Usage: auto-android <command> [arguments]
               auto-android --legacy <command>   (use slow adb bridge for benchmarks)

        Commands:
          ping                              Check ADB connection
          tree                              Print accessibility tree
          tree -s "query"                   Search elements
          layout [tipo]                     Wireframe ASCII del layout de pantalla (#107)
                                            flags: --compact (solo labeled), --region <label> (zoom)
          index [query]                     List indexed elements ($N syntax)
          inspect <query>                   Deep element inspection
          launch <package> [--inject img]    Launch app (--inject for camera mock)
          tap <label|$N|label[N]>           Tap element (supports $N and Label[2])
          longPress <text|desc|id> [secs]   Long press element
          doubleTap <text|desc|id>          Double tap element
          clear <text|desc|id>              Clear text field
          type [target] <text>              Type text
          scroll <text|desc|id> <direction> Scroll element
          swipe <up|down|left|right>        Swipe
          exists <text|desc|id>             Check if element exists
          list                              List devices
          install <path/to/app.apk>        Install APK
          elementAt <x> <y>                 Element at coordinate
          screenshot [filename.png]         Screenshot
          biometric <enroll|match|fail|status> Biometric control
          paste [text]                      Set/get clipboard
          camera start <image.jpg> [--package <pkg>]  Inject mock camera (JVMTI)
          camera feed <image.jpg> [--package <pkg>]  Update camera image (hot-swap)
          camera stop [--package <pkg>]              Stop mock camera (kills app)
          drag <from> <to> [secs]            Drag between elements
          drag x1,y1 x2,y2 [secs]           Drag between coordinates
          rotate <left|right|portrait|landscape>  Rotate device orientation
          pressKey <key>                     Press key (home, back, enter, delete, volumeUp, volumeDown, power)
          hideKeyboard                       Dismiss on-screen keyboard
          eraseText [N]                      Delete N characters (default 1)
          copyTextFrom <element>             Read text content from element
          clearState <package>               Clear app data (pm clear)
          uninstall <package>                Uninstall app
          waitUntilGone <label> [timeout]     Wait for element to disappear
          scrollTo <element> [direction]     Scroll until element is visible in viewport
          scrollUntilVisible <element> [dir] Alias of scrollTo (semantic name, emitted by recorder)
          startRecording                     Start screen recording
          stopRecording <file.mp4>           Stop recording and save
          setLocation <lat> <lon>            Set GPS location (emulator only)
          setAppearance <dark|light>         Switch dark/light mode
          lockDevice                         Lock device screen
          unlockDevice                       Unlock device screen
          pushFile <local> <remote>          Push file to device
          pullFile <remote> <local>          Pull file from device
          terminate <package>               Kill app
          permission <grant|revoke> <service> <package>  Manage app permissions
                                            services: camera, microphone, photos, contacts,
                                                      calendars, location, notifications
          logs [package] [--lines N]        Get device logs via logcat (last 50 lines)
          logs --system                     Get unfiltered system logs
          waitFor <label> [timeout]          Wait for element to appear (default 10s)
          config                            Show all config
          config <key> <value>              Set config value
                                            Android keys: android_project (raiz del proyecto
                                            gradle, requerido por build), android_module
                                            (modulo gradle, default: app)
          record <output.auto>               Record touch interactions to script (Ctrl+C to stop)
          run <script.auto>                 Run automation script
          doctor                            Check environment setup (adb, devices, agent)
          setup                             Full bootstrap — adb + device + apk + agent + warmup
          inject <image.jpg>                 Hot-swap mock camera image (no restart)
          build [module]                    Gradle assembleDebug wrapper (uses .autopilot)
          list <type>                       Typed UI listing via router
                                            type: all | buttons | text | textfields | cells |
                                                  switches | checkboxes | images | navbars

        Script format (.auto):
          # Comments start with #
          launch dev.autopilot.test.Explorea
          waitFor "Explorea"
          tap "Desbloquear con biometría"
          screenshot result.png

        Examples:
          auto-android launch dev.autopilot.test.Explorea
          auto-android tap "Explorea"
          auto-android tree -s "Login"
          auto-android swipe down
          auto-android run test-flow.auto

        Flags:
          --legacy                          Use slow adb bridge (for benchmarks)

        Requirements:
          - ADB installed (ANDROID_HOME or in PATH)
          - Device/emulator connected (adb devices)
          - AutoPilot agent installed (adb install agent.apk)
          - Agent running (adb shell am instrument -w dev.autopilot.agent/.AgentInstrumentation)
          - Socket forwarded (adb forward tcp:9008 localabstract:autopilot)
        """)
    }
}
