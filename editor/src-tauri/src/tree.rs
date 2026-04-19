use serde_json::Value;

pub fn parse_tree_output(stdout: &str) -> (Vec<Value>, Vec<String>) {
    let mut elements: Vec<Value> = Vec::new();
    let mut labels: Vec<String> = Vec::new();

    for line in stdout.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('(') {
            continue;
        }

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
                label = trimmed[start..start + end].to_string();
            }
        }
        if label.is_empty() {
            if let Some(i) = trimmed.find('"') {
                let start = i + 1;
                if let Some(end) = trimmed[start..].find('"') {
                    let candidate = &trimmed[start..start + end];
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
                value = trimmed[start..start + end].to_string();
            }
        }
        if let Some(i) = trimmed.find('[') {
            if let Some(end) = trimmed[i..].find(']') {
                frame = trimmed[i..i + end + 1].to_string();
            }
        }

        let display = if !label.is_empty() {
            label.clone()
        } else if !id.is_empty() {
            id.clone()
        } else if !value.is_empty() {
            value.clone()
        } else {
            role.clone()
        };

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

pub fn index_from_tree(elements: &[Value]) -> Vec<Value> {
    let mut indexed: Vec<Value> = Vec::new();
    let mut idx: i64 = 0;

    for el in elements {
        let role = el["role"].as_str().unwrap_or("");
        let label = el["label"].as_str().unwrap_or("");
        let frame = el["frame"].as_str().unwrap_or("");
        let depth = el["depth"].as_i64().unwrap_or(0);

        if depth <= 1 && label.is_empty() && matches!(role, "FrameLayout" | "LinearLayout") {
            continue;
        }

        let display = el["display"].as_str().unwrap_or("");

        let effective_label = if !label.is_empty() {
            label.to_string()
        } else if !display.is_empty() && display != role {
            display.to_string()
        } else {
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

pub fn parse_index_output(stdout: &str) -> Vec<Value> {
    let mut elements: Vec<Value> = Vec::new();
    for line in stdout.lines() {
        let trimmed = line.trim();
        if !trimmed.starts_with('$') {
            continue;
        }
        let parts: Vec<&str> = trimmed.splitn(2, |c: char| c.is_whitespace()).collect();
        if parts.len() < 2 {
            continue;
        }
        let idx_str = parts[0].trim_start_matches('$');
        let idx: i64 = idx_str.parse().unwrap_or(-1);
        if idx < 0 {
            continue;
        }
        let rest = parts[1].trim();
        let role_end = rest.find(|c: char| c.is_whitespace()).unwrap_or(rest.len());
        let role = &rest[..role_end];
        let after_role = rest[role_end..].trim();

        let mut label = String::new();
        if let Some(q1) = after_role.find('"') {
            if let Some(q2) = after_role[q1 + 1..].find('"') {
                label = after_role[q1 + 1..q1 + 1 + q2].to_string();
            }
        }

        let mut frame = String::new();
        if let Some(b1) = after_role.find('[') {
            if let Some(b2) = after_role[b1..].find(']') {
                frame = after_role[b1..b1 + b2 + 1].to_string();
            }
        }

        elements.push(serde_json::json!({
            "index": idx,
            "role": role,
            "label": label,
            "frame": frame,
        }));
    }
    elements
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_empty_tree() {
        let (els, labels) = parse_tree_output("");
        assert!(els.is_empty());
        assert!(labels.is_empty());
    }

    #[test]
    fn parses_single_element() {
        let input = r#"AXButton label="Sign in" [100,200 50x30]"#;
        let (els, labels) = parse_tree_output(input);
        assert_eq!(els.len(), 1);
        assert_eq!(els[0]["label"], "Sign in");
        assert_eq!(els[0]["role"], "AXButton");
        assert_eq!(labels, vec!["Sign in"]);
    }

    #[test]
    fn index_skips_containers_without_labels() {
        let els = vec![
            serde_json::json!({ "role": "FrameLayout", "label": "", "display": "", "frame": "", "depth": 0 }),
            serde_json::json!({ "role": "Button", "label": "Login", "display": "Login", "frame": "[0,0 10x10]", "depth": 2 }),
        ];
        let idx = index_from_tree(&els);
        assert_eq!(idx.len(), 1);
        assert_eq!(idx[0]["label"], "Login");
    }

    #[test]
    fn parses_index_output_basic() {
        let input = r#"$0 AXButton "Sign in" [100,200 50x30]
$1 AXTextField "Email" [100,250 200x30]"#;
        let els = parse_index_output(input);
        assert_eq!(els.len(), 2);
        assert_eq!(els[0]["index"], 0);
        assert_eq!(els[0]["role"], "AXButton");
        assert_eq!(els[0]["label"], "Sign in");
        assert_eq!(els[1]["index"], 1);
        assert_eq!(els[1]["label"], "Email");
    }
}
