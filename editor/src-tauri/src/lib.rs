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

/// Gets the element index ($N) for precise targeting.
#[tauri::command]
fn get_element_index() -> Result<Value, String> {
    let bin = auto_binary();
    let output = Command::new(&bin)
        .args(["index"])
        .output()
        .map_err(|e| format!("Failed to get index: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let mut elements: Vec<Value> = Vec::new();

    for line in stdout.lines() {
        let trimmed = line.trim();
        // Parse: $0    Button       "Inicio"                       [53,762 60x30]
        if !trimmed.starts_with('$') { continue; }

        let parts: Vec<&str> = trimmed.splitn(2, |c: char| c.is_whitespace()).collect();
        if parts.len() < 2 { continue; }

        let idx_str = parts[0].trim_start_matches('$');
        let idx: i64 = idx_str.parse().unwrap_or(-1);
        if idx < 0 { continue; }

        let rest = parts[1].trim();
        // Extract role (first word)
        let role_end = rest.find(|c: char| c.is_whitespace()).unwrap_or(rest.len());
        let role = &rest[..role_end];
        let after_role = rest[role_end..].trim();

        // Extract label (quoted string)
        let mut label = String::new();
        if let Some(q1) = after_role.find('"') {
            if let Some(q2) = after_role[q1+1..].find('"') {
                label = after_role[q1+1..q1+1+q2].to_string();
            }
        }

        // Extract frame [x,y wxh]
        let mut frame = String::new();
        if let Some(b1) = after_role.find('[') {
            if let Some(b2) = after_role[b1..].find(']') {
                frame = after_role[b1..b1+b2+1].to_string();
            }
        }

        elements.push(serde_json::json!({
            "index": idx,
            "role": role,
            "label": label,
            "frame": frame,
        }));
    }

    Ok(serde_json::json!({ "elements": elements }))
}

/// Captures screenshot + AX tree in one call. Returns base64 image + elements.
#[tauri::command]
fn inspect() -> Result<Value, String> {
    let bin = auto_binary();

    // 1. Screenshot to temp file
    let tmp = std::env::temp_dir().join("autopilot-inspect.png");
    let tmp_str = tmp.to_string_lossy().to_string();
    let _ = Command::new(&bin)
        .args(["screenshot", &tmp_str])
        .output()
        .map_err(|e| format!("Screenshot failed: {}", e))?;

    // 2. Read image as base64
    let image_b64 = if tmp.exists() {
        use std::io::Read;
        let mut file = std::fs::File::open(&tmp).map_err(|e| e.to_string())?;
        let mut bytes = Vec::new();
        file.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        use std::fmt::Write;
        let mut b64 = String::new();
        for chunk in bytes.chunks(3) {
            let b = match chunk.len() {
                3 => [chunk[0], chunk[1], chunk[2], 0],
                2 => [chunk[0], chunk[1], 0, 0],
                1 => [chunk[0], 0, 0, 0],
                _ => [0, 0, 0, 0],
            };
            let n = ((b[0] as u32) << 16) | ((b[1] as u32) << 8) | (b[2] as u32);
            const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
            let _ = write!(b64, "{}{}", T[(n >> 18 & 63) as usize] as char, T[(n >> 12 & 63) as usize] as char);
            if chunk.len() > 1 { let _ = write!(b64, "{}", T[(n >> 6 & 63) as usize] as char); } else { b64.push('='); }
            if chunk.len() > 2 { let _ = write!(b64, "{}", T[(n & 63) as usize] as char); } else { b64.push('='); }
        }
        let _ = std::fs::remove_file(&tmp);
        b64
    } else {
        String::new()
    };

    // 3. Get tree + index
    let tree_result = get_ax_tree()?;
    let index_result = get_element_index()?;

    Ok(serde_json::json!({
        "screenshot": format!("data:image/png;base64,{}", image_b64),
        "elements": tree_result["elements"],
        "labels": tree_result["labels"],
        "indexed": index_result["elements"],
    }))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![run_auto, get_ax_tree, get_element_index, inspect])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
