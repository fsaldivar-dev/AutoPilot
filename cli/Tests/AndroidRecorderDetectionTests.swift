import XCTest
@testable import AutoCore

/// Tests de la lógica pura de #54 (tecleo en teclado virtual) y #53
/// (diálogos de permisos del sistema) con trees mock — sin emulador.
/// El formato del tree replica lo que TreeSerializer.kt emite post-#130:
/// root de la ventana activa primero, luego nodos sintéticos "Window"
/// (title = "IME"/"System"/"Application") por cada ventana no-activa.
final class AndroidRecorderDetectionTests: XCTestCase {

    // MARK: - Trees mock

    /// Ventana IME estilo GBoard: frame en el tercio inferior de 1080x2400.
    private func imeWindow(withKeys: Bool = false) -> [String: Any] {
        var children: [[String: Any]] = [[
            "role": "KeyboardView",
            "title": "", "label": "", "identifier": "",
            "focused": false,
            "package": "com.google.android.inputmethod.latin",
            "frame": ["x": 0, "y": 1560, "width": 1080, "height": 840],
            "children": [[String: Any]](),
        ]]
        if withKeys {
            children = [[
                "role": "KeyboardView",
                "title": "", "label": "", "identifier": "",
                "focused": false,
                "package": "com.google.android.inputmethod.latin",
                "frame": ["x": 0, "y": 1560, "width": 1080, "height": 840],
                "children": [
                    ["role": "Key", "title": "", "label": "a", "identifier": "",
                     "frame": ["x": 0, "y": 1700, "width": 100, "height": 140],
                     "children": [[String: Any]]()],
                    ["role": "Key", "title": "", "label": "Enter", "identifier": "",
                     "frame": ["x": 950, "y": 2200, "width": 130, "height": 140],
                     "children": [[String: Any]]()],
                ],
            ]]
        }
        return [
            "role": "Window",
            "title": "IME",
            "label": "window: ime",
            "identifier": "",
            "focused": false,
            "package": "com.google.android.inputmethod.latin",
            "frame": ["x": 0, "y": 1560, "width": 1080, "height": 840],
            "children": children,
        ]
    }

    private func appRoot(fieldValue: String, fieldFocused: Bool = true) -> [String: Any] {
        [
            "role": "FrameLayout",
            "title": "", "label": "", "identifier": "",
            "focused": false,
            "package": "com.example.app",
            "frame": ["x": 0, "y": 0, "width": 1080, "height": 2400],
            "children": [
                ["role": "EditText",
                 "title": fieldValue, "value": fieldValue,
                 "label": "", "identifier": "com.example.app:id/username",
                 "focused": fieldFocused,
                 "package": "com.example.app",
                 "frame": ["x": 100, "y": 800, "width": 880, "height": 120],
                 "children": [[String: Any]]()],
                ["role": "Button",
                 "title": "Login", "value": "Login",
                 "label": "", "identifier": "com.example.app:id/login",
                 "focused": false,
                 "package": "com.example.app",
                 "frame": ["x": 100, "y": 1000, "width": 880, "height": 120],
                 "children": [[String: Any]]()],
            ],
        ]
    }

    private func treeWithKeyboard(fieldValue: String, keys: Bool = false) -> [[String: Any]] {
        [appRoot(fieldValue: fieldValue), imeWindow(withKeys: keys)]
    }

    // MARK: - #54: clasificación IME-window

    func testImeFrame_present_returnsKeyboardFrame() {
        let frame = AndroidRecorderDetection.imeFrame(in: treeWithKeyboard(fieldValue: ""))
        XCTAssertEqual(frame, CGRect(x: 0, y: 1560, width: 1080, height: 840))
    }

    func testImeFrame_absent_returnsNil() {
        XCTAssertNil(AndroidRecorderDetection.imeFrame(in: [appRoot(fieldValue: "")]))
    }

    func testIsPointInsideIME_keyboardArea_true() {
        let tree = treeWithKeyboard(fieldValue: "")
        XCTAssertTrue(AndroidRecorderDetection.isPointInsideIME(x: 540, y: 1900, tree: tree))
    }

    func testIsPointInsideIME_appArea_false() {
        let tree = treeWithKeyboard(fieldValue: "")
        XCTAssertFalse(AndroidRecorderDetection.isPointInsideIME(x: 540, y: 860, tree: tree))
    }

    func testIsPointInsideIME_noKeyboard_false() {
        XCTAssertFalse(AndroidRecorderDetection.isPointInsideIME(x: 540, y: 1900, tree: [appRoot(fieldValue: "")]))
    }

    /// Otro tipo de ventana ("System") no debe contar como teclado.
    func testIsPointInsideIME_systemWindow_false() {
        var window = imeWindow()
        window["title"] = "System"
        window["label"] = "window: system"
        XCTAssertFalse(AndroidRecorderDetection.isPointInsideIME(
            x: 540, y: 1900, tree: [appRoot(fieldValue: ""), window]
        ))
    }

    // MARK: - #54: value del campo enfocado

    func testFocusedEditableValue_focusedEditText_returnsValue() {
        let tree = treeWithKeyboard(fieldValue: "hola")
        XCTAssertEqual(AndroidRecorderDetection.focusedEditableValue(in: tree), "hola")
    }

    func testFocusedEditableValue_noFocus_returnsNil() {
        let tree = [appRoot(fieldValue: "hola", fieldFocused: false)]
        XCTAssertNil(AndroidRecorderDetection.focusedEditableValue(in: tree))
    }

    /// Un nodo enfocado DENTRO del IME (campo interno del teclado) no debe
    /// contar como "el campo donde el usuario escribe".
    func testFocusedEditableValue_ignoresFieldsInsideIME() {
        var ime = imeWindow()
        ime["children"] = [[
            "role": "EditText", "title": "search-in-keyboard",
            "value": "search-in-keyboard", "label": "", "identifier": "",
            "focused": true,
            "package": "com.google.android.inputmethod.latin",
            "frame": ["x": 0, "y": 1560, "width": 1080, "height": 100],
            "children": [[String: Any]](),
        ]]
        let tree = [appRoot(fieldValue: "real", fieldFocused: true), ime]
        XCTAssertEqual(AndroidRecorderDetection.focusedEditableValue(in: tree), "real")
    }

    func testFocusedEditableValue_focusedButton_notEditable_returnsNil() {
        var root = appRoot(fieldValue: "x", fieldFocused: false)
        var children = root["children"] as! [[String: Any]]
        children[1]["focused"] = true // Button enfocado
        root["children"] = children
        XCTAssertNil(AndroidRecorderDetection.focusedEditableValue(in: [root]))
    }

    func testIsEditableRole_variants() {
        XCTAssertTrue(AndroidRecorderDetection.isEditableRole("edittext"))
        XCTAssertTrue(AndroidRecorderDetection.isEditableRole("textinputedittext"))
        XCTAssertTrue(AndroidRecorderDetection.isEditableRole("autocompletetextview"))
        XCTAssertFalse(AndroidRecorderDetection.isEditableRole("button"))
        XCTAssertFalse(AndroidRecorderDetection.isEditableRole("textview"))
    }

    // MARK: - #54: diff de values → comandos

    func testTypingCommands_emptyToText_emitsType() {
        XCTAssertEqual(
            AndroidRecorderDetection.typingCommands(before: "", after: "hello"),
            ["type \"hello\""]
        )
    }

    func testTypingCommands_nilBefore_emitsFullType() {
        XCTAssertEqual(
            AndroidRecorderDetection.typingCommands(before: nil, after: "hello"),
            ["type \"hello\""]
        )
    }

    func testTypingCommands_appendSuffix_emitsOnlySuffix() {
        XCTAssertEqual(
            AndroidRecorderDetection.typingCommands(before: "user", after: "username"),
            ["type \"name\""]
        )
    }

    func testTypingCommands_deletion_emitsEraseText() {
        XCTAssertEqual(
            AndroidRecorderDetection.typingCommands(before: "username", after: "user"),
            ["eraseText 4"]
        )
    }

    /// Autocorrect / edición al medio: el estado final manda.
    func testTypingCommands_divergent_erasesAndRetypes() {
        XCTAssertEqual(
            AndroidRecorderDetection.typingCommands(before: "helo", after: "hello"),
            ["eraseText 4", "type \"hello\""]
        )
    }

    func testTypingCommands_noChange_emitsNothing() {
        XCTAssertEqual(AndroidRecorderDetection.typingCommands(before: "same", after: "same"), [])
        XCTAssertEqual(AndroidRecorderDetection.typingCommands(before: nil, after: nil), [])
        XCTAssertEqual(AndroidRecorderDetection.typingCommands(before: "", after: ""), [])
    }

    func testTypingCommands_clearedField_emitsEraseOnly() {
        XCTAssertEqual(
            AndroidRecorderDetection.typingCommands(before: "abc", after: ""),
            ["eraseText 3"]
        )
    }

    func testTypingCommands_passwordMasked_warnsInComment() {
        let commands = AndroidRecorderDetection.typingCommands(before: "", after: "••••••")
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands[0].hasPrefix("# campo password"))
        XCTAssertEqual(commands[1], "type \"••••••\"")
    }

    func testTypingCommands_textWithDoubleQuotes_usesSingleQuotes() {
        XCTAssertEqual(
            AndroidRecorderDetection.typingCommands(before: "", after: "say \"hi\""),
            ["type 'say \"hi\"'"]
        )
    }

    func testIsMaskedValue() {
        XCTAssertTrue(AndroidRecorderDetection.isMaskedValue("••••"))
        XCTAssertTrue(AndroidRecorderDetection.isMaskedValue("****"))
        XCTAssertFalse(AndroidRecorderDetection.isMaskedValue("hola"))
        XCTAssertFalse(AndroidRecorderDetection.isMaskedValue(""))
    }

    // MARK: - #54: tecla Enter

    func testIsEnterKeyTap_enterKeyExposed_true() {
        let tree = treeWithKeyboard(fieldValue: "", keys: true)
        XCTAssertTrue(AndroidRecorderDetection.isEnterKeyTap(x: 1000, y: 2260, tree: tree))
    }

    func testIsEnterKeyTap_letterKey_false() {
        let tree = treeWithKeyboard(fieldValue: "", keys: true)
        XCTAssertFalse(AndroidRecorderDetection.isEnterKeyTap(x: 50, y: 1760, tree: tree))
    }

    /// GBoard real no expone teclas al tree → no hay label → false (fail-safe).
    func testIsEnterKeyTap_noKeysExposed_false() {
        let tree = treeWithKeyboard(fieldValue: "", keys: false)
        XCTAssertFalse(AndroidRecorderDetection.isEnterKeyTap(x: 1000, y: 2260, tree: tree))
    }
}
