import XCTest
@testable import AutoCore

/// Tests de AutoWait (#157): auto-wait pre-acción + retryTapIfNoChange.
///
/// Config rápida en todos (`fast`): la semántica no depende de los tiempos
/// reales de producción (1500/50/800ms) y la suite no debe dormir.
final class AutoWaitTests: XCTestCase {

    /// Config con tiempos mínimos para que los loops iteren varias veces
    /// sin hacer lenta la suite. Sin re-tap (default de producción).
    private let fast = AutoWait.Config(
        enabled: true,
        stabilityDeadline: 0.25,
        pollInterval: 0.002,
        retryDeadline: 0.03,
        maxFetchCost: 10 // nunca dispara backoff en estos tests
    )

    /// Como `fast` pero con re-tap habilitado (AUTO_RETRY_TAP=1).
    private var fastRetry: AutoWait.Config {
        var config = fast
        config.retryTap = true
        return config
    }

    private let treeA: [[String: Any]] = [
        ["role": "Button", "label": "Login",
         "frame": ["x": 10, "y": 20, "width": 100, "height": 44] as [String: Any]]
    ]
    private let treeB: [[String: Any]] = [
        ["role": "Button", "label": "Logout",
         "frame": ["x": 10, "y": 20, "width": 100, "height": 44] as [String: Any]]
    ]

    override func tearDown() {
        AutoWait._resetBackoffForTesting()
        super.tearDown()
    }

    // MARK: - treeHash

    /// Mismo árbol (aunque sea otra instancia) → mismo hash; cambio de label,
    /// de frame o de estructura → hash distinto.
    func testTreeHashStableAndSensitive() {
        XCTAssertEqual(AutoWait.treeHash(treeA), AutoWait.treeHash(treeA))
        XCTAssertNotEqual(AutoWait.treeHash(treeA), AutoWait.treeHash(treeB))

        var moved = treeA
        moved[0]["frame"] = ["x": 10, "y": 200, "width": 100, "height": 44] as [String: Any]
        XCTAssertNotEqual(AutoWait.treeHash(treeA), AutoWait.treeHash(moved))

        XCTAssertNotEqual(AutoWait.treeHash(treeA), AutoWait.treeHash(treeA + treeA))
    }

    /// `value` NO participa del hash: values flapean (relojes, texto mientras
    /// se tipea) y harían que el loop de estabilidad nunca converja.
    func testTreeHashIgnoresValue() {
        var withValue = treeA
        withValue[0]["value"] = "12:59:03"
        XCTAssertEqual(AutoWait.treeHash(treeA), AutoWait.treeHash(withValue))
    }

    /// El hash es recursivo sobre children — un cambio profundo se detecta.
    func testTreeHashRecursesIntoChildren() {
        let nested: [[String: Any]] = [["role": "Group", "children": treeA] as [String: Any]]
        let nestedChanged: [[String: Any]] = [["role": "Group", "children": treeB] as [String: Any]]
        XCTAssertNotEqual(AutoWait.treeHash(nested), AutoWait.treeHash(nestedChanged))
    }

    // MARK: - stabilize (pre-acción)

    /// Árbol ya estable: 2 lecturas idénticas y listo.
    func testStabilizeStableTreeTwoReads() {
        var fetches = 0
        let snapshot = AutoWait.stabilize(config: fast) { fetches += 1; return self.treeA }
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(snapshot?.stable, true)
        XCTAssertEqual(snapshot?.hash, AutoWait.treeHash(treeA))
    }

    /// UI animando (A→B→B): espera hasta ver dos lecturas iguales.
    func testStabilizeWaitsForUnstableTree() {
        let sequence = [treeA, treeB, treeB]
        var fetches = 0
        let snapshot = AutoWait.stabilize(config: fast) {
            defer { fetches += 1 }
            return sequence[min(fetches, sequence.count - 1)]
        }
        XCTAssertEqual(fetches, 3) // A, B (≠), B (== → estable)
        XCTAssertEqual(snapshot?.stable, true)
        XCTAssertEqual(snapshot?.hash, AutoWait.treeHash(treeB))
    }

    /// `initialTree` cuenta como primera muestra — el árbol que TapTargets ya
    /// fetcheó no se paga dos veces.
    func testStabilizeReusesInitialTree() {
        var fetches = 0
        let snapshot = AutoWait.stabilize(initialTree: treeA, config: fast) {
            fetches += 1
            return self.treeA
        }
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(snapshot?.stable, true)
    }

    /// UI que nunca se estabiliza: al vencer el deadline procede igual
    /// (best-effort, stable == false) con la última lectura como pre-hash.
    func testStabilizeDeadlineProceedsUnstable() {
        var toggle = false
        let snapshot = AutoWait.stabilize(config: fast) {
            toggle.toggle()
            return toggle ? self.treeA : self.treeB
        }
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.stable, false)
    }

    /// Error del fetch → nil (la acción procede sin verificación, nunca lanza).
    func testStabilizeFetchErrorReturnsNil() {
        let snapshot = AutoWait.stabilize(config: fast) {
            throw BridgeError.adbFailed("agent down") as Error
        }
        XCTAssertNil(snapshot)
    }

    // MARK: - AUTO_NO_WAIT bypass

    func testConfigFromEnvironmentNoWait() {
        XCTAssertFalse(AutoWait.Config.fromEnvironment(["AUTO_NO_WAIT": "1"]).enabled)
        XCTAssertFalse(AutoWait.Config.fromEnvironment(["AUTO_NO_WAIT": "true"]).enabled)
        XCTAssertTrue(AutoWait.Config.fromEnvironment([:]).enabled)
        XCTAssertTrue(AutoWait.Config.fromEnvironment(["AUTO_NO_WAIT": "0"]).enabled)
    }

    /// El re-tap estilo Maestro es OPT-IN (AUTO_RETRY_TAP=1): el re-tap ciego
    /// duplica input en UIs con efecto invisible al árbol (keypad PIN de
    /// Explorea, verificado en emulador — ver header de AutoWait.swift).
    func testConfigRetryTapIsOptIn() {
        XCTAssertFalse(AutoWait.Config.fromEnvironment([:]).retryTap)
        XCTAssertTrue(AutoWait.Config.fromEnvironment(["AUTO_RETRY_TAP": "1"]).retryTap)
        XCTAssertTrue(AutoWait.Config.fromEnvironment(["AUTO_RETRY_TAP": "true"]).retryTap)
        XCTAssertFalse(AutoWait.Config.fromEnvironment(["AUTO_RETRY_TAP": "0"]).retryTap)
    }

    func testConfigFromEnvironmentTunables() {
        let config = AutoWait.Config.fromEnvironment([
            "AUTO_WAIT_STABLE_MS": "2000",
            "AUTO_WAIT_POLL_MS": "75",
            "AUTO_WAIT_RETRY_MS": "500",
            "AUTO_WAIT_MAX_FETCH_MS": "100",
        ])
        XCTAssertEqual(config.stabilityDeadline, 2.0, accuracy: 0.001)
        XCTAssertEqual(config.pollInterval, 0.075, accuracy: 0.001)
        XCTAssertEqual(config.retryDeadline, 0.5, accuracy: 0.001)
        XCTAssertEqual(config.maxFetchCost, 0.1, accuracy: 0.001)
        // Valores basura no rompen los defaults
        let junk = AutoWait.Config.fromEnvironment(["AUTO_WAIT_POLL_MS": "abc"])
        XCTAssertEqual(junk.pollInterval, 0.05, accuracy: 0.001)
    }

    /// Config deshabilitada → cero fetches, cero verificación.
    func testDisabledConfigBypassesEverything() {
        var fetches = 0
        let snapshot = AutoWait.stabilize(config: .disabled) { fetches += 1; return self.treeA }
        XCTAssertNil(snapshot)
        XCTAssertEqual(fetches, 0)

        var retaps = 0
        let outcome = AutoWait.verifyTapEffect(
            target: "X", preHash: 0, config: .disabled,
            fetch: { fetches += 1; return self.treeA },
            retap: { retaps += 1 }
        )
        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(fetches, 0)
        XCTAssertEqual(retaps, 0)
    }

    // MARK: - verifyTapEffect (retryTapIfNoChange)

    /// El hash cambia tras el tap → efecto confirmado, sin re-tap.
    func testVerifyChangedNoRetry() {
        var retaps = 0
        let outcome = AutoWait.verifyTapEffect(
            target: "Login", preHash: AutoWait.treeHash(treeA), config: fast,
            fetch: { self.treeB },
            retap: { retaps += 1 }
        )
        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(retaps, 0)
    }

    /// DEFAULT: sin cambio de hash → warning honesto SIN re-tap. El re-tap
    /// ciego duplica input cuando el efecto es invisible al árbol (dígitos
    /// de un keypad dibujado en Canvas) — verificado en el emulador con el
    /// PIN de Explorea, donde el árbol queda byte-idéntico tras cada dígito.
    func testVerifyNoRetapByDefault() {
        var retaps = 0
        let outcome = AutoWait.verifyTapEffect(
            target: "2", preHash: AutoWait.treeHash(treeA), config: fast,
            fetch: { self.treeA },
            retap: { retaps += 1 }
        )
        XCTAssertEqual(outcome, .noChange)
        XCTAssertEqual(retaps, 0) // nunca re-tapea sin AUTO_RETRY_TAP=1
    }

    /// AUTO_RETRY_TAP=1: sin cambio → UN re-tap; si tras el re-tap cambia → OK.
    func testVerifyRetryFiresOnNoChangeThenChanges() {
        var retaps = 0
        let outcome = AutoWait.verifyTapEffect(
            target: "Login", preHash: AutoWait.treeHash(treeA), config: fastRetry,
            fetch: { retaps == 0 ? self.treeA : self.treeB },
            retap: { retaps += 1 }
        )
        XCTAssertEqual(outcome, .changedAfterRetry)
        XCTAssertEqual(retaps, 1)
    }

    /// AUTO_RETRY_TAP=1 sin cambio tras 2 intentos → .noChange (warning
    /// honesto, NO error: hay taps legítimos sin efecto visual).
    func testVerifyNoChangeAfterTwoAttempts() {
        var retaps = 0
        let outcome = AutoWait.verifyTapEffect(
            target: "Login", preHash: AutoWait.treeHash(treeA), config: fastRetry,
            fetch: { self.treeA },
            retap: { retaps += 1 }
        )
        XCTAssertEqual(outcome, .noChange)
        XCTAssertEqual(retaps, 1) // exactamente UN re-tap, nunca más
    }

    /// Un error del re-tap NO propaga: el tap original ya se reportó ejecutado.
    func testVerifyRetapErrorDoesNotThrow() {
        let outcome = AutoWait.verifyTapEffect(
            target: "Login", preHash: AutoWait.treeHash(treeA), config: fastRetry,
            fetch: { self.treeA },
            retap: { throw BridgeError.elementNotFound("gone") }
        )
        XCTAssertEqual(outcome, .noChange)
    }

    // MARK: - Backoff adaptativo (árbol caro)

    /// Un fetch más caro que `maxFetchCost` apaga AutoWait para el proceso:
    /// la verificación se salta y el siguiente stabilize ni fetchea.
    func testExpensiveTreeTriggersBackoff() {
        var config = fast
        config.maxFetchCost = 0.001
        let snapshot = AutoWait.stabilize(config: config) {
            usleep(5_000) // 5ms > 1ms
            return self.treeA
        }
        // Devuelve la lectura como pre-hash válido, pero marca el backoff.
        XCTAssertNotNil(snapshot)
        XCTAssertTrue(AutoWait.isBackedOff)

        var fetches = 0
        let second = AutoWait.stabilize(config: config) { fetches += 1; return self.treeA }
        XCTAssertNil(second)
        XCTAssertEqual(fetches, 0)

        let outcome = AutoWait.verifyTapEffect(
            target: "X", preHash: snapshot!.hash, config: config,
            fetch: { self.treeA }, retap: {}
        )
        XCTAssertEqual(outcome, .skipped)
    }

    // MARK: - Variantes async (rutas via ActionRouter)

    func testAsyncStabilizeAndVerify() async {
        var fetches = 0
        let snapshot = await AutoWait.stabilize(config: fast) {
            fetches += 1
            return self.treeA
        }
        XCTAssertEqual(fetches, 2)
        XCTAssertEqual(snapshot?.hash, AutoWait.treeHash(treeA))

        var retaps = 0
        let outcome = await AutoWait.verifyTapEffect(
            target: "Login", preHash: snapshot!.hash, config: fastRetry,
            fetch: { retaps == 0 ? self.treeA : self.treeB },
            retap: { retaps += 1 }
        )
        XCTAssertEqual(outcome, .changedAfterRetry)
        XCTAssertEqual(retaps, 1)
    }

    // MARK: - Integración con el dispatcher (MockBridge)

    /// Tap por dispatcher con AutoWait activo y árbol que cambia tras el tap:
    /// un solo tap, sin retry.
    func testDispatcherTapVerifiedSingleTapWhenTreeChanges() throws {
        let bridge = MockBridge()
        // stabilize: A, A (estable) → tap → verify: B (cambió)
        bridge.treeSequence = [treeA, treeA, treeB]
        _ = try executeSharedCommand(["tap", "Login"], bridge: bridge, autoWait: fast)
        XCTAssertEqual(bridge.callCount("tap"), 1)
        XCTAssertGreaterThanOrEqual(bridge.callCount("tree"), 3)
    }

    /// Árbol congelado con default: UN solo tap (sin re-tap) y no lanza —
    /// warning honesto, no "mentira en verde" ni falso rojo ni doble input.
    func testDispatcherTapFrozenTreeDefaultNoRetap() throws {
        let bridge = MockBridge()
        bridge.treeNodes = treeA // nunca cambia
        _ = try executeSharedCommand(["tap", "Login"], bridge: bridge, autoWait: fast)
        XCTAssertEqual(bridge.callCount("tap"), 1)
    }

    /// Árbol congelado con AUTO_RETRY_TAP=1: el dispatcher re-tapea UNA vez.
    func testDispatcherTapRetriesOnFrozenTree() throws {
        let bridge = MockBridge()
        bridge.treeNodes = treeA // nunca cambia
        _ = try executeSharedCommand(["tap", "Login"], bridge: bridge, autoWait: fastRetry)
        XCTAssertEqual(bridge.callCount("tap"), 2) // tap + un re-tap
    }

    /// AUTO_NO_WAIT (config disabled) por dispatcher: comportamiento legacy —
    /// tap directo sin ninguna lectura de árbol.
    func testDispatcherTapDisabledNoTreeReads() throws {
        let bridge = MockBridge()
        _ = try executeSharedCommand(["tap", "Login"], bridge: bridge, autoWait: .disabled)
        XCTAssertEqual(bridge.callCount("tap"), 1)
        XCTAssertEqual(bridge.callCount("tree"), 0)
    }

    /// Multi-tap por coma: el árbol de TapTargets se reusa como primera
    /// muestra de estabilidad del PRIMER target (sin fetch duplicado) y el
    /// default NO re-tapea aunque el árbol quede congelado — exactamente el
    /// escenario PIN "tap 1,2,3,4" donde el re-tap duplicaría dígitos.
    func testDispatcherMultiTapFrozenTreeNoDoubleDigits() throws {
        let bridge = MockBridge()
        bridge.treeNodes = [["label": "1"], ["label": "2"]]
        _ = try executeSharedCommand(["tap", "1,2"], bridge: bridge, autoWait: fast)
        let tapped = bridge.calls.filter { $0.method == "tap" }.map { $0.args[0] }
        XCTAssertEqual(tapped, ["1", "2"]) // sin duplicados
        // TapTargets fetchea 1 vez; el primer stabilize solo agrega 1 lectura
        // (la muestra inicial viene heredada).
        let treeCalls = bridge.callCount("tree")
        XCTAssertGreaterThanOrEqual(treeCalls, 2)
    }

    /// #158: multi-tap por dispatcher — la pre-estabilización corre UNA sola vez
    /// para toda la ráfaga, no una por dígito. Con árbol frozen y
    /// `retryDeadline: 0` (1 fetch de verify por tap):
    ///   1 (TapTargets) + 1 (estabilización única, seed heredado) + 2 (verify) = 4.
    /// Con estabilización por-dígito (el bug) el 2º dígito, sin seed, pagaría
    /// 2 fetches de estabilidad extra → total mayor.
    func testDispatcherMultiTapStabilizesOnce() throws {
        let bridge = MockBridge()
        bridge.treeNodes = [["label": "1"], ["label": "2"]]
        _ = try executeSharedCommand(["tap", "1,2"], bridge: bridge, autoWait: countable)
        let tapped = bridge.calls.filter { $0.method == "tap" }.map { $0.args[0] }
        XCTAssertEqual(tapped, ["1", "2"])
        XCTAssertEqual(bridge.callCount("tree"), 4)
    }

    /// Enhancement Android con backend programable y AUTO_RETRY_TAP=1: árbol
    /// congelado → re-tap por coordenada (mismo camino que el tap original).
    func testAndroidEnhancementRetapsByCoordinate() async throws {
        let backend = AndroidTapMockBackend()
        backend.treeNodes = [
            ["label": "Enviar", "frame": ["x": 0, "y": 0, "width": 100, "height": 50] as [String: Any]]
        ]
        let registry = CapabilityRegistry()
        await registry.register(backend)
        let router = ActionRouter(registry: registry)
        try await AndroidTapEnhancement.execute(
            args: ["tap", "Enviar"], router: router,
            start: CFAbsoluteTimeGetCurrent(), autoWait: fastRetry)
        let coordinateTaps = backend.executed.filter {
            if case .tapAtCoordinate = $0 { return true }
            return false
        }
        XCTAssertEqual(coordinateTaps.count, 2) // tap + re-tap, ambos por frame
    }

    // MARK: - #158: estabilización única en multi-tap

    /// Config donde la verificación post-tap consume exactamente UN fetch por
    /// tap (`retryDeadline: 0` → el poll de cambio vence tras la primera
    /// lectura). Aísla los fetches de pre-estabilización de los de
    /// verificación para poder contar cuántas veces se estabiliza.
    private var countable: AutoWait.Config {
        AutoWait.Config(
            enabled: true,
            stabilityDeadline: 0.25,
            pollInterval: 0.002,
            retryDeadline: 0, // 1 fetch de verificación por tap, determinista
            maxFetchCost: 10
        )
    }

    /// Cuenta cuántos `.tree` ejecutó el backend (Android).
    private func treeFetchCount(_ backend: AndroidTapMockBackend) -> Int {
        backend.executed.filter { if case .tree = $0 { return true }; return false }.count
    }

    /// #158: en un multi-tap `1,2,3,4` sobre un keypad de PIN (layout congelado)
    /// la pre-estabilización debe correr UNA sola vez, no una por dígito. Con
    /// árbol frozen y `retryDeadline: 0`:
    ///   - TapTargets: 1 fetch (resuelve la coma)
    ///   - pre-estabilización única: 1 fetch (el seed hereda la muestra inicial)
    ///   - verificación post-tap: 1 fetch por dígito = 4
    /// Total = 6. Con estabilización por-dígito (el bug) serían más: cada
    /// dígito 2..N sin seed pagaría 2 fetches de estabilidad extra.
    func testAndroidMultiTapStabilizesOnce() async throws {
        let backend = AndroidTapMockBackend()
        backend.treeNodes = [["label": "1"], ["label": "2"], ["label": "3"], ["label": "4"]]
        let registry = CapabilityRegistry()
        await registry.register(backend)
        let router = ActionRouter(registry: registry)
        try await AndroidTapEnhancement.execute(
            args: ["tap", "1,2,3,4"], router: router,
            start: CFAbsoluteTimeGetCurrent(), autoWait: countable)

        let taps = backend.executed.filter { if case .tap = $0 { return true }; return false }
        XCTAssertEqual(taps.count, 4)
        // 1 (TapTargets) + 1 (estabilización única) + 4 (verify) = 6.
        // La clave: NO escala con la estabilización por dígito.
        XCTAssertEqual(treeFetchCount(backend), 6)
    }

    /// #158: contraste — un multi-tap de 2 dígitos debe estabilizar exactamente
    /// las mismas veces (1) que uno de 4. El total de fetches solo crece por la
    /// verificación post-tap (1/tap), no por re-estabilización.
    func testAndroidMultiTapStabilizationDoesNotScaleWithDigits() async throws {
        func fetches(forDigits raw: String, count expected: Int) async throws -> Int {
            let backend = AndroidTapMockBackend()
            backend.treeNodes = (1...expected).map { ["label": "\($0)"] }
            let registry = CapabilityRegistry()
            await registry.register(backend)
            let router = ActionRouter(registry: registry)
            try await AndroidTapEnhancement.execute(
                args: ["tap", raw], router: router,
                start: CFAbsoluteTimeGetCurrent(), autoWait: countable)
            return treeFetchCount(backend)
        }
        AutoWait._resetBackoffForTesting()
        let two = try await fetches(forDigits: "1,2", count: 2)
        AutoWait._resetBackoffForTesting()
        let four = try await fetches(forDigits: "1,2,3,4", count: 4)
        // Diferencia = solo 2 verificaciones extra (2 dígitos más), NO
        // estabilizaciones extra. Con el bug la diferencia sería mayor.
        XCTAssertEqual(four - two, 2)
    }

    /// Enhancement Android con default: árbol congelado → UN solo tap.
    func testAndroidEnhancementNoRetapByDefault() async throws {
        let backend = AndroidTapMockBackend()
        backend.treeNodes = [
            ["label": "2", "frame": ["x": 0, "y": 0, "width": 100, "height": 50] as [String: Any]]
        ]
        let registry = CapabilityRegistry()
        await registry.register(backend)
        let router = ActionRouter(registry: registry)
        try await AndroidTapEnhancement.execute(
            args: ["tap", "2"], router: router,
            start: CFAbsoluteTimeGetCurrent(), autoWait: fast)
        let coordinateTaps = backend.executed.filter {
            if case .tapAtCoordinate = $0 { return true }
            return false
        }
        XCTAssertEqual(coordinateTaps.count, 1)
    }
}
