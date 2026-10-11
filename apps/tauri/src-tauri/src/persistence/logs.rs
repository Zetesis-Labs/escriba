use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
use surrealdb::method::Transaction;

pub const RETAINED: usize = 3000;
const TRIM_EVERY: usize = 64;
static APPENDED: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LogQuery {
    #[serde(default)]
    pub recording_id: Option<String>,
    #[serde(default)]
    pub before: Option<String>,
    #[serde(default)]
    pub limit: Option<usize>,
}

fn identity(entry: &Value) -> Result<(String, String), String> {
    let key = entry["id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .ok_or("Línea de registro sin identidad")?;
    if entry["at"].as_str().is_none() || entry["message"].as_str().is_none() {
        return Err("Línea de registro incompleta".into());
    }
    let parent = entry["recordingId"].as_str().unwrap_or_default();
    Ok((key.to_owned(), parent.to_owned()))
}

pub(super) async fn insert(tx: &Transaction<Db>, entry: &Value) -> Result<(), String> {
    let (key, parent) = identity(entry)?;
    tx.query("UPSERT type::record('log', $key) SET key = $key, parent = $parent, position = 0, payload = $payload")
        .bind(("key", key))
        .bind(("parent", parent))
        .bind(("payload", entry.clone()))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub(super) async fn append(db: &Surreal<Db>, entry: &Value) -> Result<(), String> {
    let tx = db.clone().begin().await.map_err(|e| e.to_string())?;
    match insert(&tx, entry).await {
        Ok(()) => tx.commit().await.map(|_| ()).map_err(|e| e.to_string())?,
        Err(error) => {
            tx.cancel().await.map_err(|e| e.to_string())?;
            return Err(error);
        }
    }
    if APPENDED
        .fetch_add(1, Ordering::Relaxed)
        .is_multiple_of(TRIM_EVERY)
    {
        trim(db).await?;
    }
    Ok(())
}

pub(super) async fn trim(db: &Surreal<Db>) -> Result<(), String> {
    let mut response = db
        .query("SELECT payload.at AS at FROM log ORDER BY at DESC LIMIT 1 START $retained")
        .bind(("retained", RETAINED as i64))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let rows: Vec<Value> = response.take(0).map_err(|e| e.to_string())?;
    let Some(cut) = rows.first().and_then(|row| row["at"].as_str()) else {
        return Ok(());
    };
    db.query("DELETE log WHERE payload.at <= $cut")
        .bind(("cut", cut.to_owned()))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub(super) async fn list(db: &Surreal<Db>, query: &LogQuery) -> Result<Vec<Value>, String> {
    let limit = query.limit.unwrap_or(RETAINED).clamp(1, RETAINED);
    let mut response = db
        .query("SELECT payload, payload.at AS at FROM log WHERE ($recording = NONE OR payload.recordingId = $recording) AND ($before = NONE OR payload.at < $before) ORDER BY at DESC LIMIT $limit")
        .bind(("recording", query.recording_id.clone()))
        .bind(("before", query.before.clone()))
        .bind(("limit", limit as i64))
        .await
        .map_err(|e| e.to_string())?
        .check()
        .map_err(|e| e.to_string())?;
    let rows: Vec<Value> = response.take(0).map_err(|e| e.to_string())?;
    Ok(rows
        .into_iter()
        .map(|mut row| row["payload"].take())
        .collect())
}
