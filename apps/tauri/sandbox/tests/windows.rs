#![cfg(windows)]
use std::{fs, net::TcpListener, process::Command};

#[test]
fn appcontainer_impide_leer_datos_ajenos_red_y_subprocesos() {
    let root = tempfile::tempdir().unwrap();
    let secret = root.path().join("secret.txt");
    let vendor = root.path().join("vendor");
    let project = root.path().join("project");
    fs::create_dir(&vendor).unwrap();
    fs::create_dir(&project).unwrap();
    fs::write(&secret, "private synthetic data").unwrap();
    fs::write(vendor.join("package.txt"), "vendor synthetic data").unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    for profile in ["worker", "tool"] {
        let mut command = Command::new(env!("CARGO_BIN_EXE_escriba-sandbox"));
        command.arg(profile);
        if profile == "tool" {
            command
                .arg("--project")
                .arg(&project)
                .arg("--vendor")
                .arg(&vendor);
        }
        let result = command
            .arg("--executable")
            .arg(env!("CARGO_BIN_EXE_sandbox-probe"))
            .arg("--")
            .arg(&secret)
            .arg(project.join("new.txt"))
            .arg(&vendor)
            .arg(listener.local_addr().unwrap().to_string())
            .output()
            .unwrap();
        let output = String::from_utf8_lossy(&result.stdout);
        assert!(result.status.success(), "{profile}: {result:?}");
        assert!(output.contains("read=false"), "{profile}: {output}");
        assert!(output.contains("network=false"), "{profile}: {output}");
        assert!(output.contains("spawn=false"), "{profile}: {output}");
        assert!(output.contains("vendor_write=false"), "{profile}: {output}");
        assert!(
            output.contains(if profile == "worker" {
                "write=false"
            } else {
                "write=true"
            }),
            "{profile}: {output}"
        );
        assert!(
            output.contains(if profile == "worker" {
                "vendor=false"
            } else {
                "vendor=true"
            }),
            "{profile}: {output}"
        );
    }
}
