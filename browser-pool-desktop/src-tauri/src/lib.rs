use std::path::PathBuf;
use std::process::Command;

fn cli_path() -> PathBuf {
    // CARGO_MANIFEST_DIR = .../browser-pool-desktop/src-tauri
    // CLI is at ../../bin/browser-pool
    let manifest_dir = env!("CARGO_MANIFEST_DIR");
    PathBuf::from(manifest_dir)
        .join("../../bin/browser-pool")
        .canonicalize()
        .unwrap_or_else(|_| PathBuf::from("browser-pool"))
}

fn run_cli(args: &[&str]) -> Result<String, String> {
    let output = Command::new(cli_path())
        .args(args)
        .env("BROWSER_POOL_QUIET", "1")
        .output()
        .map_err(|e| format!("Failed to execute CLI: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(format!("{}{}", stderr, stdout))
    } else {
        Err(format!("{}{}", stderr, stdout))
    }
}

#[tauri::command]
fn pool_status() -> Result<String, String> {
    // Don't suppress output for status
    let output = Command::new(cli_path())
        .args(&["status"])
        .output()
        .map_err(|e| format!("Failed to execute CLI: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(stdout)
    } else {
        Err(format!("{}{}", stderr, stdout))
    }
}

#[tauri::command]
fn pool_acquire(
    project: String,
    network: Option<String>,
    mount: Option<String>,
    timeout: Option<u32>,
) -> Result<String, String> {
    let mut args: Vec<String> = vec!["acquire".into(), "--project".into(), project];
    if let Some(n) = network {
        if !n.is_empty() {
            args.push("--network".into());
            args.push(n);
        }
    }
    if let Some(m) = mount {
        if !m.is_empty() {
            args.push("--mount".into());
            args.push(m);
        }
    }
    if let Some(t) = timeout {
        args.push("--timeout".into());
        args.push(t.to_string());
    }
    let arg_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();

    let output = Command::new(cli_path())
        .args(&arg_refs)
        .output()
        .map_err(|e| format!("Failed to execute CLI: {}", e))?;

    if output.status.success() {
        // stdout has the JSON result
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        Ok(stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        Err(format!("{}{}", stderr, stdout))
    }
}

#[tauri::command]
fn pool_list_leases() -> Result<String, String> {
    let output = Command::new(cli_path())
        .args(&["list-leases"])
        .env("BROWSER_POOL_QUIET", "1")
        .output()
        .map_err(|e| format!("Failed to execute CLI: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();

    if output.status.success() {
        Ok(stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        Err(format!("{}{}", stderr, stdout))
    }
}

#[tauri::command]
fn pool_list_containers() -> Result<String, String> {
    let output = Command::new(cli_path())
        .args(&["list-containers"])
        .env("BROWSER_POOL_QUIET", "1")
        .output()
        .map_err(|e| format!("Failed to execute CLI: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();

    if output.status.success() {
        Ok(stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        Err(format!("{}{}", stderr, stdout))
    }
}

#[tauri::command]
fn pool_release(lease_id: String) -> Result<String, String> {
    run_cli(&["release", &lease_id])
}

#[tauri::command]
fn pool_gc(max_idle: Option<u32>) -> Result<String, String> {
    match max_idle {
        Some(val) => run_cli(&["gc", "--max-idle", &val.to_string()]),
        None => run_cli(&["gc"]),
    }
}

#[tauri::command]
fn pool_destroy_all() -> Result<String, String> {
    run_cli(&["destroy-all"])
}

#[tauri::command]
fn pool_build() -> Result<String, String> {
    let output = Command::new(cli_path())
        .args(&["build"])
        .output()
        .map_err(|e| format!("Failed to execute CLI: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&output.stderr).to_string();

    if output.status.success() {
        Ok(format!("{}{}", stderr, stdout))
    } else {
        Err(format!("{}{}", stderr, stdout))
    }
}

#[tauri::command]
fn pool_config() -> Result<String, String> {
    let output = Command::new(cli_path())
        .args(&["config"])
        .output()
        .map_err(|e| format!("Failed to execute CLI: {}", e))?;

    let stdout = String::from_utf8_lossy(&output.stdout).to_string();

    if output.status.success() {
        Ok(stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        Err(format!("{}{}", stderr, stdout))
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            pool_status,
            pool_acquire,
            pool_list_leases,
            pool_list_containers,
            pool_release,
            pool_gc,
            pool_destroy_all,
            pool_build,
            pool_config,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
