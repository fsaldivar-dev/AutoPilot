use std::process::Command;
use std::path::PathBuf;
use serde_json::Value;

fn find_binary(name: &str) -> PathBuf {
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join(name);
            if candidate.exists() { return candidate; }
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        for path in [
            cwd.join(name),
            cwd.join(format!("../{}", name)),
            cwd.join(format!("../../{}", name)),
            cwd.join(format!("../../cli/.build/debug/{}", name)),
            cwd.join(format!("../../cli/.build/release/{}", name)),
            cwd.join(format!("../cli/.build/debug/{}", name)),
            cwd.join(format!("../cli/.build/release/{}", name)),
        ] {
            if path.exists() { return path; }
        }
    }

    PathBuf::from(name)
}

fn auto_binary(platform: &str) -> PathBuf {
    match platform {
        "android" => find_binary("auto-android"),
        _ => find_binary("auto"),
    }
}

/// Run a CLI command and return stdout
fn run_cli(bin: &PathBuf, args: &[&str]) -> Result<String, String> {
    let output = Command::new(bin)
        .args(args)
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
fn run_auto(args: Vec<String>, platform: Option<String>) -> Result<String, String> {
    let plat = platform.as_deref().unwrap_or("ios");
    let bin = auto_binary(plat);
    let args_ref: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
    run_cli(&bin, &args_ref)
}

/// Parse tree output into structured elements (works for both iOS and Android)
fn parse_tree_output(stdout: &str) -> (Vec<Value>, Vec<String>) {
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

        if let Some(first_word) = trimmed.split_whitespace().next() {
            role = first_word.to_string();
        }

        if let Some(i) = trimmed.find("label=\"") {
            let start = i + 7;
            if let Some(end) = trimmed[start..].find('"') {
                label = trimmed[start..start+end].to_string();
            }
        }
        if label.is_empty() {
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
    (elements, labels)
}

/// Build indexed element list from parsed tree elements.
/// For Android: resolves generic "View" nodes by looking at their child text.
fn index_from_tree(elements: &[Value]) -> Vec<Value> {
    let mut indexed: Vec<Value> = Vec::new();
    let mut idx: i64 = 0;

    for el in elements {
        let role = el["role"].as_str().unwrap_or("");
        let label = el["label"].as_str().unwrap_or("");
        let frame = el["frame"].as_str().unwrap_or("");
        let depth = el["depth"].as_i64().unwrap_or(0);

        // Skip pure containers with no useful info at depth 0-1
        if depth <= 1 && label.is_empty() && matches!(role, "FrameLayout" | "LinearLayout") {
            continue;
        }

        // For "View" or "Button" without a label, look at sibling/neighbor context
        // The display field already has the best label from parse_tree_output
        let display = el["display"].as_str().unwrap_or("");

        let effective_label = if !label.is_empty() {
            label.to_string()
        } else if !display.is_empty() && display != role {
            display.to_string()
        } else {
            // Skip elements with no useful identifier
            continue;
        };

        indexed.push(serde_json::json!({
            "index": idx,
            "role": role,
            "label": effective_label,
            "frame": frame,
        }));
        idx += 1;
    }

    indexed
}

#[tauri::command]
fn get_ax_tree(platform: Option<String>) -> Result<Value, String> {
    let plat = platform.as_deref().unwrap_or("ios");
    let bin = auto_binary(plat);
    let stdout = run_cli(&bin, &["tree"])?;
    let (elements, labels) = parse_tree_output(&stdout);

    Ok(serde_json::json!({
        "raw": stdout,
        "elements": elements,
        "labels": labels
    }))
}

#[tauri::command]
fn get_element_index(platform: Option<String>) -> Result<Value, String> {
    let plat = platform.as_deref().unwrap_or("ios");

    if plat == "android" {
        // Generate index from tree — flatten elements and resolve generic Views
        let bin = auto_binary(plat);
        let stdout = run_cli(&bin, &["tree"]).unwrap_or_default();
        let (elements, _) = parse_tree_output(&stdout);
        return Ok(serde_json::json!({ "elements": index_from_tree(&elements) }));
    }

    let bin = auto_binary(plat);
    let stdout = run_cli(&bin, &["index"]).unwrap_or_default();
    let mut elements: Vec<Value> = Vec::new();

    for line in stdout.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with('$') { continue; }

        let parts: Vec<&str> = trimmed.splitn(2, |c: char| c.is_whitespace()).collect();
        if parts.len() < 2 { continue; }

        let idx_str = parts[0].trim_start_matches('$');
        let idx: i64 = idx_str.parse().unwrap_or(-1);
        if idx < 0 { continue; }

        let rest = parts[1].trim();
        let role_end = rest.find(|c: char| c.is_whitespace()).unwrap_or(rest.len());
        let role = &rest[..role_end];
        let after_role = rest[role_end..].trim();

        let mut label = String::new();
        if let Some(q1) = after_role.find('"') {
            if let Some(q2) = after_role[q1+1..].find('"') {
                label = after_role[q1+1..q1+1+q2].to_string();
            }
        }

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

/// Take screenshot and return base64
fn take_screenshot(bin: &PathBuf) -> String {
    let tmp = std::env::temp_dir().join("autopilot-inspect.png");
    let tmp_str = tmp.to_string_lossy().to_string();

    let _ = Command::new(bin)
        .args(["screenshot", &tmp_str])
        .output();

    if tmp.exists() {
        use std::io::Read;
        if let Ok(mut file) = std::fs::File::open(&tmp) {
            let mut bytes = Vec::new();
            if file.read_to_end(&mut bytes).is_ok() && !bytes.is_empty() {
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
                return b64;
            }
        }
    }
    String::new()
}

/// Captures screenshot + tree in one call — screenshot and tree run in parallel.
#[tauri::command]
fn inspect(platform: Option<String>) -> Result<Value, String> {
    let plat = platform.as_deref().unwrap_or("ios");
    let bin = auto_binary(plat);

    // Run screenshot and tree in parallel
    let bin_screenshot = bin.clone();
    let screenshot_thread = std::thread::spawn(move || {
        take_screenshot(&bin_screenshot)
    });

    let bin_tree = bin.clone();
    let tree_thread = std::thread::spawn(move || -> Result<(Vec<Value>, Vec<String>), String> {
        let stdout = run_cli(&bin_tree, &["tree"])?;
        Ok(parse_tree_output(&stdout))
    });

    // Collect results
    let image_b64 = screenshot_thread.join().unwrap_or_default();
    let (elements, labels) = tree_thread.join()
        .map_err(|_| "Tree thread panicked".to_string())?
        .map_err(|e| format!("Tree failed: {}", e))?;

    // Index: for Android, generate from tree; for iOS, call `auto index`
    let index_elements = if plat == "android" {
        index_from_tree(&elements)
    } else {
        let index_result = get_element_index(Some(plat.to_string()))?;
        index_result["elements"].as_array().cloned().unwrap_or_default()
    };

    Ok(serde_json::json!({
        "screenshot": format!("data:image/png;base64,{}", image_b64),
        "elements": elements,
        "labels": labels,
        "indexed": index_elements,
    }))
}

#[tauri::command]
fn open_screenshots() -> Result<String, String> {
    let dir = std::env::current_dir()
        .unwrap_or_default()
        .join("screenshots");
    let _ = std::fs::create_dir_all(&dir);
    Command::new("open")
        .arg(&dir)
        .spawn()
        .map_err(|e| format!("Failed to open: {}", e))?;
    Ok(dir.to_string_lossy().to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![run_auto, get_ax_tree, get_element_index, inspect, open_screenshots])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
