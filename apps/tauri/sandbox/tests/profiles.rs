#![cfg(target_os = "linux")]
//! Each profile against the real kernel, with bash as the confined program:
//! its builtins read, write and connect without starting other processes.

use std::{
    net::TcpListener,
    path::Path,
    process::{Command, Output},
};

const BASH: &str = "/usr/bin/bash";

fn run(profile: &[&str], script: &str) -> Output {
    let mut arguments: Vec<&str> = profile.to_vec();
    arguments.extend(["--executable", BASH, "--", "--norc", "-c", script]);
    Command::new(env!("CARGO_BIN_EXE_escriba-sandbox"))
        .args(arguments)
        .env_clear()
        .current_dir("/")
        .output()
        .unwrap()
}

fn stdout(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout).into_owned()
}

fn listening() -> (TcpListener, u16) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    (listener, port)
}

#[test]
fn el_equipo_permite_aislar() {
    let output = Command::new(env!("CARGO_BIN_EXE_escriba-sandbox"))
        .arg("--check")
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(stdout(&output).starts_with("landlock "));
}

#[test]
fn una_receta_no_lee_ni_escribe_archivos_ni_se_conecta_ni_crea_procesos() {
    let folder = tempfile::tempdir().unwrap();
    let secret = folder.path().join("privado.txt");
    std::fs::write(&secret, "solo para prueba\n").unwrap();
    let (_server, port) = listening();
    let script = format!(
        "read -r x < {secret}; echo leer=$?; echo y > {written}; echo escribir=$?; \
         (exec 3<>/dev/tcp/127.0.0.1/{port}) 2>/dev/null; echo red=$?; echo fin",
        secret = secret.display(),
        written = folder.path().join("nuevo.txt").display(),
    );
    let output = run(&["worker"], &script);
    let printed = stdout(&output);
    assert!(printed.contains("leer=1"), "{printed}");
    assert!(printed.contains("escribir=1"), "{printed}");
    assert!(!folder.path().join("nuevo.txt").exists());
    assert!(
        !printed.contains("fin"),
        "un subshell no debería poder crearse: {printed}"
    );
    let alone = run(
        &["worker"],
        &format!("exec 3<>/dev/tcp/127.0.0.1/{port} && echo conectado"),
    );
    assert!(!stdout(&alone).contains("conectado"), "{alone:?}");
    let spawned = run(&["worker"], "/usr/bin/true; echo creado");
    assert!(!stdout(&spawned).contains("creado"), "{spawned:?}");
}

#[test]
fn una_herramienta_escribe_en_su_proyecto_lee_vendor_y_nada_mas() {
    let base = tempfile::tempdir().unwrap();
    let (project, vendor, outside) = (
        base.path().join("proyecto"),
        base.path().join("vendor"),
        base.path().join("fuera.txt"),
    );
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&vendor).unwrap();
    std::fs::write(vendor.join("paquete.js"), "export {}\n").unwrap();
    std::fs::write(&outside, "fuera\n").unwrap();
    let (_server, port) = listening();
    let profile = |name| {
        vec![
            name,
            "--project",
            project.to_str().unwrap(),
            "--vendor",
            vendor.to_str().unwrap(),
        ]
    };
    let script = format!(
        "echo hecho > {project}/dist.js; echo escribir=$?; read -r x < {vendor}/paquete.js; echo vendor=$?; \
         echo y > {vendor}/otro.js; echo escribir_vendor=$?; read -r x < {outside}; echo fuera=$?; \
         exec 3<>/dev/tcp/127.0.0.1/{port} && echo conectado",
        project = project.display(),
        vendor = vendor.display(),
        outside = outside.display(),
    );
    let tool = stdout(&run(&profile("tool"), &script));
    assert!(tool.contains("escribir=0"), "{tool}");
    assert!(tool.contains("vendor=0"), "{tool}");
    assert!(tool.contains("escribir_vendor=1"), "{tool}");
    assert!(tool.contains("fuera=1"), "{tool}");
    assert!(!tool.contains("conectado"), "{tool}");
    assert!(Path::new(&project.join("dist.js")).exists());
    let install = stdout(&run(&profile("install"), &script));
    assert!(install.contains("fuera=1"), "{install}");
    assert!(
        install.contains("conectado"),
        "instalar sí sale a la red: {install}"
    );
}
