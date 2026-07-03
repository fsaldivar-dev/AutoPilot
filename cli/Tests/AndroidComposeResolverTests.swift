import XCTest
@testable import AutoCore

/// #151 — el resolver de clickable-parent no debe cruzar ventanas: con el
/// teclado visible, `tap "Museo del Louvre"` elegía un FrameLayout clickable
/// invisible del IME (Gboard) porque el hit-test usaba la ESQUINA
/// superior-izquierda del texto y buscaba en el tree completo sin filtrar
/// por ventana. Trees mock en el formato de TreeSerializer.kt post-#130:
/// ventanas no-activas como nodos sintéticos `role: "Window"` top-level.
final class AndroidComposeResolverTests: XCTestCase {

    // MARK: - Fixtures (formato TreeSerializer.kt)

    private func frame(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [String: Any] {
        ["x": x, "y": y, "width": w, "height": h]
    }

    /// TextView "Museo del Louvre" — esquina en (21, 1290), centro en (171, 1310).
    private var louvreText: [String: Any] {
        [
            "role": "TextView",
            "title": "Museo del Louvre",
            "label": "Museo del Louvre",
            "clickable": false,
            "frame": frame(21, 1290, 300, 40),
        ]
    }

    /// Card clickable de la app que contiene el texto (el padre correcto).
    private var appCardFrame: [String: Any] { frame(0, 1270, 1080, 200) }

    private var appRoot: [String: Any] {
        [
            "role": "FrameLayout",
            "package": "com.explorea.app",
            "clickable": false,
            "frame": frame(0, 0, 1080, 2400),
            "children": [
                [
                    "role": "FrameLayout",
                    "clickable": true,
                    "frame": appCardFrame,
                    "children": [louvreText],
                ] as [String: Any]
            ],
        ]
    }

    /// Ventana IME sintética (Gboard) con un FrameLayout clickable invisible.
    private func imeWindow(overlayFrame: [String: Any]) -> [String: Any] {
        [
            "role": "Window",
            "title": "IME",
            "label": "window: ime",
            "clickable": false,
            "package": "com.google.android.inputmethod.latin",
            "frame": frame(0, 1200, 1080, 1200),
            "children": [
                [
                    "role": "FrameLayout",
                    "package": "com.google.android.inputmethod.latin",
                    "clickable": false,
                    "frame": frame(0, 1200, 1080, 1200),
                    "children": [
                        [
                            "role": "FrameLayout",
                            "clickable": true,
                            "frame": overlayFrame,
                        ] as [String: Any]
                    ],
                ] as [String: Any]
            ],
        ]
    }

    private func assertFrames(_ result: [String: Any]?, _ expected: [String: Any],
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let result else {
            XCTFail("resolver devolvió nil, se esperaba \(expected)", file: file, line: line)
            return
        }
        XCTAssertTrue((result as NSDictionary).isEqual(to: expected),
                      "frame \(result) != esperado \(expected)", file: file, line: line)
    }

    // MARK: - Bug repro: target de la app + clickable IME

    /// El caso exacto del issue: el FrameLayout del IME (x=21–169) contiene la
    /// ESQUINA del texto pero es de otra ventana → NO elegirlo. Debe resolver
    /// el card clickable de la app que contiene el CENTRO.
    func testIMEClickableContainingCornerIsNotChosenForAppTarget() {
        let tree = [appRoot, imeWindow(overlayFrame: frame(21, 1280, 148, 60))]
        let result = AndroidComposeResolver.findClickableFrame(for: louvreText, in: tree)
        assertFrames(result, appCardFrame)
    }

    /// Filtro por ventana puro: aunque el clickable del IME contenga también
    /// el CENTRO del target y sea más pequeño que el card de la app, un target
    /// de la app jamás resuelve a un clickable del IME.
    func testIMEClickableContainingCenterIsNotChosenForAppTarget() {
        // Contiene el centro (171, 1310) y su área (1080x100) < card (1080x200)
        let tree = [appRoot, imeWindow(overlayFrame: frame(0, 1270, 1080, 100))]
        let result = AndroidComposeResolver.findClickableFrame(for: louvreText, in: tree)
        assertFrames(result, appCardFrame)
    }

    // MARK: - Target dentro del IME (tecla)

    /// Un target DENTRO de la ventana IME (una tecla) sí resuelve a un
    /// clickable del IME — y solo del IME: los clickables de la app se
    /// ignoran aunque contengan el punto.
    func testTargetInsideIMEResolvesToIMEClickable() {
        let keyText: [String: Any] = [
            "role": "TextView",
            "title": "q",
            "label": "q",
            "clickable": false,
            "frame": frame(30, 1420, 60, 80),
        ]
        let keyContainerFrame = frame(20, 1410, 80, 100)
        let ime: [String: Any] = [
            "role": "Window",
            "title": "IME",
            "label": "window: ime",
            "clickable": false,
            "package": "com.google.android.inputmethod.latin",
            "frame": frame(0, 1200, 1080, 1200),
            "children": [
                [
                    "role": "FrameLayout",
                    "clickable": true,
                    "frame": keyContainerFrame,
                    "children": [keyText],
                ] as [String: Any]
            ],
        ]
        // Clickable de la app que también contiene el centro de la tecla y es
        // más pequeño que el contenedor de la tecla — debe ignorarse.
        let appDistractor: [String: Any] = [
            "role": "FrameLayout",
            "package": "com.explorea.app",
            "clickable": false,
            "frame": frame(0, 0, 1080, 2400),
            "children": [
                [
                    "role": "FrameLayout",
                    "clickable": true,
                    "frame": frame(55, 1455, 20, 20),
                ] as [String: Any]
            ],
        ]
        let result = AndroidComposeResolver.findClickableFrame(for: keyText, in: [appDistractor, ime])
        assertFrames(result, keyContainerFrame)
    }

    // MARK: - Sin IME: sin regresión

    /// Tree sin nodos Window (teclado cerrado / agente pre-#130): el TextView
    /// dentro de un Button resuelve al Button, como siempre (#59).
    func testNoIMEWindowStillResolvesButtonParent() {
        let text: [String: Any] = [
            "role": "TextView",
            "title": "Guardar",
            "clickable": false,
            "frame": frame(120, 510, 100, 30),
        ]
        let buttonFrame = frame(100, 500, 200, 50)
        let tree: [[String: Any]] = [
            [
                "role": "FrameLayout",
                "clickable": false,
                "frame": frame(0, 0, 1080, 2400),
                "children": [
                    [
                        "role": "Button",
                        "frame": buttonFrame,
                        "children": [text],
                    ] as [String: Any]
                ],
            ]
        ]
        let result = AndroidComposeResolver.findClickableFrame(for: text, in: tree)
        assertFrames(result, buttonFrame)
    }

    /// Hit-test por CENTRO también dentro de la misma ventana: un clickable
    /// que solo contiene la esquina del target (no el centro) ya no captura
    /// la resolución.
    func testClickableContainingOnlyCornerIsNotChosen() {
        let text: [String: Any] = [
            "role": "TextView",
            "title": "Etiqueta",
            "clickable": false,
            "frame": frame(100, 100, 200, 40),
        ]
        let cornerOnly: [String: Any] = [
            "role": "FrameLayout",
            "clickable": true,
            // Contiene (100,100) pero no el centro (200,120)
            "frame": frame(90, 90, 60, 20),
        ]
        let tree: [[String: Any]] = [
            [
                "role": "FrameLayout",
                "clickable": false,
                "frame": frame(0, 0, 1080, 2400),
                "children": [cornerOnly, text],
            ]
        ]
        let result = AndroidComposeResolver.findClickableFrame(for: text, in: tree)
        XCTAssertNil(result, "un clickable que no contiene el centro no debe ser candidato")
    }
}
