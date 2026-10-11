use super::*;
use std::process::{Command, Stdio};
use std::time::Instant;

fn measure(phase: &str, start: Instant) -> u64 {
    let file = tempfile::NamedTempFile::new().unwrap();
    let output = Command::new("footprint")
        .args(["--noCategories", "--swapped", "-j"])
        .arg(file.path())
        .args(["-p", &std::process::id().to_string()])
        .stdout(Stdio::null())
        .output()
        .unwrap();
    assert!(output.status.success(), "No se pudo medir la memoria");
    let report: Value = serde_json::from_slice(&fs::read(file.path()).unwrap()).unwrap();
    let footprint = report["processes"][0]["footprint"].as_u64().unwrap();
    let mut usage = std::mem::MaybeUninit::<libc::rusage>::uninit();
    assert_eq!(
        unsafe { libc::getrusage(libc::RUSAGE_SELF, usage.as_mut_ptr()) },
        0
    );
    let usage = unsafe { usage.assume_init() };
    eprintln!(
        "MEMORY {}",
        json!({"phase":phase,"footprint":footprint,"maxRssBytes":usage.ru_maxrss,"elapsedMs":start.elapsed().as_millis()})
    );
    footprint
}

#[test]
#[ignore = "Prepara una copia migrada privada para comparar aperturas en procesos separados"]
fn prepara_copia_para_medicion() {
    let directory = private_copy();
    let store = Store::open_with_audio_cleanup(directory.path().into(), false).unwrap();
    drop(store);
    let directory = directory.keep();
    eprintln!(
        "PREPARED_COPY={}",
        directory.join("library.surrealkv").display()
    );
}

fn private_copy() -> tempfile::TempDir {
    let source = PathBuf::from(
        std::env::var_os("ESCRIBA_VERIFY_LIBRARY_COPY").expect("Falta la copia autorizada"),
    );
    assert!(source.is_dir(), "La copia no existe");
    let target = tempfile::tempdir().unwrap();
    fs::set_permissions(target.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let destination = target.path().join("library.surrealkv");
    for entry in walkdir::WalkDir::new(&source) {
        let entry = entry.unwrap();
        assert!(!entry.file_type().is_symlink(), "La copia contiene enlaces");
        let path = destination.join(entry.path().strip_prefix(&source).unwrap());
        if entry.file_type().is_dir() {
            fs::create_dir_all(path).unwrap();
        } else {
            fs::copy(entry.path(), path).unwrap();
        }
    }
    target
}

#[test]
#[ignore = "Sonda local con una copia privada; no muestra contenidos ni procesa notas"]
fn mide_carga_por_fases() {
    let directory = private_copy();
    let start = Instant::now();
    measure("initial", start);
    let database = Persistence::open(&directory.path().join("library.surrealkv")).unwrap();
    measure("database_open", start);
    let data = database.load().unwrap().unwrap();
    measure("library_loaded", start);
    let typed = LibraryData::read(&data).unwrap();
    measure("library_typed", start);
    drop(data);
    measure("raw_dropped", start);
    drop(typed);
    measure("library_dropped", start);
    drop(database);
    measure("database_closed", start);
}

#[test]
#[ignore = "Sonda del arranque real sobre una copia privada; no procesa ni borra audio"]
fn mide_almacen_en_reposo() {
    let directory = private_copy();
    let start = Instant::now();
    measure("initial", start);
    let store = Store::open_with_audio_cleanup(directory.path().into(), false).unwrap();
    measure("store_open", start);
    let view = store.library();
    assert!(!view["recordings"].as_array().unwrap().is_empty());
    drop(view);
    let footprint = measure("store_idle", start);
    if let Ok(limit) = std::env::var("ESCRIBA_MEMORY_LIMIT_MIB") {
        let limit: u64 = limit.parse().unwrap();
        assert!(
            footprint <= limit * 1048576,
            "El almacén supera {limit} MiB en reposo"
        );
    }
    drop(store);
    measure("store_closed", start);
}
