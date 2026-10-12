use super::*;

impl Store {
    pub async fn jobs(&self) -> Result<Vec<Value>, String> {
        self.database.jobs().await
    }
    pub async fn jobs_active(&self) -> Result<Vec<Value>, String> {
        self.database.jobs_active().await
    }
    pub async fn jobs_for(&self, recording_id: &str) -> Result<Vec<Value>, String> {
        self.database.jobs_for(recording_id).await
    }
    pub async fn job(&self, id: &str) -> Result<Option<Value>, String> {
        self.database.job(id).await
    }
    pub async fn job_save(&mut self, job: &Value) -> Result<(), String> {
        self.recording_for_write(text(job, "recordingId")?)?;
        self.database.save_job(job).await
    }
    #[cfg(test)]
    pub async fn job_remove(&mut self, id: &str) -> Result<(), String> {
        self.database.remove_job(id).await
    }
    pub(super) fn memory_key(
        &self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
    ) -> Result<String, String> {
        if fingerprint.is_empty() {
            return Err("Falta la huella de memoria".into());
        }
        let record = self.recording_for_write(recording_id)?;
        if !record
            .versions
            .as_ref()
            .is_some_and(|versions| versions.iter().any(|version| version.id == version_id))
        {
            return Err("La versión no pertenece a la grabación".into());
        }
        Ok(json!([recording_id, version_id, fingerprint]).to_string())
    }
    pub async fn memory_recall(
        &self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
    ) -> Result<Option<Value>, String> {
        self.database
            .recall(&self.memory_key(recording_id, version_id, fingerprint)?)
            .await
    }
    pub async fn memory_keep(
        &mut self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
        value: &Value,
    ) -> Result<(), String> {
        self.database
            .keep(
                &self.memory_key(recording_id, version_id, fingerprint)?,
                recording_id,
                value,
            )
            .await
    }
    pub async fn trace_save(&mut self, trace: &Value) -> Result<(), String> {
        self.recording_for_write(text(trace, "recordingId")?)?;
        let mut trace = trace.clone();
        if trace["id"].as_str().is_none_or(str::is_empty) {
            trace["id"] = json!(id());
        }
        self.database.trace_save(&trace).await
    }
    pub async fn trace_list(&self, recording_id: Option<&str>) -> Result<Vec<Value>, String> {
        self.database.trace_list(recording_id).await
    }
}
