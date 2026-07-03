import XCTest
import CoreGraphics
@testable import AutoCore

/// #166: el path `type "target" "texto"` resuelve el text input por label y
/// tapea su centro (que el observer traduce a becomeFirstResponder). Un
/// TextField SwiftUI plano NO expone accessibilityLabel = placeholder, así que
/// el observer ahora publica `placeholder` en el nodo y `tapTextInputByLabel`
/// debe poder resolver el campo por ese placeholder. Sin esto, el tap fallaba
/// silenciosamente y el type escribía en el vacío (o mentía "Typed text").
final class TypeFocusTests: XCTestCase {

    /// Un AXTextField anónimo (sin label) pero con `placeholder` que coincide
    /// con el target debe resolverse y taparse por coordenada de su centro.
    func testTapTextInputResolvesByPlaceholder() throws {
        let bridge = MockBridge()
        let tree: [[String: Any]] = [
            [
                "role": "AXTextField",
                "placeholder": "Titulo de tu experiencia",
                "frame": ["x": 32, "y": 316, "width": 338, "height": 22]
            ]
        ]

        let matched = try tapTextInputByLabel(tree: tree, bridge: bridge,
                                              label: "Titulo de tu experiencia")

        XCTAssertTrue(matched, "debe resolver el campo por placeholder")
        XCTAssertEqual(bridge.callCount("tapAtCoordinate"), 1)
        let last = try XCTUnwrap(bridge.lastCall())
        XCTAssertEqual(last.method, "tapAtCoordinate")
        // Centro del frame: x = 32 + 338/2 = 201, y = 316 + 22/2 = 327
        XCTAssertEqual(last.args, ["201.0", "327.0"])
    }

    /// Cuando el campo SÍ tiene label (p.ej. UISearchBar expone el placeholder
    /// como accessibilityLabel) el match por label sigue funcionando.
    func testTapTextInputResolvesByLabel() throws {
        let bridge = MockBridge()
        let tree: [[String: Any]] = [
            [
                "role": "AXTextField",
                "label": "Buscar destinos, experiencias...",
                "frame": ["x": 8, "y": 70, "width": 323, "height": 44]
            ]
        ]

        let matched = try tapTextInputByLabel(tree: tree, bridge: bridge,
                                              label: "Buscar destinos, experiencias...")

        XCTAssertTrue(matched)
        XCTAssertEqual(bridge.callCount("tapAtCoordinate"), 1)
    }

    /// Si ningún text input coincide con el label, no se tapea nada y retorna
    /// false — el dispatcher entonces cae al tap genérico. No debe elegir un
    /// campo cualquiera "de relleno".
    func testTapTextInputReturnsFalseWhenNoMatch() throws {
        let bridge = MockBridge()
        let tree: [[String: Any]] = [
            [
                "role": "AXTextField",
                "placeholder": "Otro campo",
                "frame": ["x": 0, "y": 0, "width": 100, "height": 20]
            ]
        ]

        let matched = try tapTextInputByLabel(tree: tree, bridge: bridge,
                                              label: "Titulo de tu experiencia")

        XCTAssertFalse(matched)
        XCTAssertEqual(bridge.callCount("tapAtCoordinate"), 0)
    }

    /// Un AXStaticText con el mismo texto que un AXTextField NO debe ganar: el
    /// filtro por rol asegura que se tapea el input, no la etiqueta visible.
    func testTapTextInputIgnoresStaticTextWithSameLabel() throws {
        let bridge = MockBridge()
        let tree: [[String: Any]] = [
            [
                "role": "AXStaticText",
                "label": "Titulo de tu experiencia",
                "frame": ["x": 0, "y": 100, "width": 200, "height": 20]
            ],
            [
                "role": "AXTextField",
                "placeholder": "Titulo de tu experiencia",
                "frame": ["x": 32, "y": 316, "width": 338, "height": 22]
            ]
        ]

        let matched = try tapTextInputByLabel(tree: tree, bridge: bridge,
                                              label: "Titulo de tu experiencia")

        XCTAssertTrue(matched)
        let last = try XCTUnwrap(bridge.lastCall())
        // Debe tapear el AXTextField (centro 201,327), no el AXStaticText.
        XCTAssertEqual(last.args, ["201.0", "327.0"])
    }
}
