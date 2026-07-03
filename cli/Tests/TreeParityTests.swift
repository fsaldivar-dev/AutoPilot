import XCTest
@testable import AutoCore
@testable import AutoLibiOS

/// #150 — el observer iOS emite árbol ANIDADO (children) con las keys de
/// Android. Estos tests cubren los consumidores que antes asumían el shape
/// plano: TreeQuery (search/deepestNode, usados por iOSAgentBridge y
/// AgentBridge) y iOSListFilter (el filtro de `auto list <tipo>`).
final class TreeParityTests: XCTestCase {

    // MARK: - Fixture: árbol con el shape nuevo del observer iOS

    /// Ventana → grupo → {label, botón, textfield, scroll → botón profundo}.
    /// Mismas keys core que el agente Android (title/label/identifier/value/
    /// enabled/clickable/scrollable/focused/package/frame/children) + las
    /// extras iOS (class, placeholder).
    private func observerTree() -> [[String: Any]] {
        func node(role: String, title: String = "", label: String = "",
                  identifier: String = "", value: String = "",
                  placeholder: String? = nil,
                  frame: [String: Int] = ["x": 0, "y": 0, "width": 100, "height": 50],
                  children: [[String: Any]] = []) -> [String: Any] {
            var n: [String: Any] = [
                "role": role, "title": title, "label": label,
                "identifier": identifier, "value": value,
                "enabled": true, "clickable": role == "AXButton",
                "scrollable": role == "AXScrollArea", "focused": false,
                "package": "com.example.app", "frame": frame,
                "children": children
            ]
            if let ph = placeholder { n["placeholder"] = ph }
            return n
        }

        return [
            node(role: "AXWindow",
                 frame: ["x": 0, "y": 0, "width": 402, "height": 874],
                 children: [
                    node(role: "AXGroup",
                         frame: ["x": 0, "y": 0, "width": 402, "height": 874],
                         children: [
                            node(role: "AXStaticText", title: "Bienvenido",
                                 frame: ["x": 20, "y": 100, "width": 200, "height": 30]),
                            node(role: "AXButton", label: "Confirmar",
                                 frame: ["x": 20, "y": 200, "width": 120, "height": 44]),
                            node(role: "AXTextField", value: "hola",
                                 placeholder: "Escribe algo",
                                 frame: ["x": 20, "y": 300, "width": 300, "height": 40]),
                            node(role: "AXScrollArea",
                                 frame: ["x": 0, "y": 400, "width": 402, "height": 400],
                                 children: [
                                    node(role: "AXButton", label: "Profundo",
                                         identifier: "deep.button",
                                         frame: ["x": 40, "y": 500, "width": 80, "height": 40])
                                 ])
                         ])
                 ])
        ]
    }

    // MARK: - TreeQuery.flatten / walk

    func testFlattenVisitsEveryNestedNode() {
        let flat = TreeQuery.flatten(observerTree())
        XCTAssertEqual(flat.count, 7, "window + group + label + botón + textfield + scroll + botón profundo")
    }

    func testWalkIsPreOrder() {
        var roles: [String] = []
        TreeQuery.walk(observerTree()) { roles.append($0["role"] as? String ?? "?") }
        XCTAssertEqual(roles.first, "AXWindow")
        XCTAssertEqual(roles.last, "AXButton", "el botón dentro del scroll va al final (DFS)")
    }

    // MARK: - TreeQuery.search (usado por iOSAgentBridge.search / exists / waitFor)

    func testSearchFindsDeeplyNestedNodeByLabel() {
        let results = TreeQuery.search(observerTree(), query: "profundo")
        XCTAssertEqual(results.count, 1, "el botón vive 3 niveles abajo — la búsqueda plana no lo veía")
        XCTAssertEqual(results.first?["identifier"] as? String, "deep.button")
    }

    func testSearchMatchesTitleLabelIdentifierValueAndPlaceholder() {
        let tree = observerTree()
        XCTAssertFalse(TreeQuery.search(tree, query: "Bienvenido").isEmpty, "title")
        XCTAssertFalse(TreeQuery.search(tree, query: "confirmar").isEmpty, "label, case-insensitive")
        XCTAssertFalse(TreeQuery.search(tree, query: "deep.button").isEmpty, "identifier")
        XCTAssertFalse(TreeQuery.search(tree, query: "hola").isEmpty, "value — texto tipeado (#166)")
        XCTAssertFalse(TreeQuery.search(tree, query: "Escribe algo").isEmpty, "placeholder (#166)")
    }

    func testSearchNoMatchReturnsEmpty() {
        XCTAssertTrue(TreeQuery.search(observerTree(), query: "inexistente").isEmpty)
    }

    func testSearchDoesNotDuplicateNodeMatchingSeveralKeys() {
        // Un nodo cuyo title Y label matchean debe aparecer UNA vez.
        let tree: [[String: Any]] = [[
            "role": "AXButton", "title": "Guardar", "label": "Guardar",
            "children": [[String: Any]]()
        ]]
        XCTAssertEqual(TreeQuery.search(tree, query: "guardar").count, 1)
    }

    // MARK: - TreeQuery.deepestNode (usado por elementAt)

    func testDeepestNodeReturnsSmallestContainingFrame() {
        // (60, 520) está dentro de window, group, scroll y el botón profundo —
        // debe ganar el botón (área más chica), no el contenedor.
        let el = TreeQuery.deepestNode(x: 60, y: 520, in: observerTree())
        XCTAssertEqual(el?["identifier"] as? String, "deep.button")
    }

    func testDeepestNodeOutsideAllFramesReturnsNil() {
        XCTAssertNil(TreeQuery.deepestNode(x: 9999, y: 9999, in: observerTree()))
    }

    func testDeepestNodeAcceptsDoubleFrames() {
        // El agente Android serializa Int; otros backends Double — ambos valen.
        let tree: [[String: Any]] = [[
            "role": "Button", "title": "OK",
            "frame": ["x": 10.0, "y": 10.0, "width": 50.0, "height": 20.0],
            "children": [[String: Any]]()
        ]]
        XCTAssertEqual(TreeQuery.deepestNode(x: 20, y: 15, in: tree)?["title"] as? String, "OK")
    }

    // MARK: - iOSListFilter (`auto list <tipo>` con árbol anidado)

    func testListButtonsRecursesIntoChildren() {
        let buttons = iOSListFilter.filter(tree: observerTree(), type: "buttons")
        XCTAssertEqual(buttons.count, 2, "Confirmar + Profundo (anidado en el scroll)")
        let labels = buttons.compactMap { $0["label"] as? String }
        XCTAssertTrue(labels.contains("Confirmar"))
        XCTAssertTrue(labels.contains("Profundo"))
    }

    func testListTextfieldsFindsNestedInput() {
        let fields = iOSListFilter.filter(tree: observerTree(), type: "textfields")
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?["value"] as? String, "hola")
    }

    func testListAllFlattensTheWholeTree() {
        XCTAssertEqual(iOSListFilter.filter(tree: observerTree(), type: "all").count, 7)
    }

    func testListUnknownTypeReturnsEmpty() {
        XCTAssertTrue(iOSListFilter.filter(tree: observerTree(), type: "widgets").isEmpty)
    }

    // MARK: - Consumidores compartidos con el shape nuevo (smoke)

    func testTapTargetsExactMatchSeesNestedLabel() {
        // "Escribe, algo" no existe → multi-tap; "Profundo" anidado sí existe.
        XCTAssertTrue(TapTargets.hasExactMatch("Profundo", in: observerTree()))
        XCTAssertFalse(TapTargets.hasExactMatch("No existe", in: observerTree()))
    }

    func testAutoWaitHashDetectsDeepChange() {
        var tree = observerTree()
        let h1 = AutoWait.treeHash(tree)
        // Cambiar el label del botón profundo (nivel 4) debe cambiar el hash.
        var window = tree[0]
        var group = (window["children"] as! [[String: Any]])[0]
        var scroll = (group["children"] as! [[String: Any]])[3]
        var deep = (scroll["children"] as! [[String: Any]])[0]
        deep["label"] = "Cambiado"
        scroll["children"] = [deep]
        var groupChildren = group["children"] as! [[String: Any]]
        groupChildren[3] = scroll
        group["children"] = groupChildren
        window["children"] = [group]
        tree[0] = window
        XCTAssertNotEqual(h1, AutoWait.treeHash(tree))
    }

    func testViewFingerprintCaptureWorksOnNestedTree() {
        let fp = ViewFingerprint.capture(tree: observerTree())
        XCTAssertEqual(fp.rootChildCount, 1, "una ventana raíz")
        XCTAssertFalse(fp.topLevelSignature.isEmpty)
    }
}
