use chrono::{DateTime, NaiveDateTime};
use plist::Value as Plist;
use rusqlite::{Connection, OpenFlags};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::{self, File},
    io::Read,
    os::unix::fs::{DirBuilderExt, MetadataExt},
    path::{Path, PathBuf},
};

pub struct Plan {
    pub data: Value,
    pub copies: Vec<(PathBuf, PathBuf)>,
    pub memories: Vec<Value>,
    pub traces: Vec<Value>,
    pub report: Value,
}

fn recording_id(key: &str) -> Result<String, String> {
    if key.is_empty() {
        return Err("Grabación SwiftUI sin clave".into());
    }
    if crate::store::safe_id(key).is_ok() {
        Ok(key.to_owned())
    } else {
        Ok(format!("swift-{:x}", Sha256::digest(key.as_bytes())))
    }
}

struct StagedDatabase {
    directory: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct FileIdentity {
    device: u64,
    inode: u64,
    length: u64,
    modified_seconds: i64,
    modified_nanoseconds: i64,
    changed_seconds: i64,
    changed_nanoseconds: i64,
    digest: Vec<u8>,
}

fn file_identity(path: &Path) -> Result<Option<FileIdentity>, String> {
    let before = match fs::metadata(path) {
        Ok(value) if value.is_file() => value,
        Ok(_) => return Err(format!("No es un archivo SQLite: {}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.to_string()),
    };
    let mut file = File::open(path).map_err(|e| e.to_string())?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let bytes = file.read(&mut buffer).map_err(|e| e.to_string())?;
        if bytes == 0 {
            break;
        }
        hash.update(&buffer[..bytes]);
    }
    let after = fs::metadata(path).map_err(|e| e.to_string())?;
    let identity = |metadata: &fs::Metadata| {
        (
            metadata.dev(),
            metadata.ino(),
            metadata.len(),
            metadata.mtime(),
            metadata.mtime_nsec(),
            metadata.ctime(),
            metadata.ctime_nsec(),
        )
    };
    if identity(&before) != identity(&after) {
        return Err(
            "SQLite SwiftUI cambió durante la copia; cierra Escriba SwiftUI e inténtalo otra vez"
                .into(),
        );
    }
    Ok(Some(FileIdentity {
        device: before.dev(),
        inode: before.ino(),
        length: before.len(),
        modified_seconds: before.mtime(),
        modified_nanoseconds: before.mtime_nsec(),
        changed_seconds: before.ctime(),
        changed_nanoseconds: before.ctime_nsec(),
        digest: hash.finalize().to_vec(),
    }))
}

impl StagedDatabase {
    fn copy_from(source: &Path, target: &Path) -> Result<Self, String> {
        Self::copy_from_with(source, target, || {})
    }

    fn copy_from_with(
        source: &Path,
        target: &Path,
        after_first_copy: impl FnOnce(),
    ) -> Result<Self, String> {
        let source = source.canonicalize().map_err(|e| e.to_string())?;
        let directory = target.join(format!(".swift-import-{}", uuid::Uuid::new_v4()));
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .map_err(|e| e.to_string())?;
        let stage = Self { directory };
        let names = ["library.sqlite", "library.sqlite-wal"];
        let expected = names.map(|name| file_identity(&source.join(name)));
        let expected = expected.into_iter().collect::<Result<Vec<_>, _>>()?;
        if expected[0].is_none() {
            return Err("La carpeta elegida no contiene library.sqlite".into());
        }
        let mut after_first_copy = Some(after_first_copy);
        for (name, expected) in names.iter().zip(expected.iter()) {
            let origin = source.join(name);
            if expected.is_some() {
                if !origin
                    .canonicalize()
                    .map_err(|e| e.to_string())?
                    .starts_with(&source)
                {
                    return Err(format!("{name} está fuera de la biblioteca elegida"));
                }
                fs::copy(&origin, stage.directory.join(name))
                    .map_err(|e| format!("No se pudo copiar {name}: {e}"))?;
                if *name == "library.sqlite" {
                    if let Some(hook) = after_first_copy.take() {
                        hook();
                    }
                }
                if file_identity(&stage.directory.join(name))?
                    .as_ref()
                    .map(|state| &state.digest)
                    != expected.as_ref().map(|state| &state.digest)
                {
                    return Err(format!(
                        "{name} cambió durante la copia; cierra Escriba SwiftUI"
                    ));
                }
            }
            if file_identity(&origin)? != *expected {
                return Err(format!(
                    "{name} cambió durante la copia; cierra Escriba SwiftUI"
                ));
            }
        }
        for (name, expected) in names.iter().zip(expected.iter()) {
            if file_identity(&source.join(name))? != *expected {
                return Err(format!(
                    "{name} cambió durante la copia; cierra Escriba SwiftUI"
                ));
            }
        }
        Ok(stage)
    }
}

impl Drop for StagedDatabase {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}

pub fn plan(
    source: &Path,
    target: &Path,
    current: &Value,
    settings_plist: Option<&Path>,
) -> Result<Plan, String> {
    let source = source
        .canonicalize()
        .map_err(|e| format!("Biblioteca SwiftUI inaccesible: {e}"))?;
    let legacy_db = source.join("library.sqlite");
    if !legacy_db.is_file() {
        return Err("La carpeta elegida no contiene library.sqlite".into());
    }
    let staged = StagedDatabase::copy_from(&source, target)?;
    let db = Connection::open_with_flags(
        staged.directory.join("library.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|e| format!("No se puede leer SQLite SwiftUI: {e}"))?;
    let check: String = db
        .query_row("PRAGMA quick_check", [], |row| row.get(0))
        .map_err(|e| e.to_string())?;
    if check != "ok" {
        return Err(format!(
            "SQLite SwiftUI no supera la comprobación de integridad: {check}"
        ));
    }
    let mut next = current.clone();
    let settings = settings_plist.map(read_settings).transpose()?;
    let mut imported = 0usize;
    let mut missing_audio = 0usize;
    let mut copies = Vec::new();
    let audio_root = if source.join("audio").exists() {
        Some(
            source
                .join("audio")
                .canonicalize()
                .map_err(|e| format!("Carpeta de audio SwiftUI inaccesible: {e}"))?,
        )
    } else {
        None
    };
    let mut records = db.prepare("SELECT id, key, sourcePath, audioPath, startedAt, importedAt, status, lastError, currentTranscriptId FROM recording ORDER BY id")
        .map_err(|e| format!("Esquema SwiftUI incompatible: {e}"))?;
    let rows = records
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, Option<String>>(7)?,
                row.get::<_, Option<i64>>(8)?,
            ))
        })
        .map_err(|e| e.to_string())?;
    for source_row in rows {
        let (
            record_id,
            key,
            source_path,
            relative_audio,
            started_at,
            imported_at,
            status,
            error,
            current_id,
        ) = source_row.map_err(|e| e.to_string())?;
        let mapped_id = recording_id(&key)?;
        if next["recordings"]
            .as_array()
            .is_some_and(|records| records.iter().any(|r| r["legacyKey"] == key))
        {
            continue;
        }
        if next["recordings"]
            .as_array()
            .is_some_and(|records| records.iter().any(|r| r["id"] == mapped_id))
        {
            if mapped_id == key {
                continue;
            }
            return Err(format!("Conflicto con la clave importada {key}"));
        }
        let mut version_stmt = db.prepare("SELECT id, backend, createdAt, text, language, diarize, speakerCount, optionsKnown, digestTitle, digestSummary, digestTags, data, dataSchema, recipe FROM transcript WHERE recordingId = ? ORDER BY id")
            .map_err(|e| e.to_string())?;
        let versions = version_stmt
            .query_map([record_id], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, Option<i64>>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, Option<String>>(8)?,
                    row.get::<_, Option<String>>(9)?,
                    row.get::<_, Option<String>>(10)?,
                    row.get::<_, Option<String>>(11)?,
                    row.get::<_, Option<String>>(12)?,
                    row.get::<_, Option<String>>(13)?,
                ))
            })
            .map_err(|e| e.to_string())?;
        let mut converted = Vec::new();
        for version in versions {
            let (
                id,
                backend,
                created,
                text,
                language,
                diarize,
                speakers,
                known,
                title,
                summary,
                tags,
                data,
                data_schema,
                recipe,
            ) = version.map_err(|e| e.to_string())?;
            let segments = segments(&db, id)?;
            let duration = segments
                .iter()
                .filter_map(|s| s["end"].as_f64())
                .fold(0.0, f64::max);
            let version_id = format!("swift:{record_id}:{id}");
            let mut converted_version = json!({"id":version_id,"createdAt":date(&created),"backend":backend,"transcript":{"text":text,"segments":segments,"language":language,"duration":duration},"recipeId":recipe});
            if let (Some(title), Some(summary)) = (title, summary) {
                let tags: Value = tags
                    .as_deref()
                    .map(serde_json::from_str)
                    .transpose()
                    .map_err(|e| format!("Etiquetas SwiftUI inválidas: {e}"))?
                    .unwrap_or(json!([]));
                converted_version["digest"] = json!({"title":title,"summary":summary,"tags":tags});
            }
            if let Some(raw) = data {
                converted_version["data"] = serde_json::from_str(&raw)
                    .map_err(|e| format!("Datos SwiftUI inválidos: {e}"))?;
            }
            if let Some(raw) = data_schema {
                converted_version["dataSchema"] = serde_json::from_str(&raw)
                    .map_err(|e| format!("Esquema de datos SwiftUI inválido: {e}"))?;
            }
            if known != 0 {
                converted_version["inputs"] = json!({"backend":backend,"language":language,"diarize":diarize != 0,"speakers":speakers});
            }
            converted.push(converted_version);
        }
        let publications = publications(&db, record_id, settings.as_ref())?;
        let mut audio_path = Value::Null;
        if !relative_audio.is_empty() {
            let relative = Path::new(&relative_audio);
            let candidate = source.join(relative);
            let real = match candidate.canonicalize() {
                Ok(real) => Some(real),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(format!("No se puede leer el audio SwiftUI: {error}")),
            };
            if let (Some(audio_root), Some(real)) = (&audio_root, real) {
                if !real.starts_with(audio_root) || !real.is_file() {
                    return Err("Audio SwiftUI fuera de su biblioteca".into());
                }
                let ext = real
                    .extension()
                    .and_then(|v| v.to_str())
                    .unwrap_or("")
                    .to_lowercase();
                if ![
                    "m4a", "mp3", "wav", "aac", "flac", "ogg", "oga", "opus", "mp4", "aiff", "aif",
                    "caf", "webm",
                ]
                .contains(&ext.as_str())
                {
                    return Err("Audio SwiftUI de formato no admitido".into());
                }
                let destination = target.join("audio").join(format!("{mapped_id}.{ext}"));
                copies.push((real, destination.clone()));
                audio_path = json!(destination);
            } else {
                missing_audio += 1;
            }
        } else {
            missing_audio += 1;
        }
        let current = current_id.map(|id| format!("swift:{record_id}:{id}"));
        let current = current.filter(|id| {
            converted
                .iter()
                .any(|v| v["id"].as_str() == Some(id.as_str()))
        });
        let fallback = converted
            .last()
            .and_then(|v| v["id"].as_str())
            .map(str::to_owned);
        let record = json!({
            "id":mapped_id,"legacyKey":key,"sourceKey":format!("swift:{key}"),"title":Path::new(&source_path).file_stem().and_then(|v| v.to_str()).unwrap_or("Grabación"),
            "createdAt":date(&started_at),"importedAt":date(&imported_at),"source":source_path,
            "audioPath":audio_path,"duration":converted.last().and_then(|v| v["transcript"]["duration"].as_f64()).unwrap_or(0.0),
            "status":if status == "processing" {"pending"} else {status.as_str()},"error":error,
            "currentVersionId":current.or(fallback),"recipeId":converted.last().and_then(|v| v["recipeId"].as_str()),
            "versions":converted,"publications":publications
        });
        next["recordings"]
            .as_array_mut()
            .ok_or("Biblioteca inválida")?
            .push(record);
        imported += 1;
    }
    if let Some(settings) = &settings {
        merge_settings(&mut next, settings)?;
    }
    let memories = import_answers(&db, &next)?;
    let traces = import_runs(&db, &next)?;
    fs::remove_dir_all(&staged.directory)
        .map_err(|e| format!("No se pudo limpiar la copia temporal de SQLite: {e}"))?;
    Ok(Plan {
        data: next,
        copies,
        report: json!({"recordings":imported,"audioMissing":missing_audio,"settingsImported":settings.is_some(),"credentialsImported":0,"answers":memories.len(),"runs":traces.len()}),
        memories,
        traces,
    })
}

fn has_table(db: &Connection, table: &str) -> Result<bool, String> {
    db.query_row(
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
        [table],
        |row| row.get::<_, i64>(0),
    )
    .map(|count| count > 0)
    .map_err(|e| e.to_string())
}

fn has_version(data: &Value, recording_id: &str, version_id: &str) -> bool {
    data["recordings"].as_array().is_some_and(|items| {
        items.iter().any(|record| {
            record["id"] == recording_id
                && record["versions"].as_array().is_some_and(|versions| {
                    versions.iter().any(|version| version["id"] == version_id)
                })
        })
    })
}

fn import_answers(db: &Connection, data: &Value) -> Result<Vec<Value>, String> {
    if !has_table(db, "answer")? {
        return Ok(Vec::new());
    }
    let mut stmt = db.prepare("SELECT r.key, t.recordingId, a.transcriptId, a.fingerprint, a.payload FROM answer a JOIN transcript t ON t.id = a.transcriptId JOIN recording r ON r.id = t.recordingId")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })
        .map_err(|e| e.to_string())?;
    let mut memories = Vec::new();
    for row in rows {
        let (source_key, source_record, source_version, fingerprint, payload) =
            row.map_err(|e| e.to_string())?;
        let recording_id = recording_id(&source_key)?;
        let version_id = format!("swift:{source_record}:{source_version}");
        if !has_version(data, &recording_id, &version_id) {
            continue;
        }
        let parsed = serde_json::from_str::<Value>(&payload)
            .map_err(|e| format!("Respuesta SwiftUI {source_version} corrupta: {e}"))?;
        let key = json!([recording_id, version_id, fingerprint]).to_string();
        memories.push(json!({"key":key,"parent":recording_id,"value":{"value":parsed}}));
    }
    Ok(memories)
}

fn import_runs(db: &Connection, data: &Value) -> Result<Vec<Value>, String> {
    if !has_table(db, "recipeRun")? {
        return Ok(Vec::new());
    }
    let mut stmt = db.prepare("SELECT run.id, recording.key, run.recipeKey, run.trigger, run.startedAt, run.payload FROM recipeRun run JOIN recording ON recording.id = run.recordingId ORDER BY run.id")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
            ))
        })
        .map_err(|e| e.to_string())?;
    let mut traces = Vec::new();
    for row in rows {
        let (id, source_key, recipe_id, trigger, started_at, payload) =
            row.map_err(|e| e.to_string())?;
        let recording_id = recording_id(&source_key)?;
        if !data["recordings"]
            .as_array()
            .is_some_and(|items| items.iter().any(|record| record["id"] == recording_id))
        {
            continue;
        }
        let original: Value =
            serde_json::from_str(&payload).map_err(|e| format!("Traza SwiftUI inválida: {e}"))?;
        traces.push(json!({"id":format!("swift-run:{id}"),"recordingId":recording_id,"recipeId":recipe_id,"dryRun":trigger == "test","startedAt":date(&started_at),"finishedAt":date(&started_at),"steps":original["steps"],"error":original["error"],"legacy":original}));
    }
    Ok(traces)
}

fn segments(db: &Connection, transcript_id: i64) -> Result<Vec<Value>, String> {
    let mut stmt = db.prepare("SELECT startTime, endTime, speaker, text, words FROM segment WHERE transcriptId = ? ORDER BY position")
        .map_err(|e| e.to_string())?;
    let result = stmt
        .query_map([transcript_id], |row| {
            Ok((
                row.get::<_, f64>(0)?,
                row.get::<_, f64>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })
        .map_err(|e| e.to_string())?
        .map(|row| {
            let (start, end, speaker, text, words) = row.map_err(|e| e.to_string())?;
            let words: Value = serde_json::from_str(&words)
                .map_err(|e| format!("Palabras SwiftUI inválidas: {e}"))?;
            Ok(json!({"start":start,"end":end,"speaker":speaker,"text":text,"words":words}))
        })
        .collect();
    result
}

fn publications(
    db: &Connection,
    recording_id: i64,
    settings: Option<&Plist>,
) -> Result<Vec<Value>, String> {
    let mut stmt = db.prepare("SELECT connector, pageId, url, syncedAt, error FROM publication WHERE recordingId = ? ORDER BY id")
        .map_err(|e| e.to_string())?;
    let result = stmt.query_map([recording_id], |row| Ok((row.get::<_, String>(0)?,row.get::<_, Option<String>>(1)?,row.get::<_, Option<String>>(2)?,row.get::<_, Option<String>>(3)?,row.get::<_, Option<String>>(4)?)))
        .map_err(|e| e.to_string())?.map(|row| {
            let (connector,page_id,url,synced,error) = row.map_err(|e| e.to_string())?;
            let provider = connector_provider(settings, &connector).unwrap_or("legacy");
            Ok(json!({"destinationId":connector,"name":connector,"provider":provider,"accountId":null,
                "receipt":{"state":"legacy","locator":page_id,"url":url,"error":error},"configuration":{},"updatedAt":synced.map(|v| date(&v))}))
        }).collect();
    result
}

fn date(raw: &str) -> String {
    if DateTime::parse_from_rfc3339(raw).is_ok() {
        return raw.to_owned();
    }
    for pattern in ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S%.f"] {
        if let Ok(value) = NaiveDateTime::parse_from_str(raw, pattern) {
            return value.and_utc().to_rfc3339();
        }
    }
    raw.to_owned()
}

fn read_settings(path: &Path) -> Result<Plist, String> {
    Plist::from_file(path).map_err(|e| format!("Preferencias SwiftUI inválidas: {e}"))
}

fn setting_json(settings: &Plist, key: &str) -> Result<Option<Value>, String> {
    let value = settings.as_dictionary().and_then(|d| d.get(key));
    match value {
        Some(Plist::Data(bytes)) => serde_json::from_slice(bytes)
            .map(Some)
            .map_err(|e| format!("Ajuste SwiftUI {key} inválido: {e}")),
        None => Ok(None),
        _ => Err(format!("Ajuste SwiftUI {key} no es JSON codificado")),
    }
}

fn connector_provider<'a>(settings: Option<&'a Plist>, connector: &str) -> Option<&'a str> {
    let raw = settings?.as_dictionary()?.get("connectors")?.as_data()?;
    let value: Value = serde_json::from_slice(raw).ok()?;
    let provider = value.as_array()?.iter().find(|v| v["id"] == connector)?["provider"].as_str()?;
    if provider == "notion" {
        Some("notion")
    } else if provider == "okf" {
        Some("okf")
    } else {
        None
    }
}

fn merge_settings(next: &mut Value, plist: &Plist) -> Result<(), String> {
    let values = plist
        .as_dictionary()
        .ok_or("Preferencias SwiftUI no son un diccionario")?;
    if let Some(language) = values.get("language").and_then(Plist::as_string) {
        next["settings"]["language"] = json!(language);
    }
    if let Some(notify) = values.get("notifyEveryNote").and_then(Plist::as_boolean) {
        next["settings"]["notifyEveryNote"] = json!(notify);
    }
    if let Some(folder) = values.get("recipesFolder").and_then(Plist::as_string) {
        next["settings"]["projectPath"] = json!(folder);
    }
    if let Some(watched) = setting_json(plist, "watchedFolders")? {
        let folders = watched.as_array().ok_or("Carpetas SwiftUI inválidas")?;
        let target = next["settings"]["watchedFolders"]
            .as_array_mut()
            .ok_or("Carpetas inválidas")?;
        for folder in folders {
            let path = folder["path"].as_str().ok_or("Carpeta SwiftUI sin ruta")?;
            if target.iter().any(|existing| existing["path"] == path) {
                continue;
            }
            target.push(json!({"id":format!("swift:{}",target.len()),"path":path,"name":Path::new(path).file_name().and_then(|v|v.to_str()).unwrap_or(path),"enabled":true,"style":folder["style"]}));
        }
    }
    if let Some(book) = setting_json(plist, "recipeBook")? {
        let mut code_keys = BTreeSet::new();
        let form_keys = book["forms"]
            .as_array()
            .ok_or("Recetas SwiftUI inválidas")?
            .iter()
            .map(|form| {
                form["key"]
                    .as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| "Receta SwiftUI sin clave".to_owned())
            })
            .collect::<Result<BTreeSet<_>, _>>()?;
        if let Some(default) = book["defaultKey"].as_str() {
            next["settings"]["defaultRecipeId"] = json!(default);
            code_keys.insert(default.to_owned());
        }
        for form in book["forms"]
            .as_array()
            .ok_or("Recetas SwiftUI inválidas")?
        {
            let id = form["key"].as_str().ok_or("Receta SwiftUI sin clave")?;
            if let Some(base) = form["base"].as_str() {
                code_keys.insert(base.to_owned());
            }
            if next["recipes"]
                .as_array()
                .is_some_and(|items| items.iter().any(|r| r["id"] == id))
            {
                continue;
            }
            let raw = book["values"][id].as_str().unwrap_or("{}");
            let mut values: Value = serde_json::from_str(raw)
                .map_err(|e| format!("Valores de receta SwiftUI inválidos: {e}"))?;
            remove_credentials(&mut values);
            next["recipes"].as_array_mut().ok_or("Recetas inválidas")?.push(json!({"id":id,"name":form["name"],"kind":"form","base":form["base"],"values":values}));
        }
        if !book["values"].is_null() && !book["values"].is_object() {
            return Err("Valores de recetas SwiftUI inválidos".into());
        }
        if let Some(saved) = book["values"].as_object() {
            code_keys.extend(saved.keys().cloned());
        }
        for id in code_keys.difference(&form_keys) {
            if next["recipes"]
                .as_array()
                .is_some_and(|items| items.iter().any(|recipe| recipe["id"] == id.as_str()))
            {
                continue;
            }
            let raw = book["values"][id].as_str().unwrap_or("{}");
            let mut values: Value = serde_json::from_str(raw)
                .map_err(|e| format!("Valores de receta SwiftUI {id} inválidos: {e}"))?;
            if !values.is_object() {
                return Err(format!("Valores de receta SwiftUI {id} no son un objeto"));
            }
            remove_credentials(&mut values);
            next["recipes"]
                .as_array_mut()
                .ok_or("Recetas inválidas")?
                .push(json!({"id":id,"name":id,"kind":"code","values":values,
                    "error":"Receta de código importada sin paquete compatible. Abre el proyecto y pulsa Compilar."}));
        }
    }
    for (setting, role) in [("sttResolvers", "stt"), ("llmResolvers", "llm")] {
        if let Some(resolvers) = setting_json(plist, setting)? {
            for resolver in resolvers["resolvers"]
                .as_array()
                .ok_or("Resolutores SwiftUI inválidos")?
            {
                if resolver["kind"] == "local" {
                    continue;
                }
                let id = resolver["id"].as_str().ok_or("Resolutor SwiftUI sin ID")?;
                if next["resolvers"]
                    .as_array()
                    .is_some_and(|items| items.iter().any(|r| r["id"] == id))
                {
                    continue;
                }
                next["resolvers"].as_array_mut().ok_or("Resolutores inválidos")?.push(json!({"id":id,"name":resolver["name"],"role":role,"local":false,"enabled":false,"url":resolver["baseURL"],"model":resolver["model"],"prompt":resolver["prompt"]}));
            }
        }
    }
    if let Some(accounts) = setting_json(plist, "connectorAccounts")? {
        for account in accounts.as_array().ok_or("Cuentas SwiftUI inválidas")? {
            let id = account["id"].as_str().ok_or("Cuenta SwiftUI sin ID")?;
            if next["accounts"]
                .as_array()
                .is_some_and(|items| items.iter().any(|r| r["id"] == id))
            {
                continue;
            }
            let provider = account["provider"].as_str().unwrap_or("");
            if provider != "notion" && provider != "okf" {
                continue;
            }
            next["accounts"].as_array_mut().ok_or("Cuentas inválidas")?.push(json!({"id":id,"name":account["name"],"provider":provider,"enabled":false,"origin":if provider == "notion" {Some("https://api.notion.com")} else {None},"folder":account["folder"]}));
        }
    }
    if let Some(connectors) = setting_json(plist, "connectors")? {
        for connector in connectors
            .as_array()
            .ok_or("Conectores SwiftUI inválidos")?
        {
            let id = connector["destinationID"]
                .as_str()
                .or_else(|| connector["id"].as_str())
                .ok_or("Destino SwiftUI sin ID")?;
            if next["destinations"]
                .as_array()
                .is_some_and(|items| items.iter().any(|r| r["id"] == id))
            {
                continue;
            }
            let provider = connector["provider"].as_str().unwrap_or("");
            if provider != "notion" && provider != "okf" {
                continue;
            }
            let config = connector["configurationJSON"].as_str().unwrap_or("{}");
            let mut config: Value = serde_json::from_str(config)
                .map_err(|e| format!("Configuración SwiftUI inválida: {e}"))?;
            remove_credentials(&mut config);
            next["destinations"].as_array_mut().ok_or("Destinos inválidos")?.push(json!({"id":id,"name":connector["name"],"provider":provider,"account":connector["accountID"],"enabled":false,"configuration":config}));
        }
    }
    Ok(())
}

fn remove_credentials(value: &mut Value) {
    match value {
        Value::Object(fields) => {
            fields.retain(|key, _| {
                let lower = key.to_ascii_lowercase();
                ![
                    "token",
                    "secret",
                    "credential",
                    "password",
                    "authorization",
                    "apikey",
                    "api_key",
                    "bearer",
                ]
                .iter()
                .any(|part| lower.contains(part))
            });
            for nested in fields.values_mut() {
                remove_credentials(nested);
            }
        }
        Value::Array(items) => {
            for item in items {
                remove_credentials(item);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::StagedDatabase;
    use std::fs;

    #[test]
    fn rejects_source_change_during_sqlite_and_wal_staging() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("swift");
        let target = dir.path().join("tauri");
        fs::create_dir_all(&source).unwrap();
        fs::create_dir_all(&target).unwrap();
        fs::write(source.join("library.sqlite"), b"same length a").unwrap();
        fs::write(source.join("library.sqlite-wal"), b"wal").unwrap();
        let error = StagedDatabase::copy_from_with(&source, &target, || {
            fs::write(source.join("library.sqlite"), b"same length b").unwrap();
        })
        .err()
        .unwrap();
        assert!(error.contains("cambió durante la copia"), "{error}");
        assert_eq!(
            fs::read(source.join("library.sqlite")).unwrap(),
            b"same length b"
        );
        assert!(!fs::read_dir(&target).unwrap().flatten().any(|entry| entry
            .file_name()
            .to_string_lossy()
            .starts_with(".swift-import-")));
    }
}
