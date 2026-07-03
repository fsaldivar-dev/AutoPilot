use std::path::PathBuf;
use std::process::Command;
use std::sync::OnceLock;

/// Resuelve la ruta del binario `name`, cacheada por proceso.
///
/// El probing (fs + `which`) es caro y este helper se llama en cada request —
/// incluido el polling de ~200ms del mirror — así que la primera resolución
/// se memoiza en un `OnceLock` por binario conocido.
pub fn find_binary(name: &str) -> PathBuf {
    static AUTO_BIN: OnceLock<PathBuf> = OnceLock::new();
    static AUTO_ANDROID_BIN: OnceLock<PathBuf> = OnceLock::new();

    let cache = match name {
        "auto" => &AUTO_BIN,
        "auto-android" => &AUTO_ANDROID_BIN,
        other => return locate_binary(other),
    };
    if let Some(path) = cache.get() {
        return path.clone();
    }
    let path = locate_binary(name);
    // Solo cachear resoluciones reales (rutas absolutas). El fallback de
    // nombre pelado no se memoiza: si el binario aparece después (p.ej. tras
    // compilar el CLI), la siguiente llamada lo encuentra sin reiniciar.
    if path.is_absolute() {
        let _ = cache.set(path.clone());
    }
    path
}

fn locate_binary(name: &str) -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join(name);
            if candidate.exists() {
                return candidate;
            }
            let triple = match (std::env::consts::ARCH, std::env::consts::OS) {
                ("aarch64", "macos") => "aarch64-apple-darwin",
                ("x86_64", "macos") => "x86_64-apple-darwin",
                _ => "",
            };
            if !triple.is_empty() {
                let candidate = dir.join(format!("{}-{}", name, triple));
                if candidate.exists() {
                    return candidate;
                }
            }
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        for rel in [
            name.to_string(),
            format!("../{}", name),
            format!("../../{}", name),
            format!("../../cli/.build/debug/{}", name),
            format!("../../cli/.build/release/{}", name),
            format!("../cli/.build/debug/{}", name),
            format!("../cli/.build/release/{}", name),
        ] {
            let path = cwd.join(&rel);
            if path.exists() {
                return path;
            }
        }

        for base in ["../../cli/.build", "../cli/.build", "cli/.build"] {
            let build_dir = cwd.join(base);
            if let Ok(entries) = std::fs::read_dir(&build_dir) {
                for entry in entries.flatten() {
                    if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                        for profile in ["debug", "release"] {
                            let candidate = entry.path().join(profile).join(name);
                            if candidate.exists() {
                                return candidate;
                            }
                        }
                    }
                }
            }
        }
    }

    if let Ok(output) = Command::new("which").arg(name).output() {
        if output.status.success() {
            let path_str = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !path_str.is_empty() {
                return PathBuf::from(path_str);
            }
        }
    }

    PathBuf::from(name)
}

pub fn auto_binary(platform: &str) -> PathBuf {
    match platform {
        "android" => find_binary("auto-android"),
        _ => find_binary("auto"),
    }
}

pub fn extended_path() -> String {
    let path = std::env::var("PATH").unwrap_or_default();
    let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/".to_string());
    format!(
        "{path}:/usr/bin:/usr/local/bin:/opt/homebrew/bin:{home}/Library/Android/sdk/platform-tools"
    )
}

pub fn android_home() -> String {
    std::env::var("ANDROID_HOME").unwrap_or_else(|_| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/Users/".to_string());
        format!("{home}/Library/Android/sdk")
    })
}

pub async fn run_cli_async(bin: &PathBuf, args: &[&str]) -> Result<String, String> {
    let bin = bin.clone();
    let args: Vec<String> = args.iter().map(|s| s.to_string()).collect();

    tokio::task::spawn_blocking(move || {
        let refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
        let output = Command::new(&bin)
            .args(&refs)
            .env("PATH", extended_path())
            .env("ANDROID_HOME", android_home())
            .output()
            .map_err(|e| format!("Failed to run {}: {}", bin.display(), e))?;

        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();

        if output.status.success() {
            Ok(stdout)
        } else {
            Err(format!("{}{}", stdout, stderr))
        }
    })
    .await
    .map_err(|e| format!("join error: {}", e))?
}
