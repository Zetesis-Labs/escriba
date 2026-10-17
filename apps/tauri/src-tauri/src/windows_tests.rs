use crate::{capabilities, file_security, native, platform, project};
use serde_json::json;
use std::{fs, process::Command};

#[test]
fn windows_no_ofrece_llm_apple_y_usa_modelos_whisper_locales() {
    let current = platform::summary();
    assert_eq!(current["bundledLlm"], false);
    assert_eq!(current["voiceMemos"], false);
    assert_eq!(platform::PLATFORM.default_whisper_model, "large-v3-turbo");
    assert_eq!(
        platform::surreal_native().1,
        "surrealdb-node.win32-x64-msvc.node"
    );
}

#[test]
fn edicion_preserva_cambios_ajenos_y_rechaza_rutas_windows_peligrosas() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().canonicalize().unwrap();
    project::write_checked(&path, "src/receta.ts", "original", None, true).unwrap();
    assert!(project::write_checked(&path, "src/receta.ts", "otra", None, true).is_err());
    assert!(
        project::write_checked(&path, "src/receta.ts", "otra", Some("obsoleta"), false).is_err()
    );
    assert_eq!(
        project::read(&path, "src/receta.ts").unwrap()["source"],
        "original"
    );
    project::write_checked(
        &path,
        "src/receta.ts",
        "actualizada",
        Some("original"),
        false,
    )
    .unwrap();
    for entry in [
        "../fuera.ts",
        "C:/fuera.ts",
        "receta.ts:oculto",
        "src\\fuera.ts",
        "NUL.ts",
        "src./fuera.ts",
    ] {
        assert!(
            project::write_checked(&path, entry, "no", None, false).is_err(),
            "{entry}"
        );
    }
}

#[test]
fn una_union_de_directorios_no_permite_escapar_del_proyecto() {
    let root = tempfile::tempdir().unwrap();
    let outside = tempfile::tempdir().unwrap();
    fs::write(outside.path().join("secret.ts"), "private synthetic").unwrap();
    let junction = root.path().join("escape");
    let output = Command::new("cmd.exe")
        .args(["/d", "/c", "mklink", "/J"])
        .arg(&junction)
        .arg(outside.path())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    assert!(project::read(root.path(), "escape/secret.ts").is_err());
    assert!(project::write_checked(root.path(), "escape/new.ts", "no", None, false).is_err());
    assert!(!outside.path().join("new.ts").exists());
    fs::remove_dir(junction).unwrap();
}

#[test]
fn conector_de_archivos_conserva_cas_y_publica_solo_en_su_carpeta() {
    let root = tempfile::tempdir().unwrap();
    let account = json!({"enabled":true,"folder":root.path(),"provider":"okf"});
    capabilities::files(&account, &json!({"operation":"apply","changes":[{"path":"notas/prueba.md","contents":"primera","expectedContents":null}]})).unwrap();
    assert_eq!(
        capabilities::files(&account, &json!({"operation":"snapshot"})).unwrap()["notas/prueba.md"],
        "primera"
    );
    assert!(capabilities::files(&account, &json!({"operation":"apply","changes":[{"path":"notas/prueba.md","contents":"otra","expectedContents":"obsoleta"}]})).is_err());
    assert!(capabilities::files(
        &account,
        &json!({"operation":"apply","changes":[{"path":"C:/escape.md","contents":"no"}]})
    )
    .is_err());
}

#[test]
fn carpeta_privada_permite_reabrir_y_escritura_atomica() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("private");
    file_security::protect_directory(&path).unwrap();
    let file = path.join("state.json");
    crate::util::atomic_write(&file, b"first").unwrap();
    crate::util::atomic_write(&file, b"second").unwrap();
    assert_eq!(fs::read(file).unwrap(), b"second");
}

#[tokio::test]
async fn host_instalado_responde_y_se_recupera_tras_cancelar() {
    let host = native::Native::new(native::binary("EscribaNativeHost").unwrap());
    let status = host.call("status", json!({})).await.unwrap();
    assert_eq!(status["protocolVersion"], 1);
    assert_eq!(status["llm"]["available"], false);
    host.cancel();
    assert_eq!(
        host.call("status", json!({})).await.unwrap()["protocolVersion"],
        1
    );
}

#[test]
fn proyecto_windows_instala_comprueba_y_construye_con_herramientas_incluidas() {
    let root = tempfile::tempdir().unwrap();
    let project_path = root.path().join("Proyecto con espacios y 100%");
    let vendor = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("vendor");
    let tools = root.path().join("Herramientas ñ 100%");
    fs::create_dir(&tools).unwrap();
    let runtime = tools.join("escriba-runtime.exe");
    fs::copy(native::binary("escriba-runtime").unwrap(), &runtime).unwrap();
    project::initialize(&project_path, &json!([]), &vendor, &runtime).unwrap();
    assert!(project_path.join("escriba.cmd").is_file());
    fs::write(
        project_path.join("src/smoke.test.ts"),
        r#"import { test, expect } from "bun:test";
import { z } from "zod";
test("las dependencias incluidas funcionan", () => {
  expect(z.string().parse("prueba sintética")).toBe("prueba sintética");
});
"#,
    )
    .unwrap();
    for tool in ["install", "check", "test"] {
        let result = project::tool(&project_path, &runtime, &vendor, tool).unwrap();
        assert_eq!(result["success"], true, "{tool}: {result}");
    }
    let built = project::build(&project_path, &runtime, &vendor).unwrap();
    assert!(!built["recipes"].as_array().unwrap().is_empty());
    for action in ["check", "build"] {
        let output = Command::new("cmd.exe")
            .args(["/d", "/c"])
            .arg(project_path.join("escriba.cmd"))
            .arg(action)
            .output()
            .unwrap();
        assert!(output.status.success(), "{action}: {output:?}");
    }
}
