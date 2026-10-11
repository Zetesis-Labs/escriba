use super::*;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SavedLibraryFilter {
    pub id: String,
    pub name: String,
    pub filter: LibraryFilter,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveLibraryFilter {
    pub id: Option<String>,
    pub name: String,
    pub filter: LibraryFilter,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LegacySavedLibraryFilter {
    id: String,
    name: String,
    ontology_id: String,
    sql: String,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum StoredLibraryFilter {
    Current(SavedLibraryFilter),
    Legacy(LegacySavedLibraryFilter),
}

impl From<StoredLibraryFilter> for SavedLibraryFilter {
    fn from(value: StoredLibraryFilter) -> Self {
        match value {
            StoredLibraryFilter::Current(filter) => filter,
            StoredLibraryFilter::Legacy(legacy) => Self {
                id: legacy.id,
                name: legacy.name,
                filter: LibraryFilter::Surrealql {
                    ontology_id: legacy.ontology_id,
                    sql: legacy.sql,
                },
            },
        }
    }
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
        .map(|row| serde_json::from_value::<StoredLibraryFilter>(row).map(Into::into))
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

async fn validate_filter(db: &Surreal<Db>, filter: &mut LibraryFilter) -> Result<(), String> {
    if matches!(filter, LibraryFilter::Visual { .. })
        && serde_json::to_vec(filter).map_err(error)?.len() > 65_536
    {
        return Err("El filtro visual ocupa más de 64 KiB".into());
    }
    match filter {
        LibraryFilter::Surrealql { ontology_id, sql } => {
            let trimmed = sql.trim();
            if trimmed.is_empty() || trimmed.len() > 65_536 {
                return Err("La consulta debe tener contenido y ocupar como máximo 64 KiB".into());
            }
            base_query::validate(trimmed)
                .map_err(|e| format!("El filtro debe ser una consulta de lectura: {e}"))?;
            *sql = trimmed.into();
            if manifest(&selected(db, ontology_id).await?).await?.is_none() {
                return Err("La ontología del filtro no está instalada".into());
            }
        }
        LibraryFilter::Visual { conditions, .. } => {
            if conditions.is_empty() || conditions.len() > 32 {
                return Err("El filtro necesita entre 1 y 32 condiciones".into());
            }
            for condition in conditions {
                let selected_db = selected(db, &condition.ontology_id).await?;
                let definition = manifest(&selected_db)
                    .await?
                    .ok_or("La ontología del filtro no está instalada")?;
                let collection = filters::declared(&definition, &condition.table)?;
                filters::predicate(condition, collection)?;
            }
        }
    }
    Ok(())
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
        if name.is_empty() || name.chars().count() > 120 {
            return Err("El nombre del filtro debe tener entre 1 y 120 caracteres".into());
        }
        let root = self.root.lock().await;
        let mut filter = request.filter;
        validate_filter(&root, &mut filter).await?;
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
            filter,
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
    use serde_json::json;

    fn draft(name: &str) -> SaveLibraryFilter {
        SaveLibraryFilter {
            id: None,
            name: name.into(),
            filter: LibraryFilter::Surrealql {
                ontology_id: "escriba".into(),
                sql: "SELECT VALUE id FROM person WHERE name = 'Ana'".into(),
            },
        }
    }

    fn visual(name: &str, mode: &str) -> SaveLibraryFilter {
        serde_json::from_value(json!({
            "name": name,
            "filter": {
                "kind": "visual", "match": mode,
                "conditions": [
                    {"ontologyId":"escriba","table":"recording","field":"title","operator":"contains","value":"Prueba"},
                    {"ontologyId":"escriba","table":"segment","field":"start","operator":"gte","value":1.5},
                    {"ontologyId":"escriba","table":"person","field":"name","operator":"empty"}
                ]
            }
        }))
        .unwrap()
    }

    #[tokio::test]
    async fn conserva_filtros_visuales_all_y_any_con_valores_tipados_y_permita_editar_y_eliminar() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("knowledge.surrealkv");
        let knowledge = Knowledge::open(&path).await.unwrap();
        let all = knowledge.save_filter(visual("Todas", "all")).await.unwrap();
        let any = knowledge
            .save_filter(visual("Cualquiera", "any"))
            .await
            .unwrap();
        knowledge.close().await.unwrap();
        let knowledge = Knowledge::open(&path).await.unwrap();
        let listed = knowledge.saved_filters().await.unwrap();
        assert_eq!(listed, vec![any.clone(), all.clone()]);
        assert_eq!(
            serde_json::to_value(&all.filter).unwrap()["conditions"][1]["value"],
            1.5
        );
        let mut changed = visual("Editado", "any");
        changed.id = Some(all.id.clone());
        let edited = knowledge.save_filter(changed).await.unwrap();
        assert_eq!(edited.id, all.id);
        assert_eq!(
            knowledge.saved_filters().await.unwrap(),
            vec![any.clone(), edited]
        );
        knowledge.remove_filter(&any.id).await.unwrap();
        knowledge.close().await.unwrap();
        let reopened = Knowledge::open(&path).await.unwrap();
        assert_eq!(reopened.saved_filters().await.unwrap().len(), 1);
        reopened.close().await.unwrap();
    }

    #[tokio::test]
    async fn lista_sql_antiguo_junto_a_visual_y_lo_edita_sin_cambiar_identidad() {
        let temp = tempfile::tempdir().unwrap();
        let knowledge = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
            .await
            .unwrap();
        let id = Uuid::new_v4().to_string();
        knowledge.root.lock().await.query("UPSERT type::record('library_filter', $id) SET payload = $payload")
            .bind(("id", id.clone()))
            .bind(("payload", json!({"id":id,"name":"Anterior","ontologyId":"escriba","sql":"SELECT VALUE id FROM person"})))
            .await.unwrap().check().unwrap();
        let saved_visual = knowledge
            .save_filter(visual("Visual", "all"))
            .await
            .unwrap();
        let listed = knowledge.saved_filters().await.unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].id, id);
        assert_eq!(
            listed[0].filter,
            LibraryFilter::Surrealql {
                ontology_id: "escriba".into(),
                sql: "SELECT VALUE id FROM person".into()
            }
        );
        assert_eq!(listed[1], saved_visual);
        let mut changed = visual("Actualizado", "any");
        changed.id = Some(id.clone());
        assert_eq!(knowledge.save_filter(changed).await.unwrap().id, id);
        knowledge.close().await.unwrap();
    }

    #[tokio::test]
    async fn rechazos_visuales_no_alteran_filtro_ya_guardado_y_corrupcion_es_visible() {
        let temp = tempfile::tempdir().unwrap();
        let knowledge = Knowledge::open(&temp.path().join("knowledge.surrealkv"))
            .await
            .unwrap();
        let saved = knowledge
            .save_filter(visual("Válido", "all"))
            .await
            .unwrap();
        for condition in [
            json!({"ontologyId":"ausente","table":"recording","field":"title","operator":"eq","value":"X"}),
            json!({"ontologyId":"escriba","table":"ausente","field":"title","operator":"eq","value":"X"}),
            json!({"ontologyId":"escriba","table":"recording","field":"ausente","operator":"eq","value":"X"}),
            json!({"ontologyId":"escriba","table":"segment","field":"start","operator":"contains","value":3}),
            json!({"ontologyId":"escriba","table":"segment","field":"start","operator":"gt","value":"tres"}),
        ] {
            let request: SaveLibraryFilter = serde_json::from_value(json!({"id":saved.id,"name":"Válido","filter":{"kind":"visual","match":"all","conditions":[condition]}})).unwrap();
            assert!(knowledge.save_filter(request).await.is_err());
            assert_eq!(
                knowledge.saved_filters().await.unwrap(),
                vec![saved.clone()]
            );
        }
        let empty: SaveLibraryFilter = serde_json::from_value(
            json!({"name":"vacío","filter":{"kind":"visual","match":"all","conditions":[]}}),
        )
        .unwrap();
        assert!(knowledge.save_filter(empty).await.is_err());
        let repeated = vec![
            json!({"ontologyId":"escriba","table":"recording","field":"title","operator":"eq","value":"X"});
            33
        ];
        let too_many: SaveLibraryFilter = serde_json::from_value(json!({"name":"demasiadas","filter":{"kind":"visual","match":"all","conditions":repeated}})).unwrap();
        assert!(knowledge.save_filter(too_many).await.is_err());
        let oversized: SaveLibraryFilter = serde_json::from_value(json!({"name":"grande","filter":{"kind":"visual","match":"all","conditions":[{"ontologyId":"escriba","table":"recording","field":"title","operator":"eq","value":"x".repeat(65_536)}]}})).unwrap();
        assert!(knowledge.save_filter(oversized).await.is_err());
        assert_eq!(knowledge.saved_filters().await.unwrap(), vec![saved]);
        knowledge
            .root
            .lock()
            .await
            .query(
                "UPSERT type::record('library_filter', 'corrupt') SET payload = { name: 'roto' }",
            )
            .await
            .unwrap()
            .check()
            .unwrap();
        assert!(knowledge
            .saved_filters()
            .await
            .unwrap_err()
            .contains("No se pudieron leer"));
        knowledge.close().await.unwrap();
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
            invalid.filter = LibraryFilter::Surrealql {
                ontology_id: "escriba".into(),
                sql: sql.into(),
            };
            assert!(knowledge.save_filter(invalid).await.is_err(), "{sql}");
        }
        assert!(knowledge.save_filter(draft("ana")).await.is_err());
        let mut missing = draft("Ausente");
        missing.filter = LibraryFilter::Surrealql {
            ontology_id: "no-instalada".into(),
            sql: "SELECT VALUE id FROM person".into(),
        };
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
