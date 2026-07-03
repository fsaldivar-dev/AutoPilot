import Foundation
import CoreGraphics

// MARK: - Gesture Classification (#91)

/// Un punto de la trayectoria de un gesto: posición en pantalla + timestamp.
public struct GesturePoint: Equatable {
    public let location: CGPoint
    public let timestamp: CFAbsoluteTime

    public init(location: CGPoint, timestamp: CFAbsoluteTime) {
        self.location = location
        self.timestamp = timestamp
    }
}

/// Dirección de un swipe/scroll, en términos del movimiento del puntero.
/// `up` = el puntero se movió hacia arriba (coordenadas de pantalla macOS:
/// y crece hacia abajo, así que dy negativo = up). Coincide con la semántica
/// de `swipe up` en `SimulatorBridge.swipe`: drag de abajo hacia arriba.
public enum SwipeDirection: String, Equatable {
    case up, down, left, right
}

/// Resultado de clasificar una trayectoria down→(drags)→up.
public enum ClassifiedGesture: Equatable {
    case tap
    case longPress(duration: CFAbsoluteTime)
    case swipe(direction: SwipeDirection)
    case drag(from: CGPoint, to: CGPoint)
}

/// Clasificador puro de gestos del recorder iOS (#91).
///
/// Antes de esto, `RecordingSession` decidía tap vs longPress mirando solo
/// la duración down→up e ignoraba por completo los `mouseDragged`: un drag
/// del usuario se grababa como `tap` en el punto de origen (o se perdía la
/// intención de scroll). Este clasificador recibe la trayectoria completa
/// (secuencia de puntos + timestamps) y decide qué gesto fue.
///
/// **Reglas (en orden):**
/// 1. Desplazamiento neto < `tapMaxDistance` (~10px):
///    - duración >= `longPressMinDuration` (0.5s) → `longPress`
///    - si no → `tap`
/// 2. Desplazamiento neto >= umbral:
///    - trayectoria mayormente vertical u horizontal (eje dominante >=
///      `axisDominanceRatio`× el otro), razonablemente recta (longitud de
///      camino <= `maxWanderRatio`× el desplazamiento neto) y rápida
///      (velocidad neta >= `swipeMinVelocity`) → `swipe` con dirección
///    - cualquier otro movimiento (diagonal, lento, o serpenteante) →
///      `drag(from:to:)`
///
/// Función PURA: sin CGEvent, sin AX, sin estado. Testeable con
/// trayectorias sintéticas (ver GestureClassifierTests).
public enum GestureClassifier {

    /// Umbrales de clasificación. Valores por default elegidos para la
    /// ventana del Simulator (px de pantalla macOS, no pt de device):
    /// - `tapMaxDistance` 10px: el temblor natural de un click humano queda
    ///   por debajo; cualquier arrastre intencional lo supera.
    /// - `longPressMinDuration` 0.5s: mismo umbral que usaba el recorder
    ///   antes de #91 (y que usa el recorder Android).
    /// - `swipeMinVelocity` 500 px/s: el issue #91 sugiere >800pt/s en
    ///   coordenadas de device; la ventana del Simulator suele renderizar
    ///   a ~40-60% del tamaño físico, así que 500px/s en ventana ≈ un
    ///   flick inercial real. Un drag deliberado (slider, reorder) va
    ///   muy por debajo.
    /// - `axisDominanceRatio` 2.0: el eje dominante debe doblar al otro
    ///   para considerarse scroll direccional; un 45° nunca es scroll.
    /// - `maxWanderRatio` 1.4: camino recorrido / desplazamiento neto.
    ///   Una línea recta da 1.0; un drag serpenteante (drag libre) supera
    ///   1.4 aunque termine alineado a un eje.
    public struct Thresholds {
        public var tapMaxDistance: CGFloat = 10
        public var longPressMinDuration: CFAbsoluteTime = 0.5
        public var swipeMinVelocity: Double = 500
        public var axisDominanceRatio: CGFloat = 2.0
        public var maxWanderRatio: CGFloat = 1.4

        public init() {}
    }

    /// Clasifica una trayectoria completa down→up.
    /// - Parameter points: secuencia ordenada de puntos; el primero es el
    ///   mouseDown, el último el mouseUp, los intermedios son mouseDragged.
    /// - Returns: el gesto clasificado, o `nil` si la trayectoria está vacía.
    public static func classify(
        points: [GesturePoint],
        thresholds: Thresholds = Thresholds()
    ) -> ClassifiedGesture? {
        guard let first = points.first, let last = points.last else { return nil }

        let dx = last.location.x - first.location.x
        let dy = last.location.y - first.location.y
        let netDistance = hypot(dx, dy)
        let duration = max(last.timestamp - first.timestamp, 0)

        // 1. Sin desplazamiento significativo → tap o longPress por duración
        if netDistance < thresholds.tapMaxDistance {
            if duration >= thresholds.longPressMinDuration {
                return .longPress(duration: duration)
            }
            return .tap
        }

        // 2. Con desplazamiento → swipe (rápido + axial + recto) o drag
        var pathLength: CGFloat = 0
        for i in 1..<points.count {
            pathLength += hypot(
                points[i].location.x - points[i - 1].location.x,
                points[i].location.y - points[i - 1].location.y
            )
        }
        let wander = pathLength / netDistance
        // duration 0 con desplazamiento = instantáneo → velocidad infinita
        let velocity = duration > 0 ? Double(netDistance) / duration : .infinity

        let vertical = abs(dy) >= abs(dx) * thresholds.axisDominanceRatio
        let horizontal = abs(dx) >= abs(dy) * thresholds.axisDominanceRatio
        let straightEnough = wander <= thresholds.maxWanderRatio

        if velocity >= thresholds.swipeMinVelocity && (vertical || horizontal) && straightEnough {
            let direction: SwipeDirection
            if vertical {
                direction = dy < 0 ? .up : .down
            } else {
                direction = dx < 0 ? .left : .right
            }
            return .swipe(direction: direction)
        }

        return .drag(from: first.location, to: last.location)
    }
}
