use std::process::Command;
use std::path::PathBuf;
use serde_json::Value;

fn auto_binary() -> PathBuf {
    // Look for auto binary: next to the editor, in parent dir, or in PATH
    let candidates = [
        std::env::current_exe().ok().and_then(|p| p.parent().map(|d| d.join("auto"))),
        std::env::current_dir().ok().map(|d| d.join("auto")),
        std::env::current_dir().ok().map(|d| d.join("../auto")),
        Some(PathBuf::from("/Users/franciscojaviersaldivarrubio/Documents/AutomationApp/auto")),
    ];
    for c in candidates.iter().flatten() {
        if c.exists() { return c.clone(); }
    }
    PathBuf::from("auto") // fallback to PATH
}

#[tauri::command]
fn run_auto(args: Vec<String>) -> Result<String, String> {
    let bin = auto_binary();
    let output = Command::new(&bin)
        .args(&args)
        .output()
        .map_err(|e| format!("Failed to run {}: {}", bin.display(), e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(stdout)
    } else {
        Err(format!("{}{}", stdout, stderr))
    }
}

#[tauri::command]
fn get_ax_tree() -> Result<Value, String> {
    let bin = auto_binary();
    let output = Command::new(&bin)
        .args(["tree"])
        .output()
        .map_err(|e| format!("Failed to get tree: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();

    // Parse tree output into structured elements
    // Format: "  AXButton  label="Login"  id=loginBtn  [100,200 50x30]"
    let mut elements: Vec<Value> = Vec::new();
    let mut labels: Vec<String> = Vec::new();

    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('(') { continue; }

        let depth = line.len() - line.trim_start().len();
        let mut role = String::new();
        let mut label = String::new();
        let mut id = String::new();
        let mut value = String::new();
        let mut frame = String::new();

        // Extract role (first word starting with AX)
        if let Some(ax_start) = trimmed.find("AX") {
            let rest = &trimmed[ax_start..];
            role = rest.split_whitespace().next().unwrap_or("").to_string();
        }

        // Extract quoted strings after keywords
        if let Some(i) = trimmed.find("label=\"") {
            let start = i + 7;
            if let Some(end) = trimmed[start..].find('"') {
                label = trimmed[start..start+end].to_string();
            }
        }
        if label.is_empty() {
            // Try title (quoted string right after role)
            if let Some(i) = trimmed.find("\"") {
                let start = i + 1;
                if let Some(end) = trimmed[start..].find('"') {
                    let candidate = &trimmed[start..start+end];
                    if !candidate.contains('=') {
                        label = candidate.to_string();
                    }
                }
            }
        }
        if let Some(i) = trimmed.find("id=") {
            let start = i + 3;
            let rest = &trimmed[start..];
            id = rest.split_whitespace().next().unwrap_or("").to_string();
        }
        if let Some(i) = trimmed.find("value=\"") {
            let start = i + 7;
            if let Some(end) = trimmed[start..].find('"') {
                value = trimmed[start..start+end].to_string();
            }
        }
        if let Some(i) = trimmed.find('[') {
            if let Some(end) = trimmed[i..].find(']') {
                frame = trimmed[i..i+end+1].to_string();
            }
        }

        let display = if !label.is_empty() { label.clone() }
            else if !id.is_empty() { id.clone() }
            else if !value.is_empty() { value.clone() }
            else { role.clone() };

        if !display.is_empty() && display != role {
            labels.push(display.clone());
        }

        if !role.is_empty() {
            elements.push(serde_json::json!({
                "role": role,
                "label": label,
                "id": id,
                "value": value,
                "frame": frame,
                "depth": depth / 2,
                "display": display,
            }));
        }
    }

    labels.sort();
    labels.dedup();

    Ok(serde_json::json!({
        "raw": stdout,
        "elements": elements,
        "labels": labels
    }))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![run_auto, get_ax_tree])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
