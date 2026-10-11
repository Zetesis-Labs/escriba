use super::*;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SavedLibraryFilter {
    pub id: String,
    pub name: String,
    pub ontology_id: String,
    pub sql: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveLibraryFilter {
    pub id: Option<String>,
    pub name: String,
    pub ontology_id: String,
    pub sql: String,
}

async fn listed(db: &Surreal<Db>) -> Result<Vec<SavedLibraryFilter>, String> {
    let mut response = db
        .query("SELECT VALUE payload FROM library_filter")
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    let rows: Vec<Value> = response.take(0).map_err(error)?;
    let mut filters: Vec<SavedLibraryFilter> = rows
        .into_iter()
        .map(serde_json::from_value)
        .collect::<Result<_, _>>()
        .map_err(|e| format!("No se pudieron leer los filtros guardados: {e}"))?;
    filters.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then(a.id.cmp(&b.id))
    });
    Ok(filters)
}

impl Knowledge {
    pub async fn saved_filters(&self) -> Result<Vec<SavedLibraryFilter>, String> {
        let root = self.root.lock().await;
        listed(&root).await
    }

    pub async fn save_filter(
        &self,
        request: SaveLibraryFilter,
    ) -> Result<SavedLibraryFilter, String> {
        let name = request.name.trim();
        let sql = request.sql.trim();
        if name.is_empty() || name.chars().count() > 120 {
            return Err("El nombre del filtro debe tener entre 1 y 120 caracteres".into());
        }
        if sql.is_empty() || sql.len() > 65_536 {
            return Err("La consulta debe tener contenido y ocupar como máximo 64 KiB".into());
        }
        base_query::validate(sql)
            .map_err(|e| format!("El filtro debe ser una consulta de lectura: {e}"))?;
        let root = self.root.lock().await;
        if manifest(&selected(&root, &request.ontology_id).await?)
            .await?
            .is_none()
        {
            return Err("La ontología del filtro no está instalada".into());
        }
        let current = listed(&root).await?;
        if let Some(id) = &request.id {
            if !current.iter().any(|filter| filter.id == *id) {
                return Err("El filtro guardado ya no existe".into());
            }
        } else if current.len() >= 256 {
            return Err("La biblioteca admite hasta 256 filtros guardados".into());
        }
        if current.iter().any(|filter| {
            Some(&filter.id) != request.id.as_ref()
                && filter.name.to_lowercase() == name.to_lowercase()
        }) {
            return Err("Ya existe un filtro con ese nombre".into());
        }
        let saved = SavedLibraryFilter {
            id: request.id.unwrap_or_else(|| Uuid::new_v4().to_string()),
            name: name.into(),
            ontology_id: request.ontology_id,
            sql: sql.into(),
        };
        root.query("UPSERT type::record('library_filter', $id) SET payload = $filter")
            .bind(("id", saved.id.clone()))
            .bind(("filter", serde_json::to_value(&saved).map_err(error)?))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        Ok(saved)
    }

    pub async fn remove_filter(&self, id: &str) -> Result<(), String> {
        if Uuid::parse_str(id).is_err() {
            return Err("Identificador de filtro inválido".into());
        }
        self.root
            .lock()
            .await
            .query("DELETE type::record('library_filter', $id)")
            .bind(("id", id.to_string()))
            .await
            .map_err(error)?
            .check()
            .map_err(error)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn draft(name: &str) -> SaveLibraryFilter {
        SaveLibraryFilter {
            id: None,
            name: name.into(),
            ontology_id: "escriba".into(),
            sql: "SELECT VALUE id FROM person WHERE name = 'Ana'".into(),
        }
    }

    #[tokio::test]
    async fn conserva_y_edita_filtros_al_reabrir_sin_cambiar_su_identidad() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("knowledge.surrealkv");
        let knowledge = Knowledge::open(&path).await.unwrap();
        let saved = knowledge.save_filter(draft("  Ana  ")).await.unwrap();
        assert_eq!(saved.name, "Ana");
        knowledge.close().await.unwrap();
        let knowledge = Knowledge::open(&path).await.unwrap();
        assert_eq!(
            knowledge.saved_filters().await.unwrap(),
            vec![saved.clone()]
        );
        let mut changed = draft("Notas de Ana");
        changed.id = Some(saved.id.clone());
        let edited = knowledge.save_filter(changed).await.unwrap();
        assert_eq!(edited.id, saved.id);
        assert_eq!(knowledge.saved_filters().await.unwrap(), vec![edited]);
        knowledge.remove_filter(&saved.id).await.unwrap();
        assert!(knowledge.saved_filters().await.unwrap().is_empty());
        knowledge.close().await.unwrap();
    }

    #[tokio::test]
    async fn rechaza_consultas_con_efectos_y_conserva_los_filtros_anteriores() {
        let temp = tempfile::tempdir().unwrap();
        let knowledge = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
            .await
            .unwrap();
        let saved = knowledge.save_filter(draft("Ana")).await.unwrap();
        for sql in [
            "DELETE person",
            "RETURN (UPDATE person SET name = 'Otro')",
            "USE NS knowledge DB registry; SELECT * FROM ontology",
            "RETURN fn::cambiar()",
        ] {
            let mut invalid = draft("No guardar");
            invalid.sql = sql.into();
            assert!(knowledge.save_filter(invalid).await.is_err(), "{sql}");
        }
        assert!(knowledge.save_filter(draft("ana")).await.is_err());
        let mut missing = draft("Ausente");
        missing.ontology_id = "no-instalada".into();
        assert!(knowledge.save_filter(missing).await.is_err());
        let mut stale = draft("Borrado");
        stale.id = Some(Uuid::new_v4().to_string());
        assert!(knowledge.save_filter(stale).await.is_err());
        assert_eq!(knowledge.saved_filters().await.unwrap(), vec![saved]);
        let private = knowledge
            .query(
                "escriba",
                1,
                "SELECT * FROM library_filter",
                serde_json::json!({}),
            )
            .await
            .unwrap_err();
        assert!(
            private.contains("table 'library_filter' does not exist"),
            "{private}"
        );
        knowledge.close().await.unwrap();
    }
}
