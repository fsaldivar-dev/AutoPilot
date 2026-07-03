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

    // MARK: - #53: diálogo de permisos

    /// Diálogo de permisos como ventana activa (root directo del tree),
    /// con la app solicitante como ventana secundaria "Application".
    private func permissionTree(
        message: String = "Allow TestApp to take pictures and record video?",
        allowLabel: String = "While using the app",
        controllerPackage: String = "com.google.android.permissioncontroller"
    ) -> [[String: Any]] {
        let dialog: [String: Any] = [
            "role": "FrameLayout",
            "title": "", "label": "",
            "identifier": "",
            "focused": true,
            "package": controllerPackage,
            "frame": ["x": 0, "y": 700, "width": 1080, "height": 1000],
            "children": [
                ["role": "TextView", "title": message, "value": message, "label": "",
                 "identifier": "\(controllerPackage):id/permission_message",
                 "package": controllerPackage,
                 "frame": ["x": 100, "y": 800, "width": 880, "height": 200],
                 "children": [[String: Any]]()],
                ["role": "Button", "title": allowLabel, "value": allowLabel, "label": "",
                 "identifier": "\(controllerPackage):id/permission_allow_foreground_only_button",
                 "package": controllerPackage,
                 "frame": ["x": 100, "y": 1100, "width": 880, "height": 120],
                 "children": [[String: Any]]()],
                ["role": "Button", "title": "Don't allow", "value": "Don't allow", "label": "",
                 "identifier": "\(controllerPackage):id/permission_deny_button",
                 "package": controllerPackage,
                 "frame": ["x": 100, "y": 1250, "width": 880, "height": 120],
                 "children": [[String: Any]]()],
            ],
        ]
        let appWindow: [String: Any] = [
            "role": "Window",
            "title": "Application",
            "label": "window: application",
            "identifier": "",
            "focused": false,
            "package": "com.example.app",
            "frame": ["x": 0, "y": 0, "width": 1080, "height": 2400],
            "children": [appRoot(fieldValue: "", fieldFocused: false)],
        ]
        return [dialog, appWindow]
    }

    func testDetectPermission_allowButton_affirmativeCameraService() {
        let dialog = AndroidRecorderDetection.detectPermissionDialog(
            x: 540, y: 1160, tree: permissionTree()
        )
        XCTAssertNotNil(dialog)
        XCTAssertEqual(dialog?.buttonLabel, "While using the app")
        XCTAssertEqual(dialog?.affirmative, true)
        XCTAssertEqual(dialog?.service, "camera")
        XCTAssertEqual(dialog?.appPackage, "com.example.app")
        XCTAssertEqual(dialog?.message, "Allow TestApp to take pictures and record video?")
    }

    func testDetectPermission_denyButton_notAffirmative() {
        let dialog = AndroidRecorderDetection.detectPermissionDialog(
            x: 540, y: 1310, tree: permissionTree()
        )
        XCTAssertEqual(dialog?.affirmative, false)
        XCTAssertEqual(dialog?.buttonLabel, "Don't allow")
    }

    /// Diálogo en español: la detección no depende del idioma del botón
    /// (package + keywords localizados).
    func testDetectPermission_spanishDialog_sameResult() {
        let dialog = AndroidRecorderDetection.detectPermissionDialog(
            x: 540, y: 1160,
            tree: permissionTree(
                message: "¿Permitir que TestApp acceda a la ubicación de este dispositivo?",
                allowLabel: "Mientras la app está en uso"
            )
        )
        XCTAssertEqual(dialog?.affirmative, true)
        XCTAssertEqual(dialog?.service, "location")
    }

    /// AOSP viejo usa com.android.packageinstaller.
    func testDetectPermission_packageInstallerPackage_detected() {
        let dialog = AndroidRecorderDetection.detectPermissionDialog(
            x: 540, y: 1160,
            tree: permissionTree(controllerPackage: "com.android.packageinstaller")
        )
        XCTAssertNotNil(dialog)
        XCTAssertEqual(dialog?.affirmative, true)
    }

    /// Tap en una app normal (sin permission controller en el tree) → nil.
    func testDetectPermission_normalApp_returnsNil() {
        let tree = [appRoot(fieldValue: "")]
        XCTAssertNil(AndroidRecorderDetection.detectPermissionDialog(x: 540, y: 1060, tree: tree))
    }

    func testIsAffirmativeLabel_dontAllowBeatsAllow() {
        // "Don't allow" contiene "allow" — lo negativo se evalúa primero
        XCTAssertFalse(AndroidRecorderDetection.isAffirmativeLabel("Don't allow"))
        XCTAssertFalse(AndroidRecorderDetection.isAffirmativeLabel("Deny"))
        XCTAssertFalse(AndroidRecorderDetection.isAffirmativeLabel("No permitir"))
        XCTAssertTrue(AndroidRecorderDetection.isAffirmativeLabel("Allow"))
        XCTAssertTrue(AndroidRecorderDetection.isAffirmativeLabel("Only this time"))
        XCTAssertTrue(AndroidRecorderDetection.isAffirmativeLabel("Permitir"))
    }

    func testPermissionService_keywords() {
        XCTAssertEqual(AndroidRecorderDetection.permissionService(
            fromMessage: "Allow X to record audio?"), "microphone")
        XCTAssertEqual(AndroidRecorderDetection.permissionService(
            fromMessage: "Allow X to send you notifications?"), "notifications")
        XCTAssertEqual(AndroidRecorderDetection.permissionService(
            fromMessage: "Allow X to access your contacts?"), "contacts")
        XCTAssertNil(AndroidRecorderDetection.permissionService(
            fromMessage: "Allow X to do something exotic?"))
    }

    func testRequestingAppPackage_skipsSystemPackages() {
        var tree = permissionTree()
        // Inyectar una ventana de systemui antes de la app real
        let sysWindow: [String: Any] = [
            "role": "Window", "title": "System", "label": "window: system",
            "identifier": "", "focused": false,
            "package": "com.android.systemui",
            "frame": ["x": 0, "y": 0, "width": 1080, "height": 80],
            "children": [[String: Any]](),
        ]
        tree.insert(sysWindow, at: 1)
        XCTAssertEqual(AndroidRecorderDetection.requestingAppPackage(in: tree), "com.example.app")
    }
}
