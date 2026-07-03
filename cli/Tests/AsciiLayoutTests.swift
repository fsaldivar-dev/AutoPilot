import XCTest
import CoreGraphics
@testable import AutoCore

/// Tests del renderer ASCII (#107). Tree sintético, output determinista.
final class AsciiLayoutTests: XCTestCase {

    // MARK: - Fixtures

    /// Pantalla iOS sintética 400x800: navbar, texto, input y dos botones.
    /// Incluye un Window y un ScrollArea gigantes que el renderer debe ignorar.
    private func iosTree() -> [[String: Any]] {
        [[
            "role": "AXWindow",
            "frame": ["x": 0, "y": 0, "width": 400, "height": 800],
            "children": [
                [
                    "role": "AXNavigationBar",
                    "title": "Ajustes",
                    "frame": ["x": 0, "y": 0, "width": 400, "height": 120]
                ],
                [
                    "role": "AXScrollArea",
                    "frame": ["x": 0, "y": 120, "width": 400, "height": 680],
                    "children": [
                        [
                            "role": "AXStaticText",
                            "label": "Perfil",
                            "frame": ["x": 20, "y": 160, "width": 200, "height": 120]
                        ],
                        [
                            "role": "AXImage",
                            "frame": ["x": 300, "y": 160, "width": 80, "height": 120]
                        ],
                        [
                            "role": "AXTextField",
                            "label": "Email",
                            "frame": ["x": 20, "y": 320, "width": 360, "height": 120]
                        ],
                        [
                            "role": "AXButton",
                            "title": "Guardar",
                            "frame": ["x": 20, "y": 600, "width": 170, "height": 140]
                        ],
                        [
                            "role": "AXButton",
                            "title": "Cancelar",
                            "frame": ["x": 210, "y": 600, "width": 170, "height": 140]
                        ]
                    ]
                ]
            ]
        ]]
    }

    private let viewport = CGRect(x: 0, y: 0, width: 400, height: 800)

    private func smallGrid() -> AsciiLayout.Options {
        var opts = AsciiLayout.Options()
        opts.width = 40
        opts.height = 20
        return opts
    }

    // MARK: - Golden test (output exacto)

    func testRenderGolden() {
        let output = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: smallGrid())
        let expected = """
        +----------------------------------------+
        |+--------------------------------------+|
        ||[N] Ajustes                           ||
        |+--------------------------------------+|
        |                                        |
        |  +------------------+        +------+  |
        |  |[T] Perfil        |        |[G]   |  |
        |  +------------------+        +------+  |
        |                                        |
        |  +----------------------------------+  |
        |  |[I] Email                         |  |
        |  +----------------------------------+  |
        |                                        |
        |                                        |
        |                                        |
        |                                        |
        |  +---------------+  +---------------+  |
        |  |[B] Guardar    |  |[B] Cancelar   |  |
        |  |               |  |               |  |
        |  +---------------+  +---------------+  |
        |                                        |
        +----------------------------------------+
        [B] boton  [T] texto  [I] input  [N] navbar  [G] imagen
        6 elemento(s) · viewport 400x800
        """
        XCTAssertEqual(output, expected)
    }

    // MARK: - Estructura del output

    func testGridDimensions() {
        let output = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: smallGrid())
        let lines = output.components(separatedBy: "\n")
        // 20 filas + 2 bordes + leyenda + resumen
        XCTAssertEqual(lines.count, 24)
        for line in lines.prefix(22) {
            XCTAssertEqual(line.count, 42, "cada fila del grid mide width+2: \(line)")
        }
    }

    func testDeterministic() {
        let a = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: smallGrid())
        let b = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: smallGrid())
        XCTAssertEqual(a, b)
    }

    // MARK: - Filtrado

    func testSkipsGiantContainers() {
        let output = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: smallGrid())
        // Window y ScrollArea cubren >90% del viewport y son contenedores → fuera
        XCTAssertFalse(output.contains("Window"))
        XCTAssertFalse(output.contains("Scroll"))
    }

    func testTypeFilterButtons() {
        var opts = smallGrid()
        opts.typeFilter = "buttons"
        let output = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: opts)
        XCTAssertTrue(output.contains("[B] Guardar"))
        XCTAssertTrue(output.contains("[B] Cancelar"))
        XCTAssertFalse(output.contains("[I] Email"))
        XCTAssertFalse(output.contains("[N] Ajustes"))
        XCTAssertTrue(output.contains("2 elemento(s)"))
    }

    func testCompactSkipsUnlabeled() {
        var opts = smallGrid()
        opts.compact = true
        let output = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: opts)
        // La AXImage sin label desaparece; el resto queda
        XCTAssertFalse(output.contains("[G]"))
        XCTAssertTrue(output.contains("[B] Guardar"))
        XCTAssertTrue(output.contains("5 elemento(s)"))
    }

    func testRegionZoom() {
        var opts = smallGrid()
        opts.region = "Guardar"
        let output = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: opts)
        // El viewport pasa a ser el frame del botón (170x140)
        XCTAssertTrue(output.contains("viewport 170x140"))
        // Cancelar queda fuera del nuevo viewport
        XCTAssertFalse(output.contains("Cancelar"))
    }

    func testRegionNotFound() {
        var opts = smallGrid()
        opts.region = "NoExiste"
        let output = AsciiLayout.render(tree: iosTree(), viewport: viewport, options: opts)
        XCTAssertTrue(output.contains("region 'NoExiste' no encontrada"))
    }

    func testEmptyTree() {
        let output = AsciiLayout.render(tree: [], viewport: viewport, options: smallGrid())
        XCTAssertTrue(output.contains("sin elementos"))
    }

    // MARK: - Cross-platform (roles Android)

    func testAndroidRoles() {
        let tree: [[String: Any]] = [[
            "role": "FrameLayout",
            "frame": ["x": 0, "y": 0, "width": 1080, "height": 2340],
            "children": [
                [
                    "role": "TextView",
                    "label": "Bienvenido",
                    "frame": ["x": 100, "y": 200, "width": 500, "height": 120]
                ],
                [
                    "role": "EditText",
                    "label": "Usuario",
                    "frame": ["x": 100, "y": 500, "width": 880, "height": 150]
                ],
                [
                    "role": "Button",
                    "label": "Entrar",
                    "frame": ["x": 100, "y": 800, "width": 880, "height": 160]
                ],
                // Compose: botón de ícono = View clickable + contentDescription
                [
                    "role": "View",
                    "label": "Abrir menu",
                    "clickable": true,
                    "frame": ["x": 700, "y": 100, "width": 150, "height": 100]
                ],
                // View genérico sin label ni clickable → no se dibuja
                [
                    "role": "View",
                    "frame": ["x": 0, "y": 2000, "width": 1080, "height": 300]
                ]
            ]
        ]]
        let output = AsciiLayout.render(
            tree: tree,
            viewport: CGRect(x: 0, y: 0, width: 1080, height: 2340),
            options: smallGrid()
        )
        XCTAssertTrue(output.contains("[T] Bienvenido"))
        XCTAssertTrue(output.contains("[I] Usuario"))
        XCTAssertTrue(output.contains("[B] Entrar"))
        XCTAssertTrue(output.contains("[B] Abrir menu"))
        XCTAssertTrue(output.contains("4 elemento(s)"))
    }

    // MARK: - Normalización de roles

    func testCategoryNormalization() {
        XCTAssertEqual(AsciiLayout.category(role: "AXButton", clickable: false, labeled: true), .button)
        XCTAssertEqual(AsciiLayout.category(role: "Button", clickable: false, labeled: true), .button)
        XCTAssertEqual(AsciiLayout.category(role: "android.widget.EditText", clickable: false, labeled: false), .input)
        XCTAssertEqual(AsciiLayout.category(role: "AXSecureTextField", clickable: false, labeled: true), .input)
        XCTAssertEqual(AsciiLayout.category(role: "NavigationBar", clickable: false, labeled: true), .navbar)
        XCTAssertEqual(AsciiLayout.category(role: "Toolbar", clickable: false, labeled: false), .navbar)
        XCTAssertEqual(AsciiLayout.category(role: "View", clickable: true, labeled: true), .button)
        XCTAssertNil(AsciiLayout.category(role: "View", clickable: false, labeled: false))
        XCTAssertNil(AsciiLayout.category(role: "AXScrollArea", clickable: false, labeled: false))
    }

    // MARK: - Etiquetas truncadas

    func testLabelTruncation() {
        let tree: [[String: Any]] = [[
            "role": "AXButton",
            "title": "Este titulo es larguisimo y no cabe en la caja de ninguna manera",
            "frame": ["x": 0, "y": 0, "width": 100, "height": 100]
        ]]
        let output = AsciiLayout.render(
            tree: tree,
            viewport: CGRect(x: 0, y: 0, width: 400, height: 800),
            options: smallGrid()
        )
        XCTAssertTrue(output.contains(".."), "etiqueta larga se trunca con '..'")
        let lines = output.components(separatedBy: "\n")
        for line in lines.dropLast(2) {
            XCTAssertEqual(line.count, 42)
        }
    }
}
