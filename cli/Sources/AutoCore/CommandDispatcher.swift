import Foundation

/// Handles platform-agnostic commands via any DeviceBridge.
/// Returns true if the command was handled, false if unrecognized (for platform-specific fallthrough).
///
/// - Parameters:
///   - args: command-line arguments (first is the verb)
///   - bridge: the primary DeviceBridge (usually HybridBridge on iOS, AgentBridge on Android)
///   - deepBridge: optional deep-only bridge (e.g. XCUIBridge on iOS). When provided,
///                 `tree deep` and `tree full` subcommands will use it. On Android this is nil.
public func executeSharedCommand(
    _ args: [String],
    bridge: any DeviceBridge,
    deepBridge: (any DeviceBridge)? = nil,
    router: ActionRouter? = nil,
    autoWait: AutoWait.Config = .current
) throws -> Bool {
    guard let rawCmd = args.first else { return false }

    // Strip [role] suffix for switch matching: "tap[button]" → "tap"
    let cmd: String
    if let bracket = rawCmd.firstIndex(of: "[") {
        cmd = String(rawCmd[rawCmd.startIndex..<bracket])
    } else {
        cmd = rawCmd
    }

    let start = CFAbsoluteTimeGetCurrent()

    switch cmd {

    case "tree":
        if args.count >= 3 && (args[1] == "--search" || args[1] == "-s") {
            let results = try bridge.search(query: args[2])
            let ms = elapsedMs(start)
            if results.isEmpty {
                print("No elements found matching '\(args[2])'")
            } else {
                print("Found \(results.count) element(s) matching '\(args[2])' (\(ms)ms):\n")
                for el in results {
                    printElement(el)
                }
            }
        } else if args.count >= 2 && args[1] == "deep" {
            // Force deep bridge (XCUI on iOS) — slow, sees everything SwiftUI exposes
            guard let deep = deepBridge else {
                print("tree deep: no deep bridge available on this platform (iOS only)")
                return true
            }
            let tree = try deep.tree()
            let ms = elapsedMs(start)
            TreePrinter.printAX(tree)
            print("\n(\(ms)ms — deep)")
        } else if args.count >= 2 && args[1] == "full" {
            // Fast + deep merged — deep adds what fast missed (NavBar buttons, etc.)
            let fastTree = (try? bridge.tree()) ?? []
            let deepTree: [[String: Any]]
            if let deep = deepBridge {
                deepTree = (try? deep.tree()) ?? []
            } else {
                deepTree = []
            }
            let ms = elapsedMs(start)
            print("=== fast (AX macOS) ===")
            TreePrinter.printAX(fastTree)
            if !deepTree.isEmpty {
                print("\n=== deep (XCUI runner) ===")
                TreePrinter.printAX(deepTree)
            } else if deepBridge == nil {
                print("\n(no deep bridge available on this platform)")
            }
            print("\n(\(ms)ms — full)")
        } else {
            let tree = try runActionReturning(
                .tree,
                router: router,
                fallback: { try bridge.tree() },
                extract: { if case .elements(let es) = $0 { return es } else { return nil } }
            )
            let ms = elapsedMs(start)
            TreePrinter.printAX(tree)
            print("\n(\(ms)ms)")
        }

    case "layout":
        // #107 — wireframe ASCII de la pantalla. Cross-platform: reusa .tree
        // via router (ARD-001) y escala los frames a un grid de caracteres.
        // Variantes: `layout deep` (iOS XCUI), `layout buttons` (filtro por
        // tipo, mismos nombres que `list`), `--compact`, `--region <label>`.
        var options = AsciiLayout.Options()
        var useDeep = false
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "deep":
                useDeep = true
            case "--compact":
                options.compact = true
            case "--region":
                guard i + 1 < args.count else {
                    print("Usage: auto layout [tipo] [deep] [--compact] [--region <label>]")
                    return true
                }
                i += 1
                options.region = args[i]
            default:
                if AsciiLayout.allowedTypeFilters.contains(arg.lowercased()) {
                    options.typeFilter = arg.lowercased()
                } else {
                    print("layout: argumento desconocido '\(arg)'")
                    print("Usage: auto layout [tipo] [deep] [--compact] [--region <label>]")
                    print("       tipo: \(AsciiLayout.allowedTypeFilters.sorted().joined(separator: " | "))")
                    return true
                }
            }
            i += 1
        }

        let layoutTree: [[String: Any]]
        if useDeep {
            guard let deep = deepBridge else {
                print("layout deep: no deep bridge available on this platform (iOS only)")
                return true
            }
            layoutTree = try deep.tree()
        } else {
            layoutTree = try runActionReturning(
                .tree,
                router: router,
                fallback: { try bridge.tree() },
                extract: { if case .elements(let es) = $0 { return es } else { return nil } }
            )
        }

        // Viewport real del device; si el bridge no lo resuelve, bounding box
        // de los frames raíz del tree (suficiente para escalar proporcional).
        let screen: CGRect
        if let vp = try? bridge.viewport(), vp.width > 0, vp.height > 0 {
            screen = vp
        } else if let box = AsciiLayout.boundingBox(of: layoutTree) {
            screen = box
        } else {
            print("layout: no pude resolver viewport ni frames en el tree")
            return true
        }

        print(AsciiLayout.render(tree: layoutTree, viewport: screen, options: options))
        print("\n(\(elapsedMs(start))ms\(useDeep ? " — deep" : ""))")

    case "tap":
        guard args.count >= 2 else {
            print("Usage: auto tap <label>")
            print("       auto tap a,b,c      (multiple)")
            return true
        }
        // Labels estándar pueden contener comas ("Nombre, iPhone" en celdas iOS).
        // TapTargets decide con match exacto sobre el árbol rápido: si el label
        // completo existe → un solo tap; si no → multi-tap por fragmentos (#124).
        // El árbol que TapTargets fetchea (solo si hay coma) se reusa como
        // primera muestra del loop de estabilidad de AutoWait (#157) — cero
        // fetches duplicados.
        var seedTree: [[String: Any]]? = nil
        let targets = try TapTargets.resolve(args[1]) {
            let tree = try bridge.tree()
            seedTree = tree
            return tree
        }
        // #158: en un multi-tap la estabilización pre-acción se hace UNA sola
        // vez, antes del primer target. Para un keypad de PIN (`tap 1,2,3,4`)
        // el layout no cambia entre dígitos: re-estabilizar en cada iteración
        // era el grueso del costo creciente por tap que vio el QA tras #157.
        // Estabilizamos una vez y reusamos el pre-hash para la verificación
        // post-tap de cada dígito.
        let isMultiTap = targets.count > 1
        var sharedSnapshot: AutoWait.Snapshot?
        if isMultiTap {
            sharedSnapshot = AutoWait.stabilize(initialTree: seedTree, config: autoWait) { try bridge.tree() }
            seedTree = nil
        }
        for target in targets {
            // #158: cronómetro POR target — el reporte "Tapped 'X' (Nms)" debe
            // mostrar el tiempo real de ESE tap, no el acumulado desde el inicio
            // del comando (antes todos los targets imprimían elapsedMs(start),
            // dando 194→462→1829→…, números acumulados y engañosos).
            let targetStart = CFAbsoluteTimeGetCurrent()
            // #157: pre-acción — espera a que el árbol se estabilice (2 lecturas
            // con el mismo hash). En multi-tap reusamos la estabilización única
            // (#158); en tap único estabilizamos aquí. Devuelve el pre-hash
            // para la verificación.
            let doTap = { try runAction(.tap(target: target), router: router,
                                        fallback: { try bridge.tap(target: target) }) }
            let snapshot: AutoWait.Snapshot?
            if isMultiTap {
                snapshot = sharedSnapshot
            } else {
                snapshot = AutoWait.stabilize(initialTree: seedTree, config: autoWait) { try bridge.tree() }
                seedTree = nil // solo el primer target hereda el árbol de TapTargets
            }
            try doTap()
            // #157: post-tap — retryTapIfNoChange. Sin cambio de hash → un
            // re-tap → sin cambio → warning honesto en stderr (no error duro:
            // hay taps legítimos sin efecto visual, ver AutoWait.swift).
            if let snapshot {
                AutoWait.verifyTapEffect(target: target, preHash: snapshot.hash, config: autoWait,
                                         fetch: { try bridge.tree() }, retap: doTap)
            }
            print("Tapped '\(target)' (\(elapsedMs(targetStart))ms)")
        }

    case "longPress":
        guard args.count >= 2 else {
            print("Usage: auto longPress <identifier|title|label> [seconds]")
            return true
        }
        let duration = args.count >= 3 ? Double(args[2]) ?? 1.0 : 1.0
        try runAction(.longPress(target: args[1], duration: duration), router: router,
                      fallback: { try bridge.longPress(target: args[1], duration: duration) })
        let ms = elapsedMs(start)
        print("Long pressed '\(args[1])' for \(duration)s (\(ms)ms)")

    case "doubleTap":
        guard args.count >= 2 else {
            print("Usage: auto doubleTap <identifier|title|label>")
            return true
        }
        try runAction(.doubleTap(target: args[1]), router: router,
                      fallback: { try bridge.doubleTap(target: args[1]) })
        let ms = elapsedMs(start)
        print("Double tapped '\(args[1])' (\(ms)ms)")

    case "clear":
        guard args.count >= 2 else {
            print("Usage: auto clear <identifier|title|label>")
            return true
        }
        try runAction(.clear(target: args[1]), router: router,
                      fallback: { try bridge.clear(target: args[1]) })
        let ms = elapsedMs(start)
        print("Cleared '\(args[1])' (\(ms)ms)")

    case "type":
        // Parse type[N] for "Nth text input" syntax. The bracket part is in
        // rawCmd because the switch above stripped it. Numeric -> index of
        // text input in tree (1-based, only AXTextField/AXSecureTextField/EditText).
        var nthInputIndex: Int? = nil
        if let bracket = rawCmd.firstIndex(of: "["),
           let end = rawCmd.lastIndex(of: "]"),
           bracket < end {
            let inner = String(rawCmd[rawCmd.index(after: bracket)..<end])
            nthInputIndex = Int(inner)
        }

        guard args.count >= 2 else {
            print("Usage: auto type <text>")
            print("       auto type <target> <text>      (tap target, then type)")
            print("       auto type[N] <text>            (tap Nth text input, then type)")
            return true
        }

        // #157: pre-acción — no tipear sobre una UI en transición (el campo
        // puede estar moviéndose mientras aparece el teclado o una animación).
        AutoWait.stabilize(config: autoWait) { try bridge.tree() }

        if let n = nthInputIndex {
            // type[N] "text" — find Nth text input in tree, tap its center, then type.
            // Filters by role (AXTextField/AXSecureTextField/EditText) so it never
            // resolves to a sibling AXStaticText with the same label.
            let snapshot = try preTapTreeSnapshot(bridge: bridge)
            try tapNthTextInput(tree: snapshot.tree, bridge: bridge, index: n)
            settleBeforeType(bridge: bridge, snapshot: snapshot)
            try runAction(.typeText(args[1]), router: router, fallback: { try bridge.typeText(args[1]) })
        } else if args.count >= 3 {
            // type "target" "text" — smart resolution: prefer the text input whose
            // label/value/identifier matches the target over a sibling AXStaticText
            // with the same label. This is what makes
            //   type "Email o DNI" "user@example.com"
            // work even when the form has both an AXStaticText (visible label above
            // the field) and an AXTextField (placeholder text inside the field) with
            // the same string.
            let snapshot = try preTapTreeSnapshot(bridge: bridge)
            if try !tapTextInputByLabel(tree: snapshot.tree, bridge: bridge, label: args[1]) {
                // Fallback to plain tap when no text input matches the label
                // (the target may be a button, link, etc.)
                try runAction(.tap(target: args[1]), router: router, fallback: { try bridge.tap(target: args[1]) })
            }
            settleBeforeType(bridge: bridge, snapshot: snapshot)
            try runAction(.typeText(args[2]), router: router, fallback: { try bridge.typeText(args[2]) })
        } else {
            try runAction(.typeText(args[1]), router: router, fallback: { try bridge.typeText(args[1]) })
        }
        let ms = elapsedMs(start)
        print("Typed text (\(ms)ms)")

    case "scroll":
        guard args.count >= 3 else {
            print("Usage: auto scroll <identifier|title|label> <up|down|left|right>")
            return true
        }
        // #157: pre-acción — scrollear un contenedor que aún está animando
        // produce offsets impredecibles; esperamos estabilidad primero.
        AutoWait.stabilize(config: autoWait) { try bridge.tree() }
        try runAction(.scroll(target: args[1], direction: args[2]), router: router,
                      fallback: { try bridge.scroll(target: args[1], direction: args[2]) })
        let ms = elapsedMs(start)
        print("Scrolled '\(args[1])' \(args[2]) (\(ms)ms)")

    case "swipe":
        guard args.count >= 2 else {
            print("Usage: auto swipe <up|down|left|right>")
            return true
        }
        try runAction(.swipe(direction: args[1]), router: router,
                      fallback: { try bridge.swipe(direction: args[1]) })
        let ms = elapsedMs(start)
        print("Swiped \(args[1]) (\(ms)ms)")

    case "screenshot":
        let filename = args.count >= 2 ? args[1] : "screenshot.png"
        // #155: vía router → en iOS captura el framebuffer del device
        // (MediaBackend/simctl), nunca la ventana del Mac (runner XCUI).
        try runAction(.screenshot(path: filename), router: router,
                      fallback: { try bridge.screenshot(path: filename) })
        let ms = elapsedMs(start)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filename)[.size] as? Int) ?? 0
        print("Saved: \(filename) (\(fileSize / 1024)KB, \(ms)ms)")

    case "assertScreen":
        // Diff visual por perceptual hash (#56): screenshot actual vs baseline.
        // assertScreen <baseline.png> [tolerancia 0-64] [--create]
        var rest = Array(args.dropFirst())
        let createBaseline = rest.contains("--create")
        rest.removeAll { $0 == "--create" }
        guard let baselinePath = rest.first else {
            print("Usage: auto assertScreen <baseline.png> [tolerance 0-64] [--create]")
            print("       tolerance: max Hamming distance in bits (default \(ScreenAssert.defaultTolerance))")
            print("       --create:  save current screen as baseline if it doesn't exist")
            return true
        }
        var tolerance = ScreenAssert.defaultTolerance
        if rest.count >= 2 {
            guard let t = Int(rest[1]), (0...PerceptualHash.bits).contains(t) else {
                print("Invalid tolerance '\(rest[1])' — must be an integer 0-\(PerceptualHash.bits)")
                return true
            }
            tolerance = t
        }

        if !FileManager.default.fileExists(atPath: baselinePath) {
            guard createBaseline else {
                throw BridgeError.baselineNotFound(baselinePath)
            }
            try runAction(.screenshot(path: baselinePath), router: router,
                          fallback: { try bridge.screenshot(path: baselinePath) })
            print("Baseline created: \(baselinePath) (\(elapsedMs(start))ms)")
            return true
        }

        let currentPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-assertscreen-\(UUID().uuidString).png").path
        // defer ANTES de capturar (#155): el PNG temporal se borra también
        // cuando el assert falla (mismatch lanza, pero el defer ya corre).
        defer { try? FileManager.default.removeItem(atPath: currentPath) }
        try runAction(.screenshot(path: currentPath), router: router,
                      fallback: { try bridge.screenshot(path: currentPath) })
        let result = try ScreenAssert.assertMatch(
            currentPath: currentPath,
            baselinePath: baselinePath,
            tolerance: tolerance
        )
        print("MATCH (distance \(result.distance)/\(PerceptualHash.bits), tolerance \(tolerance)) (\(elapsedMs(start))ms)")

    case "exists":
        guard args.count >= 2 else {
            print("Usage: auto exists <identifier|title|label>")
            return true
        }
        let results = try runActionReturning(
            .search(query: args[1]),
            router: router,
            fallback: { try bridge.search(query: args[1]) },
            extract: { if case .elements(let es) = $0 { return es } else { return nil } }
        )
        let ms = elapsedMs(start)
        print(results.isEmpty ? "NO (\(ms)ms)" : "YES (\(ms)ms)")

    case "visible", "isVisible":
        guard args.count >= 2 else {
            print("Usage: auto visible <identifier|title|label>")
            return true
        }
        let tree = try bridge.tree()
        var visible = false
        if let el = ViewportUtil.findFirst(in: tree, matching: args[1]),
           let frame = ViewportUtil.rect(from: el["frame"] as? [String: Any]) {
            let vp = try bridge.viewport()
            visible = ViewportUtil.isVisible(frame: frame, inViewport: vp)
        }
        let ms = elapsedMs(start)
        print(visible ? "YES (\(ms)ms)" : "NO (\(ms)ms)")

    case "hasText":
        guard args.count >= 3 else {
            print("Usage: auto hasText <identifier|title|label> <expected>")
            return true
        }
        let tree = try bridge.tree()
        var match = false
        if let el = ViewportUtil.findFirst(in: tree, matching: args[1]) {
            let expected = args[2]
            let label = el["label"] as? String ?? ""
            let value = el["value"] as? String ?? ""
            let title = el["title"] as? String ?? ""
            match = label.contains(expected) || value.contains(expected) || title.contains(expected)
        }
        let ms = elapsedMs(start)
        print(match ? "YES (\(ms)ms)" : "NO (\(ms)ms)")

    case "assertOCR":
        // #55 — verificación visual de texto via Vision.framework.
        // screenshot → OCR (accurate, es+en) → contains case-insensitive.
        // Vision corre en el Mac sobre el PNG del bridge, por eso el mismo
        // flujo sirve para iOS (simctl) y Android (agente/adb). Complementa
        // exists/hasText para texto que solo existe en píxeles (canvas,
        // webviews, imágenes).
        guard args.count >= 2, args[1] != "--region" else {
            print("Usage: auto assertOCR <text> [--region x,y,w,h]")
            print("       Asserts text is visible on screen via OCR (Vision.framework).")
            print("       --region crops the screenshot before OCR (pixels, top-left origin).")
            return true
        }
        let expectedText = args[1]
        var region: OCRAssert.Region? = nil
        if let idx = args.firstIndex(of: "--region") {
            guard idx + 1 < args.count else {
                print("Usage: auto assertOCR <text> [--region x,y,w,h]")
                return true
            }
            region = try OCRAssert.Region.parse(args[idx + 1])
        }
        let tmpPath = NSTemporaryDirectory() + "autopilot-ocr-\(UUID().uuidString).png"
        // defer ANTES de capturar (#155): el PNG temporal se borra también si
        // la captura o el OCR fallan (ocrTextNotFound lanza más abajo).
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        // #155: vía router → framebuffer del device, no la ventana del Mac.
        try runAction(.screenshot(path: tmpPath), router: router,
                      fallback: { try bridge.screenshot(path: tmpPath) })
        let recognized = try OCRAssert.recognizeText(imagePath: tmpPath, region: region)
        let ms = elapsedMs(start)
        if let match = OCRAssert.findMatch(for: expectedText, in: recognized) {
            print("FOUND '\(expectedText)' (confidence \(String(format: "%.2f", match.confidence)), \(ms)ms)")
        } else {
            throw BridgeError.ocrTextNotFound(expected: expectedText,
                                              recognized: recognized.map(\.string))
        }

    case "platform":
        // Platform runtime. iOS CLI siempre emite "ios"; Android CLI override
        // este comando en su propio dispatcher si hace falta.
        let ms = elapsedMs(start)
        print("ios (\(ms)ms)")

    case "orientation":
        let rect = try bridge.viewport()
        let orient = rect.height >= rect.width ? "portrait" : "landscape"
        let ms = elapsedMs(start)
        print("\(orient) (\(ms)ms)")

    case "terminate":
        guard args.count >= 2 else {
            print("Usage: auto terminate <bundleId>")
            return true
        }
        try bridge.terminateApp(bundleId: args[1])
        let ms = elapsedMs(start)
        print("Terminated \(args[1]) (\(ms)ms)")

    case "elementAt":
        guard args.count >= 3,
              let x = Double(args[1]),
              let y = Double(args[2]) else {
            print("Usage: auto elementAt <x> <y>")
            return true
        }
        // Wrap in a single-element array so `runActionReturning` can distinguish
        // "extracted nil" from "did not extract". [nil] passes through, [] =
        // extract failed → fallback. extract() returns [element] or [] or nil.
        let wrapped: [[String: Any]?] = try runActionReturning(
            .elementAt(x: x, y: y),
            router: router,
            fallback: { [try bridge.elementAt(x: x, y: y)] },
            extract: {
                if case .element(let e) = $0 { return [e] }
                // Some backends may return .void when no element found.
                if case .void = $0 { return [nil] }
                return nil
            }
        )
        if let el = wrapped.first ?? nil {
            printElement(el)
        } else {
            print("No element at (\(args[1]), \(args[2]))")
        }

    case "tapAt":
        guard args.count >= 3,
              let x = Double(args[1]),
              let y = Double(args[2]) else {
            print("Usage: auto tapAt <x> <y>")
            return true
        }
        try runAction(.tapAtCoordinate(x: x, y: y), router: router,
                      fallback: { try bridge.tapAtCoordinate(x: x, y: y) })
        let ms = elapsedMs(start)
        print("Tapped at (\(args[1]), \(args[2])) (\(ms)ms)")

    case "media":
        guard args.count >= 2 else {
            print("Usage: auto media <image_path> [image2 ...]")
            return true
        }
        for path in args.dropFirst() {
            try bridge.addMedia(path: path)
            print("Injected: \(path)")
        }
        let ms = elapsedMs(start)
        print("Done (\(ms)ms)")

    case "paste":
        if args.count >= 2 {
            try bridge.setPasteboard(text: args[1])
            print("Set pasteboard: \(args[1])")
        } else {
            let text = try bridge.getPasteboard()
            print(text)
        }

    case "boot":
        guard args.count >= 2 else {
            print("Usage: auto boot <device_name|udid>")
            return true
        }
        try bridge.bootDevice(args[1])
        let ms = elapsedMs(start)
        print("Booted '\(args[1])' (\(ms)ms)")

    case "shutdown":
        guard args.count >= 2 else {
            print("Usage: auto shutdown <device_name|udid>")
            return true
        }
        try bridge.shutdownDevice(args[1])
        let ms = elapsedMs(start)
        print("Shutdown '\(args[1])' (\(ms)ms)")

    case "install":
        guard args.count >= 2 else {
            print("Usage: auto install <path/to/app.app>")
            return true
        }
        try bridge.installApp(path: args[1])
        let ms = elapsedMs(start)
        print("Installed \(args[1]) (\(ms)ms)")

    case "list":
        let devices = try bridge.listDevices()
        let ms = elapsedMs(start)
        let booted = devices.filter { $0["state"] as? String == "Booted" }
        let shutdown = devices.filter { $0["state"] as? String == "Shutdown" }

        if !booted.isEmpty {
            print("Booted:")
            for d in booted {
                print("  \(d["name"]!)  \(d["os"]!)  \(d["udid"]!)")
            }
        }
        if !shutdown.isEmpty {
            print("Available:")
            for d in shutdown {
                print("  \(d["name"]!)  \(d["os"]!)")
            }
        }
        print("\n\(devices.count) device(s) (\(ms)ms)")

    case "openurl":
        guard args.count >= 2 else {
            print("Usage: auto openurl <url>")
            return true
        }
        try bridge.openURL(args[1])
        let ms = elapsedMs(start)
        print("Opened URL (\(ms)ms)")

    case "waitFor":
        guard args.count >= 2 else {
            print("Usage: auto waitFor <identifier|label> [timeout_seconds]")
            return true
        }
        let target = args[1]
        let timeout = args.count >= 3 ? Double(args[2]) ?? 10.0 : 10.0

        // #79: poll interval bajado de 500ms → 100ms para capturar transiciones
        // breves (dialogs de permisos <500ms). Para mantener el CPU cost acotado
        // usamos `existsFast` (shallow, ~5-10ms) cuando el requiredCount es 1;
        // solo caemos a `search()` full-tree si el caller pide `label[N]` con N>1.
        let pollInterval: useconds_t = 100_000
        let maxAttempts = Int(timeout * 10)

        // Support label[N] syntax: waitFor "Cerrar sesion[2]" waits for 2+ matches
        let (searchLabel, requiredCount) = TargetResolverShared.parse(target)
        let minMatches = requiredCount ?? 1
        let needsCountQuery = minMatches > 1

        var found = false
        var pollCount = 0
        for _ in 0..<maxAttempts {
            pollCount += 1
            if needsCountQuery {
                // label[N] — necesitamos contar, cae a search() full-tree
                if let results = try? bridge.search(query: searchLabel), results.count >= minMatches {
                    found = true
                    break
                }
            } else {
                // Caso común: solo nos importa ≥1 match. existsFast binario.
                if (try? bridge.existsFast(label: searchLabel)) == true {
                    found = true
                    break
                }
            }
            usleep(pollInterval)
        }

        let ms = elapsedMs(start)
        debugTimingLog("waitFor target=\(target) found=\(found) polls=\(pollCount) elapsed=\(ms)ms")
        if found {
            print("Found '\(target)' (\(ms)ms)")
        } else {
            throw BridgeError.timeout("Timeout: '\(target)' not found after \(timeout)s")
        }

    case "waitUntilGone":
        guard args.count >= 2 else {
            print("Usage: auto waitUntilGone <identifier|label> [timeout_seconds]")
            return true
        }
        let target = args[1]
        let timeout = args.count >= 3 ? Double(args[2]) ?? 10.0 : 10.0

        // #79: mismo tratamiento que waitFor — poll 100ms + existsFast
        let pollInterval: useconds_t = 100_000
        let maxAttempts = Int(timeout * 10)

        // Support label[N] syntax: waitUntilGone "Item[2]" waits until fewer than 2 matches
        let (searchLabel, requiredCount) = TargetResolverShared.parse(target)
        let minMatches = requiredCount ?? 1
        let needsCountQuery = minMatches > 1

        var gone = false
        for _ in 0..<maxAttempts {
            if needsCountQuery {
                let results = (try? bridge.search(query: searchLabel)) ?? []
                if results.count < minMatches {
                    gone = true
                    break
                }
            } else {
                if (try? bridge.existsFast(label: searchLabel)) == false {
                    gone = true
                    break
                }
            }
            usleep(pollInterval)
        }

        let wms = elapsedMs(start)
        if gone {
            print("Gone '\(target)' (\(wms)ms)")
        } else {
            throw BridgeError.timeout("Timeout: '\(target)' still present after \(timeout)s")
        }

    case "config":
        if args.count < 2 {
            let config = AutoPilotConfig.readAll()
            if config.isEmpty {
                print("No config set. Use: auto config <key> <value>")
                print("\nAvailable keys:")
                for k in AutoPilotConfig.knownKeys {
                    print("  \(k.key.padding(toLength: 16, withPad: " ", startingAt: 0)) \(k.description)")
                }
            } else {
                print(".autopilot config:")
                for (key, val) in config.sorted(by: { $0.key < $1.key }) {
                    print("  \(key) = \(val)")
                }
            }
            return true
        }
        let key = args[1]
        if args.count < 3 {
            if let val = AutoPilotConfig.get(key) {
                print("\(key) = \(val)")
            } else {
                print("\(key) is not set")
            }
            return true
        }
        let value = args[2...].joined(separator: " ")
        AutoPilotConfig.set(key, value: value)
        print("Set \(key) = \(value)")

    case "wait", "sleep":
        let seconds = args.count >= 2 ? Double(args[1]) ?? 1.0 : 1.0
        usleep(UInt32(seconds * 1_000_000))
        let ms = elapsedMs(start)
        print("Waited \(seconds)s (\(ms)ms)")

    case "drag":
        guard args.count >= 3 else {
            print("Usage: auto drag <from> <to> [duration]")
            print("       auto drag \"Element A\" \"Element B\" 1.0")
            print("       auto drag 100,200 300,400")
            return true
        }
        let duration = args.count >= 4 ? Double(args[3]) ?? 0.5 : 0.5
        let fromArg = args[1]
        let toArg = args[2]
        // Check if arguments are coordinates (format: "x,y")
        let fromParts = fromArg.split(separator: ",")
        let toParts = toArg.split(separator: ",")
        if fromParts.count == 2, let fx = Double(fromParts[0]), let fy = Double(fromParts[1]),
           toParts.count == 2, let tx = Double(toParts[0]), let ty = Double(toParts[1]) {
            try bridge.dragCoordinates(x1: fx, y1: fy, x2: tx, y2: ty, duration: duration)
            let ms = elapsedMs(start)
            print("Dragged (\(fx),\(fy)) → (\(tx),\(ty)) (\(ms)ms)")
        } else {
            try bridge.drag(from: fromArg, to: toArg, duration: duration)
            let ms = elapsedMs(start)
            print("Dragged '\(fromArg)' → '\(toArg)' (\(ms)ms)")
        }

    case "biometric", "faceid":
        guard args.count >= 2 else {
            print("Usage: auto biometric <enroll|unenroll|match|fail|status>")
            return true
        }
        let ms: Int
        switch args[1] {
        case "enroll":
            try bridge.biometricEnroll()
            ms = elapsedMs(start)
            print("Biometric enrolled (\(ms)ms)")
        case "unenroll":
            try bridge.biometricUnenroll()
            ms = elapsedMs(start)
            print("Biometric unenrolled (\(ms)ms)")
        case "match":
            try bridge.biometricMatch()
            ms = elapsedMs(start)
            print("Biometric match sent (\(ms)ms)")
        case "fail":
            try bridge.biometricFail()
            ms = elapsedMs(start)
            print("Biometric non-match sent (\(ms)ms)")
        case "status":
            let enrolled = try bridge.biometricIsEnrolled()
            ms = elapsedMs(start)
            print("Enrolled: \(enrolled ? "YES" : "NO") (\(ms)ms)")
        default:
            print("Unknown: \(args[1]). Use enroll/unenroll/match/fail/status")
        }

    case "permission":
        guard args.count >= 4 else {
            print("Usage: auto permission <grant|revoke|reset> <service> <bundleId>")
            print("       Services: camera, microphone, photos, contacts, calendars,")
            print("                 reminders, location, bluetooth, health, homekit,")
            print("                 notifications, all")
            return true
        }
        let action = args[1]
        let service = args[2]
        let bundleId = args[3]
        try bridge.setPermission(action: action, service: service, bundleId: bundleId)
        let ms = elapsedMs(start)
        print("Permission \(action) \(service) → \(bundleId) (\(ms)ms)")

    case "logs":
        let bundleId: String? = (args.count >= 2 && !args[1].hasPrefix("--")) ? args[1] : nil
        var lines = 50
        if let idx = args.firstIndex(of: "--lines"), idx + 1 < args.count {
            lines = Int(args[idx + 1]) ?? 50
        }
        let isSystem = args.contains("--system")
        let output = try bridge.getLogs(bundleId: isSystem ? nil : bundleId, lines: lines)
        print(output)

    case "rotate":
        guard args.count >= 2 else {
            print("Usage: auto rotate <left|right|portrait|landscape>")
            return true
        }
        try bridge.rotate(direction: args[1])
        let ms = elapsedMs(start)
        print("Rotated \(args[1]) (\(ms)ms)")

    // MARK: - Keyboard

    case "pressKey":
        guard args.count >= 2 else {
            print("Usage: auto pressKey <home|back|enter|delete|volumeUp|volumeDown|power|tab|escape>")
            return true
        }
        try runAction(.pressKey(key: args[1]), router: router,
                      fallback: { try bridge.pressKey(key: args[1]) })
        let ms = elapsedMs(start)
        print("Pressed key '\(args[1])' (\(ms)ms)")

    case "hideKeyboard":
        try runAction(.hideKeyboard, router: router, fallback: { try bridge.hideKeyboard() })
        let ms = elapsedMs(start)
        print("Keyboard dismissed (\(ms)ms)")

    case "eraseText":
        let count = args.count >= 2 ? Int(args[1]) ?? 1 : 1
        try bridge.eraseText(count: count)
        let ms = elapsedMs(start)
        print("Erased \(count) character(s) (\(ms)ms)")

    // MARK: - Text Extraction

    case "copyTextFrom":
        guard args.count >= 2 else {
            print("Usage: auto copyTextFrom <element>")
            return true
        }
        let text = try bridge.copyTextFrom(target: args[1])
        let ms = elapsedMs(start)
        print("\(text)")
        if isatty(1) != 0 {
            fputs("(\(ms)ms)\n", stderr)
        }

    // MARK: - App Data

    case "clearState":
        guard args.count >= 2 else {
            print("Usage: auto clearState <bundleId>")
            return true
        }
        try bridge.clearState(bundleId: args[1])
        let ms = elapsedMs(start)
        print("Cleared state for \(args[1]) (\(ms)ms)")

    case "uninstall":
        guard args.count >= 2 else {
            print("Usage: auto uninstall <bundleId>")
            return true
        }
        try bridge.uninstallApp(bundleId: args[1])
        let ms = elapsedMs(start)
        print("Uninstalled \(args[1]) (\(ms)ms)")

    case "keychain":
        // Subcommand-style: `keychain reset`. Leaves room for future
        // `keychain add-cert` / `add-root-cert` mirroring simctl, without
        // crowding the top-level command list today.
        guard args.count >= 2 else {
            print("Usage: auto keychain reset")
            return true
        }
        switch args[1] {
        case "reset":
            try bridge.resetKeychain()
            let ms = elapsedMs(start)
            print("Keychain reset (\(ms)ms)")
        default:
            print("Usage: auto keychain reset")
            print("Unknown subcommand: '\(args[1])'")
        }

    case "accounts":
        // Subcommand-style como `keychain` (issue #86). En Android opera
        // sobre el AccountManager del sistema (cuentas Google Sign-In que
        // sobreviven al uninstall); en iOS es no-op documentado — las
        // credenciales viven en el keychain y `keychain reset` ya las cubre.
        guard args.count >= 2 else {
            print("Usage: auto accounts <list|clear> [type]")
            return true
        }
        switch args[1] {
        case "list":
            var accounts = try bridge.listAccounts()
            if args.count >= 3 {
                accounts = accounts.filter { $0.type == args[2] }
            }
            let ms = elapsedMs(start)
            for account in accounts {
                print("\(account.type)  \(account.name)")
            }
            print("\(accounts.count) account(s) (\(ms)ms)")
        case "clear":
            // Default `com.google` — el caso que motivó el feature
            // (Google Sign-In sobrevive a uninstall + keychain reset).
            let type = args.count >= 3 ? args[2] : "com.google"
            try bridge.clearAccounts(type: type)
            let ms = elapsedMs(start)
            print("Accounts clear done for type '\(type)' (\(ms)ms)")
        default:
            print("Usage: auto accounts <list|clear> [type]")
            print("Unknown subcommand: '\(args[1])'")
        }

    // MARK: - Scroll Search
    // `scrollUntilVisible` is an alias of `scrollTo` (emitted by recorder).

    case "scrollTo", "scrollUntilVisible":
        guard args.count >= 2 else {
            print("Usage: auto \(args[0]) <element> [direction] [maxAttempts]")
            return true
        }
        let direction = args.count >= 3 ? args[2] : "down"
        let maxAttempts = args.count >= 4 ? Int(args[3]) ?? 20 : 20
        try runAction(
            .scrollTo(target: args[1], direction: direction, maxAttempts: maxAttempts),
            router: router,
            fallback: { try bridge.scrollTo(target: args[1], direction: direction, maxAttempts: maxAttempts) }
        )
        let ms = elapsedMs(start)
        print("Scrolled '\(args[1])' into view (\(ms)ms)")

    // MARK: - Screen Recording

    case "startRecording":
        try bridge.startRecording()
        let ms = elapsedMs(start)
        print("Recording started (\(ms)ms)")

    case "stopRecording":
        guard args.count >= 2 else {
            print("Usage: auto stopRecording <output.mp4>")
            return true
        }
        try bridge.stopRecording(outputPath: args[1])
        let ms = elapsedMs(start)
        print("Recording saved to \(args[1]) (\(ms)ms)")

    // MARK: - Device Environment

    case "setLocation":
        guard args.count >= 3 else {
            print("Usage: auto setLocation <latitude> <longitude>")
            return true
        }
        guard let lat = Double(args[1]), let lon = Double(args[2]) else {
            print("Error: latitude and longitude must be numbers")
            return true
        }
        try bridge.setLocation(latitude: lat, longitude: lon)
        let ms = elapsedMs(start)
        print("Location set to \(lat), \(lon) (\(ms)ms)")

    case "setAppearance":
        guard args.count >= 2 else {
            print("Usage: auto setAppearance <dark|light>")
            return true
        }
        try bridge.setAppearance(mode: args[1])
        let ms = elapsedMs(start)
        print("Appearance set to \(args[1]) (\(ms)ms)")

    case "lockDevice":
        try bridge.lockDevice()
        let ms = elapsedMs(start)
        print("Device locked (\(ms)ms)")

    case "unlockDevice":
        try bridge.unlockDevice()
        let ms = elapsedMs(start)
        print("Device unlocked (\(ms)ms)")

    // MARK: - File Transfer

    case "pushFile":
        guard args.count >= 3 else {
            print("Usage: auto pushFile <localPath> <remotePath>")
            return true
        }
        try bridge.pushFile(localPath: args[1], remotePath: args[2])
        let ms = elapsedMs(start)
        print("Pushed \(args[1]) → \(args[2]) (\(ms)ms)")

    case "pullFile":
        guard args.count >= 3 else {
            print("Usage: auto pullFile <remotePath> <localPath>")
            return true
        }
        try bridge.pullFile(remotePath: args[1], localPath: args[2])
        let ms = elapsedMs(start)
        print("Pulled \(args[1]) → \(args[2]) (\(ms)ms)")

    default:
        return false
    }

    return true
}

// MARK: - Router dispatch helpers (ARD-001)

/// Dispatch an action through the router when available; otherwise
/// execute the provided sync fallback against the legacy bridge.
/// This preserves the existing test-suite signature while giving migrated
/// commands the router's automatic escalation (ARD-001).
private func runAction(
    _ action: Action,
    router: ActionRouter?,
    fallback: () throws -> Void
) throws {
    guard let router else { try fallback(); return }
    do {
        _ = try runAsyncThrowing { try await router.execute(action) }
    } catch ActionRouterError.noBackendForAction {
        // Router doesn't know this action → fall back to bridge.
        try fallback()
    }
}

/// Like `runAction` but returns a value extracted from the `ActionResult`.
/// When the router returns a shape the extractor doesn't recognize, it falls
/// back to the sync closure — keeps behavior identical to pre-router code.
private func runActionReturning<T>(
    _ action: Action,
    router: ActionRouter?,
    fallback: () throws -> T,
    extract: (ActionResult) -> T?
) throws -> T {
    guard let router else { return try fallback() }
    do {
        let r = try runAsyncThrowing { try await router.execute(action) }
        if let v = extract(r) { return v }
        return try fallback()
    } catch ActionRouterError.noBackendForAction {
        return try fallback()
    }
}

// MARK: - Shared helpers

public func elapsedMs(_ start: CFAbsoluteTime) -> Int {
    Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
}

/// Emit a `[timing] …` line to stderr when `AUTO_DEBUG_TIMING=1` is set.
/// The message closure is only invoked when the flag is active, so
/// interpolation cost is skipped in normal runs.
public func debugTimingLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["AUTO_DEBUG_TIMING"] != nil else { return }
    FileHandle.standardError.write(Data("[timing] \(message())\n".utf8))
}

public func printElement(_ el: [String: Any]) {
    let role = el["role"] as? String ?? "?"
    let title = el["title"] as? String ?? ""
    let label = el["label"] as? String ?? ""
    let identifier = el["identifier"] as? String ?? ""
    let frame = el["frame"] as? [String: Any]

    var line = "  \(role)"
    if !title.isEmpty { line += "  \"\(title)\"" }
    if !label.isEmpty && label != title { line += "  label=\"\(label)\"" }
    if !identifier.isEmpty { line += "  id=\(identifier)" }
    if let f = frame {
        line += "  [\(f["x"] ?? 0),\(f["y"] ?? 0) \(f["width"] ?? 0)x\(f["height"] ?? 0)]"
    }
    print(line)
}

// MARK: - type[N] support

/// Recursively collects every text-input element from the tree, in document order.
/// Used by `type[N]` to resolve the Nth text input regardless of label/sibling noise.
/// iOS roles: AXTextField, AXSecureTextField. Android roles: anything ending in EditText.
private func collectTextInputs(_ elements: [[String: Any]], into result: inout [[String: Any]]) {
    for el in elements {
        if let role = el["role"] as? String {
            let isTextInput = role == "AXTextField"
                || role == "AXSecureTextField"
                || role == "EditText"
                || role.hasSuffix(".EditText")
                || role.hasSuffix("EditText")
            if isTextInput {
                result.append(el)
            }
        }
        if let children = el["children"] as? [[String: Any]] {
            collectTextInputs(children, into: &result)
        }
    }
}

// MARK: - Settle tap→type (#159)

/// Snapshot único del tree para el flujo tap→type: se usa tanto para
/// resolver el text input como para el fingerprint pre-tap del settle.
/// `costMs` mide lo que tardó `bridge.tree()` — es el auto-tuning del
/// settle: si el tree es caro, el poll no vale la pena.
struct PreTapTreeSnapshot {
    let tree: [[String: Any]]
    let fingerprint: ViewFingerprint
    let costMs: Int
}

func preTapTreeSnapshot(bridge: any DeviceBridge) throws -> PreTapTreeSnapshot {
    let t0 = CFAbsoluteTimeGetCurrent()
    let tree = try bridge.tree()
    let costMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
    return PreTapTreeSnapshot(tree: tree,
                              fingerprint: ViewFingerprint.capture(tree: tree),
                              costMs: costMs)
}

/// Espera adaptativa entre tap y type — sustituye el usleep(200ms) fijo (#159).
///
/// Señal de "listo": el fingerprint estructural del tree difiere del pre-tap
/// (la UI reaccionó — foco, teclado o transición). Contrato de tiempos:
///   - mínimo 100ms de gracia (el foco/teclado sigue en vuelo aunque el
///     tree ya haya cambiado),
///   - techo 200ms desde el tap = el valor fijo anterior, así el peor caso
///     (fingerprint estable, p.ej. teclado que no altera el top-level) NO
///     empeora y el mejor caso ahorra ~100ms por type.
///
/// Decisión documentada: `ViewFingerprint.capture(root:)` (AX) es iOS-only;
/// este dispatcher es compartido, así que el fingerprint se calcula sobre el
/// snapshot de `bridge.tree()` (`ViewFingerprint.capture(tree:)` en AutoCore).
/// Si el tree() pre-tap costó >80ms (p.ej. XCUI runner sin observer), cada
/// poll costaría más de lo que ahorra: degradamos al sleep fijo de 200ms.
/// TODO(#157): converger con AutoWait/retryTapIfNoChange cuando aterrice en
/// main — hoy no existe ahí y este helper no depende de él a propósito.
func settleBeforeType(bridge: any DeviceBridge, snapshot: PreTapTreeSnapshot) {
    guard snapshot.costMs <= 80 else {
        usleep(200_000)
        return
    }
    let start = CFAbsoluteTimeGetCurrent()
    usleep(100_000) // gracia mínima
    while (CFAbsoluteTimeGetCurrent() - start) < 0.2 {
        if let tree = try? bridge.tree(),
           ViewFingerprint.capture(tree: tree) != snapshot.fingerprint {
            debugTimingLog("settleBeforeType: UI changed at \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms — typing early")
            return
        }
        usleep(50_000)
    }
}

/// Finds the Nth text input in `tree` (1-indexed) and taps the center of its frame.
/// Throws BridgeError if N is out of range or the element has no usable frame.
func tapNthTextInput(tree: [[String: Any]], bridge: any DeviceBridge, index: Int) throws {
    var inputs: [[String: Any]] = []
    collectTextInputs(tree, into: &inputs)

    guard !inputs.isEmpty else {
        throw BridgeError.elementNotFound("type[\(index)]: no text inputs found in current tree")
    }
    guard index >= 1 && index <= inputs.count else {
        throw BridgeError.elementNotFound("type[\(index)]: only \(inputs.count) text input(s) in current tree")
    }

    try tapElementCenter(inputs[index - 1], hint: "text input [\(index)]", bridge: bridge)
}

/// Finds the first text input whose label/value/title/identifier matches `label`
/// and taps the center of its frame. Returns true on success, false if no text
/// input matches (caller can fallback to a plain `bridge.tap`).
///
/// This is the smart resolver used by `auto type <target> <text>` (3 args). It
/// prefers a text input over a sibling AXStaticText with the same label, which
/// is what allows `type "Email o DNI" "user@example.com"` to work even when the
/// form has both a label-only StaticText and a TextField with the same string.
func tapTextInputByLabel(tree: [[String: Any]], bridge: any DeviceBridge, label: String) throws -> Bool {
    var inputs: [[String: Any]] = []
    collectTextInputs(tree, into: &inputs)
    if inputs.isEmpty { return false }

    let needle = label.lowercased()
    for field in inputs {
        let candidates: [String] = [
            (field["label"] as? String) ?? "",
            (field["title"] as? String) ?? "",
            (field["value"] as? String) ?? "",
            (field["identifier"] as? String) ?? "",
            (field["placeholder"] as? String) ?? "",
        ]
        for candidate in candidates where !candidate.isEmpty {
            if candidate.lowercased() == needle || candidate.lowercased().contains(needle) {
                try tapElementCenter(field, hint: "text input '\(label)'", bridge: bridge)
                return true
            }
        }
    }
    return false
}

/// Tap the center of `element`'s frame via `bridge`. Throws if no frame.
private func tapElementCenter(_ element: [String: Any], hint: String, bridge: any DeviceBridge) throws {
    guard let frame = element["frame"] as? [String: Any],
          let fx = frame["x"] as? Int,
          let fy = frame["y"] as? Int,
          let fw = frame["width"] as? Int,
          let fh = frame["height"] as? Int else {
        throw BridgeError.noFrame(hint)
    }
    let cx = Double(fx + fw / 2)
    let cy = Double(fy + fh / 2)
    try bridge.tapAtCoordinate(x: cx, y: cy)
}
