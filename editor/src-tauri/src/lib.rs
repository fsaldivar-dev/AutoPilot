use std::process::Command;
use serde_json::Value;

#[tauri::command]
fn run_auto(args: Vec<String>) -> Result<String, String> {
    let output = Command::new("./auto")
        .args(&args)
        .output()
        .map_err(|e| format!("Failed to run auto: {}", e))?;

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
    let output = Command::new("./auto")
        .args(["tree"])
        .output()
        .map_err(|e| format!("Failed to get tree: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();

    // Parse tree output into labels for autocomplete
    let mut elements: Vec<String> = Vec::new();
    for line in stdout.lines() {
        // Extract quoted strings (labels, titles, ids)
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '"' {
                let mut s = String::new();
                while let Some(&nc) = chars.peek() {
                    chars.next();
                    if nc == '"' { break; }
                    s.push(nc);
                }
                if !s.is_empty() {
                    elements.push(s);
                }
            }
        }
    }

    elements.sort();
    elements.dedup();

    Ok(serde_json::json!({
        "raw": stdout,
        "elements": elements
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
