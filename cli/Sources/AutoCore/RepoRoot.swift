import Foundation

/// Localiza la raiz del repositorio AutoPilot.
///
/// Varios comandos necesitan artefactos que viven dentro del repo
/// (APK del agente, `.so`/`.dex` del camera mock). Resolverlos relativos
/// al cwd rompe cuando el CLI se invoca desde otro directorio, asi que
/// siempre se camina hacia arriba buscando `.git` (funciona tambien en
/// worktrees, donde `.git` es un archivo).
public enum RepoRoot {
    /// Camina desde `startingAt` (default: cwd) hacia `/` buscando `.git`.
    /// Si no encuentra repo, devuelve el directorio de partida como fallback.
    public static func find(startingAt start: String = FileManager.default.currentDirectoryPath) -> String {
        var dir = start
        while dir != "/" {
            if FileManager.default.fileExists(atPath: "\(dir)/.git") {
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return start
    }
}
