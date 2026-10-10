use super::*;

impl Store {
    pub fn jobs(&self) -> Result<Vec<Value>, String> {
        self.database.jobs()
    }
    pub fn job_save(&mut self, job: &Value) -> Result<(), String> {
        self.recording_for_write(text(job, "recordingId")?)?;
        self.database.save_job(job)
    }
    #[cfg(test)]
    pub fn job_remove(&mut self, id: &str) -> Result<(), String> {
        self.database.remove_job(id)
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
    pub fn memory_recall(
        &self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
    ) -> Result<Option<Value>, String> {
        self.database
            .recall(&self.memory_key(recording_id, version_id, fingerprint)?)
    }
    pub fn memory_keep(
        &mut self,
        recording_id: &str,
        version_id: &str,
        fingerprint: &str,
        value: &Value,
    ) -> Result<(), String> {
        self.database.keep(
            &self.memory_key(recording_id, version_id, fingerprint)?,
            recording_id,
            value,
        )
    }
    pub fn trace_save(&mut self, trace: &Value) -> Result<(), String> {
        self.recording_for_write(text(trace, "recordingId")?)?;
        let mut trace = trace.clone();
        if trace["id"].as_str().is_none_or(str::is_empty) {
            trace["id"] = json!(id());
        }
        self.database.trace_save(&trace)
    }
    pub fn trace_list(&self, recording_id: Option<&str>) -> Result<Vec<Value>, String> {
        self.database.trace_list(recording_id)
    }
}
