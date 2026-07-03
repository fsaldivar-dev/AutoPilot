import Foundation

// MARK: - AutoWait (#157)
//
// Tolerancia a flakiness estilo Maestro, en el nivel compartido:
//
//  1. **Pre-acción (estabilidad)**: antes de tap/type/scroll, poll del árbol
//     hasta 2 lecturas consecutivas con el MISMO hash (hash barato del árbol
//     serializado: roles + labels + frames). Si la UI está animando, esperamos
//     a que termine antes de actuar — el fix de fondo de la clase de bugs
//     "actué sobre un frame intermedio".
//
//  2. **Post-tap (verificación de efecto)**: hash del árbol antes del tap;
//     tras el tap, poll esperando CAMBIO de hash. Sin cambio → warning
//     honesto en stderr. Con `AUTO_RETRY_TAP=1` además se hace UN re-tap
//     estilo Maestro (`retryTapIfNoChange`) antes del warning.
//
//     **Por qué warning y NO error duro**: existen taps legítimos sin efecto
//     visual — tap en un campo ya enfocado, tap en un botón toggle que solo
//     cambia estado interno, tap para descartar un teclado que no está, tap
//     en un elemento cuyo efecto es lanzar trabajo en background. Un error
//     duro rompería scripts válidos; el warning deja el rastro honesto en
//     stderr sin mentir en verde NI fallar en falso. Los asserts explícitos
//     (`waitFor`, `assertScreen`, `assertOCR`) siguen siendo la herramienta
//     para postcondiciones duras.
//
//     **Por qué el re-tap es OPT-IN y no default**: verificación runtime en
//     el emulador (Explorea, keypad de PIN) demostró que el árbol de
//     accesibilidad queda BYTE-IDÉNTICO al tipear un dígito — los dots del
//     indicador son dibujo puro en Canvas, invisibles a cualquier hash del
//     árbol. Con re-tap default, `tap 2` duplicaba el dígito (PIN "1223…"),
//     rompiendo `scripts/examples/android-login.auto`. Es la misma razón por
//     la que Maestro terminó deprecando `retryTapIfNoChange`: el re-tap
//     ciego convierte "efecto invisible" en "efecto doble". El warning ya
//     mata la mentira en verde; el re-tap queda para quien sepa que su UI
//     no tiene efectos hash-invisibles (AUTO_RETRY_TAP=1).
//
//  3. **Config por env**:
//       AUTO_NO_WAIT=1            desactiva todo (benchmarks / CI rápido)
//       AUTO_RETRY_TAP=1          re-tap estilo Maestro si no hubo cambio
//       AUTO_WAIT_STABLE_MS       deadline de estabilidad pre-acción (1500)
//       AUTO_WAIT_POLL_MS         espaciado entre muestras (50)
//       AUTO_WAIT_RETRY_MS        deadline de cambio post-tap por intento (800)
//       AUTO_WAIT_MAX_FETCH_MS    umbral de backoff por árbol caro (250)
//
//  **Backoff adaptativo ("mide y decide")**: con tree a 25-34ms (AgentBridge
//  Android, observer iOS) esto es casi gratis. En XCUI puro un tree puede
//  costar segundos — medimos el costo de CADA fetch y si excede
//  `maxFetchCost` marcamos el proceso como "árbol caro" y AutoWait se apaga
//  solo para el resto del proceso (se paga a lo sumo UNA lectura cara).
//
//  El espaciado entre muestras descuenta el costo del fetch
//  (`sleep = pollInterval - fetchCost`): las muestras quedan separadas
//  `pollInterval` de reloj de pared, sin pagar el intervalo completo encima
//  de un fetch lento.
public enum AutoWait {

    // MARK: - Config

    public struct Config {
        /// false = bypass total (AUTO_NO_WAIT=1).
        public var enabled: Bool
        /// Deadline del loop de estabilidad pre-acción.
        public var stabilityDeadline: TimeInterval
        /// Espaciado objetivo entre muestras (pre y post). El sleep real
        /// descuenta lo que tardó el fetch.
        public var pollInterval: TimeInterval
        /// Deadline de espera de cambio post-tap, por intento.
        public var retryDeadline: TimeInterval
        /// Costo de fetch a partir del cual el proceso hace backoff
        /// (árbol caro → AutoWait se desactiva solo).
        public var maxFetchCost: TimeInterval
        /// true = re-tap estilo Maestro si el hash no cambió (AUTO_RETRY_TAP=1).
        /// OPT-IN: el re-tap ciego duplica input en UIs con efecto invisible
        /// al árbol (keypads dibujados en Canvas) — ver header del archivo.
        public var retryTap: Bool

        public init(
            enabled: Bool = true,
            stabilityDeadline: TimeInterval = 1.5,
            pollInterval: TimeInterval = 0.05,
            retryDeadline: TimeInterval = 0.8,
            maxFetchCost: TimeInterval = 0.25,
            retryTap: Bool = false
        ) {
            self.enabled = enabled
            self.stabilityDeadline = stabilityDeadline
            self.pollInterval = pollInterval
            self.retryDeadline = retryDeadline
            self.maxFetchCost = maxFetchCost
            self.retryTap = retryTap
        }

        /// Config efectiva del proceso, leída del environment una sola vez.
        public static let current = Config.fromEnvironment(ProcessInfo.processInfo.environment)

        /// Bypass explícito — para tests y benchmarks.
        public static let disabled = Config(enabled: false)

        public static func fromEnvironment(_ env: [String: String]) -> Config {
            var config = Config()
            func flag(_ key: String) -> Bool {
                guard let value = env[key] else { return false }
                return value == "1" || value.lowercased() == "true"
            }
            if flag("AUTO_NO_WAIT") { config.enabled = false }
            if flag("AUTO_RETRY_TAP") { config.retryTap = true }
            func ms(_ key: String) -> TimeInterval? {
                guard let raw = env[key], let value = Double(raw), value >= 0 else { return nil }
                return value / 1000.0
            }
            if let v = ms("AUTO_WAIT_STABLE_MS") { config.stabilityDeadline = v }
            if let v = ms("AUTO_WAIT_POLL_MS") { config.pollInterval = v }
            if let v = ms("AUTO_WAIT_RETRY_MS") { config.retryDeadline = v }
            if let v = ms("AUTO_WAIT_MAX_FETCH_MS") { config.maxFetchCost = v }
            return config
        }
    }

    // MARK: - Snapshot / Outcome

    /// Última lectura del loop de estabilidad: hash + árbol. El árbol se
    /// expone para que el caller lo REUSE en su resolución de target
    /// (Compose clickable, label[N], $N) sin pagar otro fetch.
    public struct Snapshot {
        public let hash: UInt64
        public let tree: [[String: Any]]
        /// true si hubo 2 lecturas consecutivas idénticas dentro del deadline;
        /// false si el deadline venció con la UI aún cambiando (procedemos
        /// igual — AutoWait es best-effort, nunca bloquea la acción).
        public let stable: Bool
    }

    public enum TapOutcome: String, Equatable {
        /// El hash cambió tras el primer tap — efecto confirmado.
        case changed
        /// Sin cambio tras el primer tap; el re-tap sí produjo cambio.
        case changedAfterRetry
        /// Dos intentos sin cambio de hash → warning honesto en stderr.
        case noChange
        /// Verificación no disponible (deshabilitado, backoff por árbol
        /// caro, o el fetch post-tap falló). No se emite warning.
        case skipped
    }

    // MARK: - Tree hash

    /// Hash FNV-1a 64-bit del árbol serializado: role + title + label +
    /// identifier + frame, recursivo sobre children. Deliberadamente NO
    /// incluye `value`: los values flapean sin que la pantalla "cambie"
    /// (relojes, contadores, el propio texto mientras se tipea) y harían
    /// que el loop de estabilidad nunca converja. Dos hashes distintos
    /// prueban que algo cambió; dos hashes iguales no prueban identidad
    /// total — esa asimetría es exactamente lo que necesita la verificación
    /// post-tap (misma filosofía que `ViewFingerprint`).
    public static func treeHash(_ tree: [[String: Any]]) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for node in tree { hashNode(node, into: &hash) }
        return hash
    }

    private static func hashNode(_ node: [String: Any], into hash: inout UInt64) {
        for key in ["role", "title", "label", "identifier", "id"] {
            if let value = node[key] as? String, !value.isEmpty {
                mix(key, into: &hash)
                mix(value, into: &hash)
            }
        }
        if let frame = node["frame"] as? [String: Any] {
            for key in ["x", "y", "width", "height"] {
                if let value = frame[key] {
                    mix("\(value)", into: &hash)
                }
            }
        }
        if let children = node["children"] as? [[String: Any]] {
            for child in children { hashNode(child, into: &hash) }
        }
    }

    private static func mix(_ string: String, into hash: inout UInt64) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // Separador entre campos para que ("ab","c") != ("a","bc").
        hash ^= 0x1f
        hash = hash &* 0x100000001b3
    }

    // MARK: - Backoff memory (árbol caro)

    private final class BackoffMemory: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set(_ value: Bool) { lock.lock(); defer { lock.unlock() }; flag = value }
    }

    private static let backoff = BackoffMemory()

    /// Solo para tests: limpia la memoria de backoff del proceso.
    public static func _resetBackoffForTesting() { backoff.set(false) }
    /// Solo para tests/diagnóstico: ¿el proceso ya decidió que el árbol es caro?
    public static var isBackedOff: Bool { backoff.get() }

    // MARK: - Pre-acción: estabilidad

    /// Espera a que el árbol se estabilice: 2 lecturas consecutivas con el
    /// mismo hash dentro de `stabilityDeadline`. Devuelve la última lectura
    /// (hash + árbol) para que el caller reuse ambos — el hash como pre-hash
    /// del tap y el árbol para resolver el target sin otro fetch.
    ///
    /// - `initialTree`: árbol ya fetcheado por el caller (p.ej. el que
    ///   `TapTargets` pidió para decidir multi-tap) — cuenta como primera
    ///   muestra para no duplicar el fetch.
    /// - Devuelve `nil` si AutoWait está deshabilitado, en backoff, o el
    ///   fetch falla — la acción procede igual, sin verificación.
    ///
    /// Best-effort por diseño: nunca lanza, nunca bloquea más allá del
    /// deadline. Si la UI sigue cambiando al vencer, devolvemos la última
    /// lectura con `stable == false` y la acción procede.
    @discardableResult
    public static func stabilize(
        initialTree: [[String: Any]]? = nil,
        config: Config = .current,
        fetch: () throws -> [[String: Any]]
    ) -> Snapshot? {
        guard config.enabled, !backoff.get() else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + config.stabilityDeadline

        var previous: (hash: UInt64, tree: [[String: Any]])?
        if let initialTree {
            previous = (treeHash(initialTree), initialTree)
        }
        var lastCost: TimeInterval = 0
        var polls = 0

        while true {
            if previous != nil {
                sleepRemainder(of: config.pollInterval, spent: lastCost)
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let tree = try? fetch() else { return nil }
            lastCost = CFAbsoluteTimeGetCurrent() - t0
            polls += 1
            let hash = treeHash(tree)

            if lastCost > config.maxFetchCost {
                // Árbol caro (XCUI puro, bridge degradado): apaga AutoWait
                // para el resto del proceso. Esta lectura sigue siendo un
                // pre-hash válido, pero la verificación post-tap se saltará
                // por el mismo backoff.
                backoff.set(true)
                debugTimingLog("autowait backoff: tree fetch \(Int(lastCost * 1000))ms > \(Int(config.maxFetchCost * 1000))ms")
                return Snapshot(hash: hash, tree: tree, stable: false)
            }
            if let prev = previous, prev.hash == hash {
                debugTimingLog("autowait stable after \(polls) poll(s), \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
                return Snapshot(hash: hash, tree: tree, stable: true)
            }
            previous = (hash, tree)
            if CFAbsoluteTimeGetCurrent() >= deadline {
                debugTimingLog("autowait stability deadline (\(polls) polls) — proceeding unstable")
                return Snapshot(hash: hash, tree: tree, stable: false)
            }
        }
    }

    /// Variante async de `stabilize` — misma semántica, para rutas donde el
    /// árbol viene del `ActionRouter` (enhancements iOS/Android).
    @discardableResult
    public static func stabilize(
        initialTree: [[String: Any]]? = nil,
        config: Config = .current,
        fetch: () async throws -> [[String: Any]]
    ) async -> Snapshot? {
        guard config.enabled, !backoff.get() else { return nil }
        let start = CFAbsoluteTimeGetCurrent()
        let deadline = start + config.stabilityDeadline

        var previous: (hash: UInt64, tree: [[String: Any]])?
        if let initialTree {
            previous = (treeHash(initialTree), initialTree)
        }
        var lastCost: TimeInterval = 0
        var polls = 0

        while true {
            if previous != nil {
                await sleepRemainderAsync(of: config.pollInterval, spent: lastCost)
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let tree = try? await fetch() else { return nil }
            lastCost = CFAbsoluteTimeGetCurrent() - t0
            polls += 1
            let hash = treeHash(tree)

            if lastCost > config.maxFetchCost {
                backoff.set(true)
                debugTimingLog("autowait backoff: tree fetch \(Int(lastCost * 1000))ms > \(Int(config.maxFetchCost * 1000))ms")
                return Snapshot(hash: hash, tree: tree, stable: false)
            }
            if let prev = previous, prev.hash == hash {
                debugTimingLog("autowait stable after \(polls) poll(s), \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000))ms")
                return Snapshot(hash: hash, tree: tree, stable: true)
            }
            previous = (hash, tree)
            if CFAbsoluteTimeGetCurrent() >= deadline {
                debugTimingLog("autowait stability deadline (\(polls) polls) — proceeding unstable")
                return Snapshot(hash: hash, tree: tree, stable: false)
            }
        }
    }

    // MARK: - Post-tap: retryTapIfNoChange

    /// Verifica que el tap tuvo efecto: poll hasta `retryDeadline` esperando
    /// que el hash del árbol CAMBIE respecto a `preHash`.
    ///
    /// Sin cambio → warning honesto en stderr. Con `config.retryTap`
    /// (AUTO_RETRY_TAP=1) además: UN re-tap → poll otra vez → sin cambio →
    /// warning. El re-tap es opt-in porque duplica input en UIs con efecto
    /// invisible al árbol (ver header del archivo).
    ///
    /// Nunca lanza: el tap original ya se ejecutó con éxito y un error del
    /// re-tap o del fetch de verificación no debe convertir esa acción en
    /// fallo (se degrada a `.skipped`/`.noChange` con debug log).
    @discardableResult
    public static func verifyTapEffect(
        target: String,
        preHash: UInt64,
        config: Config = .current,
        fetch: () throws -> [[String: Any]],
        retap: () throws -> Void
    ) -> TapOutcome {
        guard config.enabled, !backoff.get() else { return .skipped }

        switch pollForChange(from: preHash, config: config, fetch: fetch) {
        case .changed: return .changed
        case .unavailable: return .skipped
        case .unchanged: break
        }

        guard config.retryTap else {
            warnNoChange(target, retried: false)
            return .noChange
        }

        debugTimingLog("autowait no change after tap '\(target)' — retapping once")
        do {
            try retap()
        } catch {
            // El elemento pudo desaparecer entre el tap y el re-tap (UI sí
            // cambió pero en campos fuera del hash). No propagamos: el tap
            // original ya fue reportado como ejecutado.
            debugTimingLog("autowait retap failed: \(error)")
            warnNoChange(target, retried: true)
            return .noChange
        }

        switch pollForChange(from: preHash, config: config, fetch: fetch) {
        case .changed: return .changedAfterRetry
        case .unavailable: return .skipped
        case .unchanged:
            warnNoChange(target, retried: true)
            return .noChange
        }
    }

    /// Variante async de `verifyTapEffect` — para las rutas via `ActionRouter`.
    @discardableResult
    public static func verifyTapEffect(
        target: String,
        preHash: UInt64,
        config: Config = .current,
        fetch: () async throws -> [[String: Any]],
        retap: () async throws -> Void
    ) async -> TapOutcome {
        guard config.enabled, !backoff.get() else { return .skipped }

        switch await pollForChangeAsync(from: preHash, config: config, fetch: fetch) {
        case .changed: return .changed
        case .unavailable: return .skipped
        case .unchanged: break
        }

        guard config.retryTap else {
            warnNoChange(target, retried: false)
            return .noChange
        }

        debugTimingLog("autowait no change after tap '\(target)' — retapping once")
        do {
            try await retap()
        } catch {
            debugTimingLog("autowait retap failed: \(error)")
            warnNoChange(target, retried: true)
            return .noChange
        }

        switch await pollForChangeAsync(from: preHash, config: config, fetch: fetch) {
        case .changed: return .changedAfterRetry
        case .unavailable: return .skipped
        case .unchanged:
            warnNoChange(target, retried: true)
            return .noChange
        }
    }

    // MARK: - Internals

    private enum ChangePoll { case changed, unchanged, unavailable }

    private static func pollForChange(
        from preHash: UInt64,
        config: Config,
        fetch: () throws -> [[String: Any]]
    ) -> ChangePoll {
        let deadline = CFAbsoluteTimeGetCurrent() + config.retryDeadline
        var lastCost: TimeInterval = 0
        var first = true
        while true {
            if !first {
                sleepRemainder(of: config.pollInterval, spent: lastCost)
            }
            first = false
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let tree = try? fetch() else { return .unavailable }
            lastCost = CFAbsoluteTimeGetCurrent() - t0
            if treeHash(tree) != preHash { return .changed }
            if lastCost > config.maxFetchCost {
                backoff.set(true)
                return .unavailable
            }
            if CFAbsoluteTimeGetCurrent() >= deadline { return .unchanged }
        }
    }

    private static func pollForChangeAsync(
        from preHash: UInt64,
        config: Config,
        fetch: () async throws -> [[String: Any]]
    ) async -> ChangePoll {
        let deadline = CFAbsoluteTimeGetCurrent() + config.retryDeadline
        var lastCost: TimeInterval = 0
        var first = true
        while true {
            if !first {
                await sleepRemainderAsync(of: config.pollInterval, spent: lastCost)
            }
            first = false
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let tree = try? await fetch() else { return .unavailable }
            lastCost = CFAbsoluteTimeGetCurrent() - t0
            if treeHash(tree) != preHash { return .changed }
            if lastCost > config.maxFetchCost {
                backoff.set(true)
                return .unavailable
            }
            if CFAbsoluteTimeGetCurrent() >= deadline { return .unchanged }
        }
    }

    /// Duerme `interval - spent`: las muestras quedan espaciadas `interval`
    /// de reloj de pared sin sumar el sleep completo encima del fetch.
    private static func sleepRemainder(of interval: TimeInterval, spent: TimeInterval) {
        let remainder = interval - spent
        if remainder > 0 {
            usleep(useconds_t(remainder * 1_000_000))
        }
    }

    private static func sleepRemainderAsync(of interval: TimeInterval, spent: TimeInterval) async {
        let remainder = interval - spent
        if remainder > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remainder * 1_000_000_000))
        }
    }

    private static func warnNoChange(_ target: String, retried: Bool) {
        let attempts = retried
            ? "tras 2 intentos de tap"
            : "tras el tap"
        FileHandle.standardError.write(Data(
            "[tap] warning: la UI no cambió \(attempts) en '\(target)' — puede ser un tap legítimo sin efecto visible en el árbol (keypads, toggles internos), o el tap no está llegando al elemento\n".utf8
        ))
    }
}
