use chrono::{Datelike, Local, NaiveDate, TimeZone, Timelike};
use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde_json::{json, Value};
use std::os::{macos::fs::MetadataExt, unix::fs::MetadataExt as UnixMetadataExt};
use std::{
    collections::{HashMap, HashSet},
    fs, io,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::mpsc;

#[derive(Clone, Debug)]
pub struct Folder {
    pub id: String,
    pub path: PathBuf,
    pub enabled: bool,
    pub style: Style,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    Any,
    JustPressRecord,
    VoiceMemos,
}

impl Style {
    pub fn parse(value: Option<&str>) -> Result<Self, String> {
        match value.unwrap_or("any") {
            "any" => Ok(Self::Any),
            "justPressRecord" => Ok(Self::JustPressRecord),
            "voiceMemos" => Ok(Self::VoiceMemos),
            _ => Err("Estilo de carpeta vigilada desconocido".into()),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Stamp {
    pub size: u64,
    pub modified: SystemTime,
}

#[derive(Clone, Debug)]
pub struct Candidate {
    pub path: PathBuf,
    pub folder_id: String,
    pub stamp: Stamp,
    pub title: String,
    pub started_at: SystemTime,
    pub source_key: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FolderError {
    pub folder_id: String,
    pub path: PathBuf,
    pub message: String,
    pub permission_denied: bool,
}

impl FolderError {
    pub(crate) fn from_io(folder_id: String, path: PathBuf, error: io::Error) -> Self {
        Self {
            folder_id,
            path,
            message: error.to_string(),
            permission_denied: permission_denied(&error),
        }
    }

    fn from_notify(folder_id: String, path: PathBuf, error: notify::Error) -> Self {
        let permission_denied = match &error.kind {
            notify::ErrorKind::Io(source) => permission_denied(source),
            _ => false,
        };
        Self {
            folder_id,
            path,
            message: error.to_string(),
            permission_denied,
        }
    }
}

fn permission_denied(error: &io::Error) -> bool {
    error.kind() == io::ErrorKind::PermissionDenied
        || matches!(error.raw_os_error(), Some(libc::EPERM | libc::EACCES))
}

#[derive(Default)]
pub struct Health {
    issues: Vec<FolderError>,
}

impl Health {
    pub fn update(&mut self, mut issues: Vec<FolderError>) -> Option<Vec<FolderError>> {
        issues.sort_by(|a, b| {
            (&a.folder_id, &a.path, &a.message, a.permission_denied).cmp(&(
                &b.folder_id,
                &b.path,
                &b.message,
                b.permission_denied,
            ))
        });
        issues.dedup();
        if issues == self.issues {
            return None;
        }
        self.issues = issues.clone();
        Some(issues)
    }

    pub fn snapshot(&self) -> Value {
        Value::Array(
            self.issues
                .iter()
                .map(|issue| {
                    json!({
                        "folderId":issue.folder_id,
                        "path":issue.path.to_string_lossy(),
                        "message":issue.message,
                        "permissionDenied":issue.permission_denied,
                    })
                })
                .collect(),
        )
    }
}

#[derive(Default, Debug)]
pub struct ScanBatch {
    pub ready: Vec<Candidate>,
    pub zero: Vec<Candidate>,
    pub abandoned: Vec<Candidate>,
    pub errors: Vec<FolderError>,
}

#[derive(Default)]
pub struct Scanner {
    observed: HashMap<PathBuf, Stamp>,
    acknowledged: HashMap<PathBuf, Stamp>,
}

pub struct WatchHandle {
    _watcher: RecommendedWatcher,
    pub errors: Vec<FolderError>,
}

pub fn file_status(path: &Path) -> Result<Value, io::Error> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("No es un archivo regular: {}", path.display()),
        ));
    }
    let flags = metadata.st_flags();
    let modified = metadata
        .modified()?
        .duration_since(UNIX_EPOCH)
        .map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("Fecha inválida: {}", path.display()),
            )
        })?
        .as_secs_f64();
    Ok(json!({
        "size": metadata.len(),
        "blocks": metadata.blocks(),
        "flags": flags,
        "dataless": flags & 0x4000_0000 != 0,
        "modifiedAt": modified,
    }))
}

pub fn watch(folders: &[Folder], wake: mpsc::Sender<()>) -> Result<WatchHandle, String> {
    let mut watcher = notify::recommended_watcher(move |_event| {
        let _ = wake.try_send(());
    })
    .map_err(|error| format!("No se pudo iniciar FSEvents: {error}"))?;
    let mut errors = Vec::new();
    for folder in folders.iter().filter(|folder| folder.enabled) {
        if let Err(error) = watcher.watch(&folder.path, RecursiveMode::Recursive) {
            errors.push(FolderError::from_notify(
                folder.id.clone(),
                folder.path.clone(),
                error,
            ));
        }
    }
    Ok(WatchHandle {
        _watcher: watcher,
        errors,
    })
}

impl Scanner {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn scan(&mut self, folders: &[Folder], now: SystemTime) -> ScanBatch {
        let mut batch = ScanBatch::default();
        let mut visited = HashSet::new();
        for folder in folders.iter().filter(|folder| folder.enabled) {
            let mut pending = vec![folder.path.clone()];
            while let Some(directory) = pending.pop() {
                let entries = match fs::read_dir(&directory) {
                    Ok(entries) => entries,
                    Err(error) => {
                        batch.errors.push(FolderError::from_io(
                            folder.id.clone(),
                            directory,
                            error,
                        ));
                        continue;
                    }
                };
                for entry in entries {
                    let entry = match entry {
                        Ok(entry) => entry,
                        Err(error) => {
                            batch.errors.push(FolderError::from_io(
                                folder.id.clone(),
                                directory.clone(),
                                error,
                            ));
                            continue;
                        }
                    };
                    let path = entry.path();
                    if entry.file_name().to_string_lossy().starts_with('.') {
                        continue;
                    }
                    let kind = match entry.file_type() {
                        Ok(kind) => kind,
                        Err(error) => {
                            batch
                                .errors
                                .push(FolderError::from_io(folder.id.clone(), path, error));
                            continue;
                        }
                    };
                    if kind.is_symlink() {
                        continue;
                    }
                    if kind.is_dir() {
                        match folder.style {
                            Style::Any => pending.push(path),
                            Style::JustPressRecord
                                if directory == folder.path
                                    && entry.file_name().to_str().and_then(parse_day).is_some() =>
                            {
                                pending.push(path)
                            }
                            _ => {}
                        }
                        continue;
                    }
                    if !kind.is_file() || !audio_file(&path) || visited.contains(&path) {
                        continue;
                    }
                    let metadata = match entry.metadata() {
                        Ok(metadata) => metadata,
                        Err(error) => {
                            batch
                                .errors
                                .push(FolderError::from_io(folder.id.clone(), path, error));
                            continue;
                        }
                    };
                    let modified = match metadata.modified() {
                        Ok(modified) => modified,
                        Err(error) => {
                            batch
                                .errors
                                .push(FolderError::from_io(folder.id.clone(), path, error));
                            continue;
                        }
                    };
                    let Some((title, started_at, source_key)) =
                        source_metadata(folder, &path, &metadata, modified)
                    else {
                        continue;
                    };
                    visited.insert(path.clone());
                    let stamp = Stamp {
                        size: metadata.len(),
                        modified,
                    };
                    let stable = self.observed.get(&path) == Some(&stamp);
                    self.observed.insert(path.clone(), stamp.clone());
                    if !stable || self.acknowledged.get(&path) == Some(&stamp) {
                        continue;
                    }
                    let age = now.duration_since(modified).unwrap_or_default();
                    let candidate = Candidate {
                        path,
                        folder_id: folder.id.clone(),
                        stamp,
                        title,
                        started_at,
                        source_key,
                    };
                    if candidate.stamp.size == 0 {
                        if age >= Duration::from_secs(3_600) {
                            batch.abandoned.push(candidate);
                        } else {
                            batch.zero.push(candidate);
                        }
                    } else if age >= Duration::from_secs(15) {
                        batch.ready.push(candidate);
                    }
                }
            }
        }
        self.observed.retain(|path, _| visited.contains(path));
        self.acknowledged.retain(|path, _| visited.contains(path));
        batch
    }

    pub fn acknowledge(&mut self, candidate: &Candidate) {
        self.acknowledged
            .insert(candidate.path.clone(), candidate.stamp.clone());
    }
}

fn audio_file(path: &Path) -> bool {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("");
    [
        "m4a", "mp3", "wav", "aac", "flac", "ogg", "oga", "opus", "mp4", "aiff", "aif", "caf",
        "webm", "mov",
    ]
    .iter()
    .any(|candidate| extension.eq_ignore_ascii_case(candidate))
}

fn source_metadata(
    folder: &Folder,
    path: &Path,
    metadata: &fs::Metadata,
    modified: SystemTime,
) -> Option<(String, SystemTime, String)> {
    let relative = path.strip_prefix(&folder.path).ok()?;
    let stem = path.file_stem()?.to_str()?.to_owned();
    let relative_key = relative.with_extension("").to_str()?.to_owned();
    match folder.style {
        Style::Any => Some((
            stem,
            modified,
            format!("any:{}/{}", folder.id, relative_key),
        )),
        Style::VoiceMemos => {
            if relative.components().count() != 1 {
                return None;
            }
            let inode = metadata.ino();
            let key = if inode == 0 {
                relative_key
            } else {
                inode.to_string()
            };
            Some((stem, modified, format!("voiceMemos:{}/{}", folder.id, key)))
        }
        Style::JustPressRecord => {
            if relative.components().count() != 2 || !path.extension()?.eq_ignore_ascii_case("m4a")
            {
                return None;
            }
            let day = relative.parent()?.file_name()?.to_str()?;
            let date = parse_day(day)?;
            let (hour, minute, second) = parse_triplet(&stem, [2, 2, 2])?;
            let naive = date.and_hms_opt(hour, minute, second)?;
            let instant = Local.from_local_datetime(&naive).earliest()?;
            let month = [
                "enero",
                "febrero",
                "marzo",
                "abril",
                "mayo",
                "junio",
                "julio",
                "agosto",
                "septiembre",
                "octubre",
                "noviembre",
                "diciembre",
            ][(instant.month() - 1) as usize];
            let title = format!(
                "Grabación del {} de {month} de {}, {:02}:{:02}",
                instant.day(),
                instant.year(),
                instant.hour(),
                instant.minute()
            );
            Some((
                title,
                instant.into(),
                format!("justPressRecord:{}/{}", folder.id, relative_key),
            ))
        }
    }
}

fn parse_day(value: &str) -> Option<NaiveDate> {
    let (year, month, day) = parse_triplet(value, [4, 2, 2])?;
    NaiveDate::from_ymd_opt(year as i32, month, day)
}

fn parse_triplet(value: &str, widths: [usize; 3]) -> Option<(u32, u32, u32)> {
    let parts: Vec<_> = value.split('-').collect();
    if parts.len() != 3 {
        return None;
    }
    let mut values = [0; 3];
    for (index, part) in parts.into_iter().enumerate() {
        if part.len() != widths[index] || !part.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        values[index] = part.parse().ok()?;
    }
    Some((values[0], values[1], values[2]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        sync::atomic::{AtomicU64, Ordering},
    };

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "escriba-watcher-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn estado_archivo_no_sigue_symlinks_y_detecta_archivo_materializado() {
        let tmp = Temp::new();
        let file = tmp.0.join("grabación.wav");
        fs::write(&file, b"audio sintetico").unwrap();
        let status = file_status(&file).unwrap();
        assert_eq!(status["size"], 15);
        assert_eq!(status["dataless"], false);
        assert!(status["modifiedAt"].as_f64().unwrap() > 0.0);
        assert!(file_status(&tmp.0).is_err());
        let link = tmp.0.join("atajo.wav");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(file_status(&link).is_err());
    }

    #[test]
    fn una_carpeta_inaccesible_no_oculta_el_audio_de_otra() {
        let tmp = Temp::new();
        let file = tmp.0.join("notas").join("voz.M4A");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, b"audio").unwrap();
        let folders = [
            Folder {
                id: "caida".into(),
                path: tmp.0.join("ausente"),
                enabled: true,
                style: Style::Any,
            },
            Folder {
                id: "bien".into(),
                path: tmp.0.clone(),
                enabled: true,
                style: Style::Any,
            },
        ];
        let now = SystemTime::now() + Duration::from_secs(16);
        let mut scanner = Scanner::new();
        assert!(scanner.scan(&folders, now).ready.is_empty());
        let batch = scanner.scan(&folders, now + Duration::from_secs(1));
        assert_eq!(batch.ready.len(), 1);
        assert_eq!(batch.ready[0].path, file);
        assert_eq!(batch.ready[0].folder_id, "bien");
        assert_eq!(batch.errors.len(), 1);
        assert_eq!(batch.errors[0].folder_id, "caida");
    }

    #[test]
    fn cambio_de_tamano_exige_otra_observacion_y_ack_solo_tras_importar() {
        let tmp = Temp::new();
        let file = tmp.0.join("voz.wav");
        fs::write(&file, b"a").unwrap();
        let folder = Folder {
            id: "f".into(),
            path: tmp.0.clone(),
            enabled: true,
            style: Style::Any,
        };
        let mut scanner = Scanner::new();
        let now = SystemTime::now() + Duration::from_secs(16);
        assert!(scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .is_empty());
        let first = scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .remove(0);
        assert_eq!(
            scanner.scan(std::slice::from_ref(&folder), now).ready.len(),
            1
        );
        fs::write(&file, b"ab").unwrap();
        assert!(scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .is_empty());
        let changed = scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .remove(0);
        assert_ne!(first.stamp, changed.stamp);
        scanner.acknowledge(&changed);
        assert!(scanner.scan(&[folder], now).ready.is_empty());
    }

    #[test]
    fn vacio_antiguo_se_reporta_y_symlink_no_sale_de_la_carpeta() {
        let tmp = Temp::new();
        let outside = Temp::new();
        fs::write(tmp.0.join("vacío.m4a"), []).unwrap();
        fs::write(outside.0.join("externo.m4a"), b"audio").unwrap();
        std::os::unix::fs::symlink(outside.0.join("externo.m4a"), tmp.0.join("atajo.m4a")).unwrap();
        let folder = Folder {
            id: "f".into(),
            path: tmp.0.clone(),
            enabled: true,
            style: Style::Any,
        };
        let mut scanner = Scanner::new();
        let soon = SystemTime::now() + Duration::from_secs(16);
        scanner.scan(std::slice::from_ref(&folder), soon);
        let before = scanner.scan(std::slice::from_ref(&folder), soon);
        assert_eq!(before.zero.len(), 1);
        assert!(before.abandoned.is_empty());
        let later = SystemTime::now() + Duration::from_secs(3601);
        let batch = scanner.scan(&[folder], later);
        assert_eq!(batch.abandoned.len(), 1);
        assert_eq!(batch.abandoned[0].path, tmp.0.join("vacío.m4a"));
        assert!(batch.ready.is_empty());
    }

    #[test]
    fn fsevents_conserva_una_carpeta_si_otra_no_puede_vigilarse() {
        let tmp = Temp::new();
        let folders = [
            Folder {
                id: "bien".into(),
                path: tmp.0.clone(),
                enabled: true,
                style: Style::Any,
            },
            Folder {
                id: "caida".into(),
                path: tmp.0.join("ausente"),
                enabled: true,
                style: Style::Any,
            },
        ];
        let (wake, _receiver) = mpsc::channel(1);
        let handle = watch(&folders, wake).unwrap();
        assert_eq!(handle.errors.len(), 1);
        assert_eq!(handle.errors[0].folder_id, "caida");
    }

    #[test]
    fn estilo_jpr_valida_fecha_nombre_y_nivel_y_conserva_fecha_de_grabacion() {
        let tmp = Temp::new();
        for name in [
            "2026-08-29/10-00-00.m4a",
            "2026-08-29/suelto.m4a",
            "suelto.m4a",
            "otro/11-00-00.m4a",
            "2026-02-30/10-00-00.m4a",
            "2026-08-29/sub/11-00-00.m4a",
        ] {
            let file = tmp.0.join(name);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, b"audio").unwrap();
        }
        let folder = Folder {
            id: "jpr".into(),
            path: tmp.0.clone(),
            enabled: true,
            style: Style::JustPressRecord,
        };
        let mut scanner = Scanner::new();
        let now = SystemTime::now() + Duration::from_secs(16);
        scanner.scan(std::slice::from_ref(&folder), now);
        let batch = scanner.scan(&[folder], now);
        assert_eq!(batch.ready.len(), 1);
        let item = &batch.ready[0];
        assert_eq!(item.path, tmp.0.join("2026-08-29/10-00-00.m4a"));
        assert_eq!(item.source_key, "justPressRecord:jpr/2026-08-29/10-00-00");
        assert_eq!(item.title, "Grabación del 29 de agosto de 2026, 10:00");
        let local: chrono::DateTime<Local> = item.started_at.into();
        assert_eq!(
            local.format("%Y-%m-%d %H:%M:%S").to_string(),
            "2026-08-29 10:00:00"
        );
    }

    #[test]
    fn notas_de_voz_acepta_solo_primer_nivel_y_renombrar_mantiene_clave() {
        let tmp = Temp::new();
        let original = tmp.0.join("Nueva grabación.m4a");
        fs::write(&original, b"audio").unwrap();
        let nested = tmp.0.join("edicion.composition/trozo.m4a");
        fs::create_dir_all(nested.parent().unwrap()).unwrap();
        fs::write(nested, b"audio").unwrap();
        let folder = Folder {
            id: "vm".into(),
            path: tmp.0.clone(),
            enabled: true,
            style: Style::VoiceMemos,
        };
        let mut scanner = Scanner::new();
        let now = SystemTime::now() + Duration::from_secs(16);
        scanner.scan(std::slice::from_ref(&folder), now);
        let first = scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .remove(0);
        assert_eq!(first.title, "Nueva grabación");
        assert_eq!(
            first.started_at,
            fs::metadata(&original).unwrap().modified().unwrap()
        );
        let renamed = tmp.0.join("Reunión con Aritz.m4a");
        fs::rename(&original, &renamed).unwrap();
        scanner.scan(std::slice::from_ref(&folder), now);
        let second = scanner.scan(&[folder], now).ready.remove(0);
        assert_eq!(second.path, renamed);
        assert_eq!(first.source_key, second.source_key);
        assert_eq!(second.title, "Reunión con Aritz");
    }

    #[test]
    fn carpeta_libre_recursiva_incluye_mov_y_style_ausente_es_any() {
        let tmp = Temp::new();
        let file = tmp.0.join("llamadas/reunión.mov");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, b"audio").unwrap();
        let folder = Folder {
            id: "libre".into(),
            path: tmp.0.clone(),
            enabled: true,
            style: Style::parse(None).unwrap(),
        };
        let mut scanner = Scanner::new();
        let now = SystemTime::now() + Duration::from_secs(16);
        scanner.scan(std::slice::from_ref(&folder), now);
        let item = scanner.scan(&[folder], now).ready.remove(0);
        assert_eq!(item.path, file);
        assert_eq!(item.title, "reunión");
        assert_eq!(item.source_key, "any:libre/llamadas/reunión");
        assert!(Style::parse(Some("unexpected")).is_err());
    }

    #[test]
    fn placeholder_oculto_solo_se_importa_cuando_aparece_audio_visible() {
        let tmp = Temp::new();
        let placeholder = tmp.0.join(".nota.m4a.icloud");
        fs::write(&placeholder, b"placeholder").unwrap();
        let folder = Folder {
            id: "icloud".into(),
            path: tmp.0.clone(),
            enabled: true,
            style: Style::Any,
        };
        let mut scanner = Scanner::new();
        let now = SystemTime::now() + Duration::from_secs(16);
        scanner.scan(std::slice::from_ref(&folder), now);
        assert!(scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .is_empty());
        let materialized = tmp.0.join("nota.m4a");
        fs::rename(placeholder, &materialized).unwrap();
        assert!(scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .is_empty());
        assert_eq!(scanner.scan(&[folder], now).ready[0].path, materialized);
    }

    #[test]
    fn salud_de_vigilancia_avisa_solo_al_cambiar_y_limpia_al_recuperar() {
        let tmp = Temp::new();
        let folder = Folder {
            id: "vm".into(),
            path: tmp.0.join("ausente"),
            enabled: true,
            style: Style::VoiceMemos,
        };
        let mut scanner = Scanner::new();
        let mut health = Health::default();
        let first = scanner.scan(std::slice::from_ref(&folder), SystemTime::now());
        assert_eq!(first.errors.len(), 1);
        assert_eq!(health.update(first.errors.clone()).unwrap().len(), 1);
        assert_eq!(health.snapshot()[0]["folderId"], "vm");
        assert_eq!(health.snapshot()[0]["permissionDenied"], false);
        assert!(health.update(first.errors).is_none());
        fs::create_dir_all(&folder.path).unwrap();
        let recovered = scanner.scan(std::slice::from_ref(&folder), SystemTime::now());
        assert!(recovered.errors.is_empty());
        assert!(health.update(recovered.errors).unwrap().is_empty());
        assert_eq!(health.snapshot(), json!([]));
        assert!(health.update(Vec::new()).is_none());
    }

    #[test]
    fn permisos_denegados_io_y_notify_se_identifican_sin_depender_del_texto() {
        let path = PathBuf::from("/synthetic/voice-memos");
        let io = std::io::Error::from_raw_os_error(libc::EPERM);
        let issue = FolderError::from_io("vm".into(), path.clone(), io);
        assert!(issue.permission_denied);
        let notify = notify::Error::io(std::io::Error::from_raw_os_error(libc::EACCES));
        let issue = FolderError::from_notify("vm".into(), path, notify);
        assert!(issue.permission_denied);
    }

    #[test]
    fn salud_ordena_deduplica_y_acepta_rutas_no_utf8() {
        use std::os::unix::ffi::OsStringExt;
        let odd = PathBuf::from(std::ffi::OsString::from_vec(vec![b'/', b'v', 0xff]));
        let first = FolderError::from_io(
            "b".into(),
            odd,
            std::io::Error::from(std::io::ErrorKind::NotFound),
        );
        let second = FolderError::from_io(
            "a".into(),
            PathBuf::from("/synthetic"),
            std::io::Error::from(std::io::ErrorKind::PermissionDenied),
        );
        let mut health = Health::default();
        let updated = health
            .update(vec![first.clone(), second.clone(), first.clone()])
            .unwrap();
        assert_eq!(updated.len(), 2);
        assert_eq!(updated[0].folder_id, "a");
        assert_eq!(health.snapshot()[1]["path"].as_str().unwrap(), "/v�");
        assert!(health.update(vec![first, second]).is_none());
    }

    #[test]
    fn archivo_desaparece_entre_escaneo_y_estado_y_la_salud_se_recupera() {
        let tmp = Temp::new();
        let path = tmp.0.join("nueva.m4a");
        fs::write(&path, b"audio sintetico").unwrap();
        let folder = Folder {
            id: "vm".into(),
            path: tmp.0.clone(),
            enabled: true,
            style: Style::VoiceMemos,
        };
        let now = SystemTime::now() + Duration::from_secs(16);
        let mut scanner = Scanner::new();
        assert!(scanner
            .scan(std::slice::from_ref(&folder), now)
            .ready
            .is_empty());
        let candidate = scanner.scan(&[folder], now).ready.remove(0);
        fs::remove_file(&candidate.path).unwrap();
        let error = file_status(&candidate.path).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::NotFound);
        let issue = FolderError::from_io(candidate.folder_id, candidate.path.clone(), error);
        let mut health = Health::default();
        assert_eq!(health.update(vec![issue.clone()]).unwrap().len(), 1);
        assert_eq!(health.snapshot()[0]["path"], json!(path));
        assert!(health.update(vec![issue]).is_none());
        fs::write(&path, b"audio recuperado").unwrap();
        assert!(file_status(&path).is_ok());
        assert!(health.update(Vec::new()).unwrap().is_empty());
        assert_eq!(health.snapshot(), json!([]));
    }
}
