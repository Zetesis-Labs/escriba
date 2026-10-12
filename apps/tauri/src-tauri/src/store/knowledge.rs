use super::Store;
#[cfg(test)]
use crate::persistence::CoreChange;

impl Store {
    pub async fn knowledge_prepare(&self, epoch: &str) -> Result<(), String> {
        self.database.knowledge_prepare(epoch).await
    }
    #[cfg(test)]
    pub async fn knowledge_change(&self) -> Result<Option<CoreChange>, String> {
        self.database.knowledge_change().await
    }
    pub async fn knowledge_ack(&self, key: &str, revision: &str) -> Result<(), String> {
        self.database.knowledge_ack(key, revision).await
    }
}

#[cfg(test)]
mod tests {
    use super::super::*;

    #[tokio::test]
    async fn knowledge_journal_conserva_cambios_pendientes_y_no_expone_campos_privados() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("sintetico.wav");
        fs::write(&audio, b"audio sintetico").unwrap();
        let root = dir.path().join("library");
        let mut store = Store::open(root.clone()).await.unwrap();
        assert!(store.knowledge_change().await.unwrap().is_none());
        let recording = store.import(&audio, None).await.unwrap();
        let id = recording["id"].as_str().unwrap();
        let initial = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(initial.kind, "recording");
        assert_eq!(initial.id, id);
        store.mutate("version_save", &json!({"recordingId":id,"transcript":{"text":"sintético","segments":[{"start":0,"end":1,"text":"sintético","words":[{"start":0,"end":1,"text":"sintético","secret":"prohibido"}],"private":"prohibido"}],"private":"prohibido"},"inputs":{"secret":"prohibido"}})).await.unwrap();
        store
            .knowledge_ack(&initial.key, &initial.revision)
            .await
            .unwrap();
        let changed = store.knowledge_change().await.unwrap().unwrap();
        assert_ne!(initial.revision, changed.revision);
        let value = changed.value.as_ref().unwrap();
        assert_eq!(
            value["versions"][0]["transcript"]["segments"][0]["words"][0]["text"],
            "sintético"
        );
        assert!(value.get("audioPath").is_none());
        assert!(!value.to_string().contains("prohibido"));
        drop(store);
        let mut store = Store::open(root).await.unwrap();
        let pending = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(changed.revision, pending.revision);
        store
            .knowledge_ack(&pending.key, &pending.revision)
            .await
            .unwrap();
        assert!(store.knowledge_change().await.unwrap().is_none());
        store
            .mutate("recording_discard", &json!({"id":id}))
            .await
            .unwrap();
        let removed = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(removed.id, id);
        assert!(removed.value.is_none());
    }

    #[tokio::test]
    async fn knowledge_journal_personas_conserva_identidad_al_editar_y_omite_biometria() {
        let dir = tempfile::tempdir().unwrap();
        let store = Store::open(dir.path().join("library")).await.unwrap();
        let voice = SpeakerVoice {
            speaker: "Speaker 1".into(),
            model: "modelo privado".into(),
            embedding: vec![0.25, 0.75],
        };
        store
            .add_person_voice("Ana", &voice, "ruta privada")
            .await
            .unwrap();
        let created = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(created.kind, "person");
        let value = created.value.unwrap();
        assert_eq!(value["id"], created.id);
        assert_eq!(value["name"], "Ana");
        assert_eq!(value.as_object().unwrap().len(), 3);
        assert!(value["createdAt"].is_string());
        store
            .knowledge_ack(&created.key, &created.revision)
            .await
            .unwrap();
        store.rename_person("Ana", "Ana María").await.unwrap();
        store
            .set_person_color("Ana María", "#123456")
            .await
            .unwrap();
        let updated = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(created.id, updated.id);
        assert_eq!(updated.value.as_ref().unwrap()["name"], "Ana María");
        assert_eq!(updated.value.as_ref().unwrap()["color"], "#123456");
        store
            .knowledge_ack(&updated.key, &updated.revision)
            .await
            .unwrap();
        store.remove_person("Ana María").await.unwrap();
        let deleted = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(created.id, deleted.id);
        assert!(deleted.value.is_none());
    }

    #[tokio::test]
    async fn knowledge_journal_incorpora_biblioteca_anterior_una_vez_y_detecta_borrado() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let audio = dir.path().join("sintetico.wav");
        fs::write(&audio, b"audio sintetico").unwrap();
        let mut store = Store::open(root.clone()).await.unwrap();
        let recording = store.import(&audio, None).await.unwrap();
        let id = recording["id"].as_str().unwrap();
        store.database.query_test("REMOVE EVENT knowledge_changed ON recording; REMOVE EVENT knowledge_changed ON version; REMOVE EVENT knowledge_changed ON person; REMOVE TABLE knowledge_dirty; REMOVE TABLE knowledge_meta").await.unwrap();
        drop(store);
        let mut store = Store::open(root.clone()).await.unwrap();
        let pending = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(pending.id, id);
        assert_eq!(pending.value.as_ref().unwrap()["id"], id);
        store
            .knowledge_ack(&pending.key, &pending.revision)
            .await
            .unwrap();
        drop(store);
        store = Store::open(root).await.unwrap();
        assert!(store.knowledge_change().await.unwrap().is_none());
        store
            .mutate("recording_delete", &json!({"id":id}))
            .await
            .unwrap();
        let deleted = store.knowledge_change().await.unwrap().unwrap();
        assert_eq!(deleted.id, id);
        assert!(deleted.value.is_none());
    }

    #[tokio::test]
    async fn knowledge_journal_reconstruye_proyeccion_nueva_sin_perder_borrados_pendientes() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let audio = dir.path().join("sintetico.wav");
        fs::write(&audio, b"audio sintetico").unwrap();
        let mut store = Store::open(root.clone()).await.unwrap();
        let recording = store.import(&audio, None).await.unwrap();
        store
            .add_person_voice(
                "Ana",
                &SpeakerVoice {
                    speaker: "Speaker 1".into(),
                    model: "sintetico".into(),
                    embedding: vec![0.5],
                },
                "sintetico",
            )
            .await
            .unwrap();
        store.knowledge_prepare("primera").await.unwrap();
        let mut initial = Vec::new();
        while let Some(change) = store.knowledge_change().await.unwrap() {
            store
                .knowledge_ack(&change.key, &change.revision)
                .await
                .unwrap();
            initial.push(change);
        }
        assert_eq!(initial.len(), 2);
        store.knowledge_prepare("primera").await.unwrap();
        assert!(store.knowledge_change().await.unwrap().is_none());
        store.knowledge_prepare("segunda").await.unwrap();
        for old in &initial {
            store.knowledge_ack(&old.key, &old.revision).await.unwrap();
        }
        let mut rebuilt = Vec::new();
        while let Some(change) = store.knowledge_change().await.unwrap() {
            store
                .knowledge_ack(&change.key, &change.revision)
                .await
                .unwrap();
            rebuilt.push(change);
        }
        assert_eq!(rebuilt.len(), 2);
        assert!(rebuilt.iter().all(|change| change.value.is_some()));
        assert_eq!(
            rebuilt
                .iter()
                .find(|change| change.kind == "recording")
                .unwrap()
                .id,
            recording["id"]
        );
        drop(store);
        store = Store::open(root).await.unwrap();
        store.knowledge_prepare("segunda").await.unwrap();
        assert!(store.knowledge_change().await.unwrap().is_none());
        store.remove_person("Ana").await.unwrap();
        store.knowledge_prepare("tercera").await.unwrap();
        let mut deletion = false;
        let mut recording_retained = false;
        while let Some(change) = store.knowledge_change().await.unwrap() {
            deletion |= change.kind == "person" && change.value.is_none();
            recording_retained |= change.kind == "recording" && change.value.is_some();
            store
                .knowledge_ack(&change.key, &change.revision)
                .await
                .unwrap();
        }
        assert!(deletion && recording_retained);
    }

    #[tokio::test]
    async fn knowledge_journal_corrupcion_falla_visiblemente_y_conserva_la_proyeccion_previa() {
        let dir = tempfile::tempdir().unwrap();
        let audio = dir.path().join("sintetico.wav");
        fs::write(&audio, b"audio sintetico").unwrap();
        let mut store = Store::open(dir.path().join("library")).await.unwrap();
        let recording = store.import(&audio, None).await.unwrap();
        let id = recording["id"].as_str().unwrap();
        store.mutate("version_save", &json!({"recordingId":id,"transcript":{"text":"Texto íntegro","segments":[{"start":0,"end":1,"text":"Texto íntegro"}]}})).await.unwrap();
        let store = crate::library::Library::new(store).await.unwrap();
        let graph = crate::knowledge::Knowledge::open(&dir.path().join("knowledge.rocksdb"))
            .await
            .unwrap();
        let initial = crate::knowledge_commands::call(
            &graph,
            &store,
            "knowledge_records",
            json!({"id":"escriba","table":"segment"}),
        )
        .await
        .unwrap();
        assert_eq!(initial["records"][0]["values"]["text"], "Texto íntegro");
        for assignment in [
            "payload.transcript.segments = 'dato corrupto'",
            "payload.transcript.segments = [], payload.transcript.text = 42",
        ] {
            let query = format!("UPDATE version SET {assignment} WHERE parent = '{id}'");
            store
                .with_store(move |store| {
                    Box::pin(async move { store.database.query_test(&query).await })
                })
                .await
                .unwrap();
            for _ in 0..2 {
                let failure = crate::knowledge_commands::call(
                    &graph,
                    &store,
                    "knowledge_records",
                    json!({"id":"escriba","table":"segment"}),
                )
                .await
                .unwrap_err();
                assert!(failure.contains("Versión guardada inválida"), "{failure}");
                assert!(store.knowledge_change().await.is_err());
                let preserved = graph
                    .query("escriba", 1, "SELECT VALUE text FROM segment", json!({}))
                    .await
                    .unwrap();
                assert_eq!(preserved, vec![json!(["Texto íntegro"])]);
            }
        }
        graph.close().await.unwrap();
    }
}
