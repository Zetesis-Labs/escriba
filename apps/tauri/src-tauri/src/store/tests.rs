use super::*;

#[test]
fn abrir_la_lista_no_retiene_transcripciones_y_el_detalle_conserva_el_original() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("sintetico.wav");
    fs::write(&audio, b"audio de prueba").unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let recording = store.import(&audio, None).unwrap();
    let key = recording["id"].as_str().unwrap();
    let transcript = json!({"text":"contenido ".repeat(1000),"segments":[{"start":0,"end":1,"text":"segmento completo","words":[{"start":0,"end":1,"text":"palabra completa"}]}],"extension":{"retain":true}});
    let version = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":transcript}),
        )
        .unwrap();
    drop(store);
    let mut reopened = Store::open(root).unwrap();
    let cached = reopened.data.recordings[0].versions.as_ref().unwrap()[0]
        .transcript
        .as_ref()
        .unwrap();
    assert!(
        cached.segments.is_empty(),
        "La lista conserva segmentos completos en RAM"
    );
    assert!(cached.text.chars().count() <= 400);
    assert_eq!(reopened.recording(key).unwrap()["versions"][0], version);
    reopened
        .mutate(
            "settings_save",
            &json!({"settings":{"notifyEveryNote":false}}),
        )
        .unwrap();
    reopened
        .mutate(
            "recording_update",
            &json!({"id":key,"title":"Título nuevo"}),
        )
        .unwrap();
    assert_eq!(
        reopened.recording(key).unwrap()["versions"][0]["transcript"],
        transcript
    );
    assert!(reopened.data.recordings[0].versions.as_ref().unwrap()[0]
        .transcript
        .as_ref()
        .unwrap()
        .segments
        .is_empty());
}
use crate::voices::SpeakerVoice;

#[test]
fn fecha_de_incorporacion_usa_la_del_fichero_solo_para_captura_recuperada() {
    let imported_at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_750_000_000);
    let captured_at = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);

    assert_eq!(
        import_created_at(Some(captured_at), imported_at),
        "2023-11-14T22:13:20+00:00"
    );
    assert_eq!(
        import_created_at(None, imported_at),
        "2025-06-15T15:06:40+00:00"
    );
}

#[test]
fn captura_recuperada_conserva_la_fecha_del_fichero_tras_reabrir_la_biblioteca() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let capture = dir.path().join("captura.m4a");
    fs::write(&capture, b"audio sintetico").unwrap();
    File::open(&capture)
        .unwrap()
        .set_modified(std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000))
        .unwrap();

    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import_recovered_capture(&capture).unwrap();
    assert_eq!(record["createdAt"], "2023-11-14T22:13:20+00:00");
    drop(store);

    let reopened = Store::open(root).unwrap();
    assert_eq!(
        reopened.recording(record["id"].as_str().unwrap()).unwrap()["createdAt"],
        "2023-11-14T22:13:20+00:00"
    );
}

#[test]
fn las_personas_guardan_varias_huellas_privadas_y_solo_exponen_metadatos() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let store = Store::open(root.clone()).unwrap();
    let first = SpeakerVoice {
        speaker: "Speaker 1".into(),
        model: "m".into(),
        embedding: vec![0.123456, -0.654321],
    };
    let second = SpeakerVoice {
        speaker: "Speaker 2".into(),
        model: "m".into(),
        embedding: vec![0.5, 0.5],
    };
    store.add_person_voice("Rubén", &first, "a").unwrap();
    store.add_person_voice("Rubén", &second, "b").unwrap();
    let people = store.people().unwrap();
    assert_eq!(people.as_array().unwrap().len(), 1);
    assert_eq!(people[0]["name"], "Rubén");
    assert_eq!(people[0]["voices"].as_array().unwrap().len(), 2);
    assert_eq!(people[0]["voices"][0]["source"], "a");
    assert!(people.to_string().find("embedding").is_none());
    assert_eq!(store.known_voices().unwrap().len(), 2);
    assert!(!store.snapshot().unwrap().to_string().contains("0.123456"));
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert_eq!(reopened.known_voices().unwrap().len(), 2);
}

#[test]
fn renombrar_juntar_y_quitar_huellas_conserva_solo_personas_con_voz() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(dir.path().join("library")).unwrap();
    for (name, source, embedding) in [
        ("Ruben", "a", vec![1.0, 0.0]),
        ("Ruben", "b", vec![0.9, 0.1]),
        ("Rubén G.", "c", vec![0.0, 1.0]),
        ("Ana", "d", vec![1.0, 1.0]),
    ] {
        store
            .add_person_voice(
                name,
                &SpeakerVoice {
                    speaker: "S".into(),
                    model: "m".into(),
                    embedding,
                },
                source,
            )
            .unwrap();
    }
    let redundant = store
        .people()
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .find(|person| person["name"] == "Ruben")
        .unwrap()["voices"][1]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    store.remove_person_voice(&redundant).unwrap();
    store.rename_person("Ruben", "Rubén").unwrap();
    store.rename_person("Rubén G.", "Rubén").unwrap();
    store.remove_person("Ana").unwrap();
    let people = store.people().unwrap();
    assert_eq!(people.as_array().unwrap().len(), 1);
    assert_eq!(people[0]["name"], "Rubén");
    assert_eq!(
        people[0]["voices"]
            .as_array()
            .unwrap()
            .iter()
            .map(|voice| voice["source"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["a", "c"]
    );
    let first = people[0]["voices"][0]["id"].as_str().unwrap().to_owned();
    let last = people[0]["voices"][1]["id"].as_str().unwrap().to_owned();
    store.remove_person_voice(&first).unwrap();
    store.remove_person_voice(&last).unwrap();
    assert!(store.people().unwrap().as_array().unwrap().is_empty());
}

#[test]
fn transcribir_reconoce_sin_exponer_huellas_y_la_version_las_conserva() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let audio = dir.path().join("sample.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let recording = store.import(&audio, None).unwrap();
    let key = recording["id"].as_str().unwrap();
    store
        .add_person_voice(
            "Rubén",
            &SpeakerVoice {
                speaker: "S".into(),
                model: "m".into(),
                embedding: vec![1.0, 0.0],
            },
            "muestra de voz",
        )
        .unwrap();
    let transcript = store.recognize_transcription(key, json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0.0,"end":1.0,"text":"hola","words":[]}],"voices":[{"speaker":"Speaker 1","model":"m","embedding":[1.0,0.01]}]})).unwrap();
    assert_eq!(transcript["segments"][0]["speaker"], "Rubén");
    let person_id = store.people().unwrap()[0]["id"]
        .as_str()
        .unwrap()
        .to_string();
    assert_eq!(transcript["segments"][0]["personId"], person_id);
    assert_eq!(transcript["recognitions"][0]["speaker"], "Speaker 1");
    assert!(!transcript.to_string().contains("embedding"));
    let version = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"backend":"local-stt","transcript":transcript}),
        )
        .unwrap();
    assert_eq!(version["hasVoices"], true);
    assert_eq!(
        store
            .version_voices(version["id"].as_str().unwrap())
            .unwrap()[0]
            .speaker,
        "Rubén"
    );
    assert!(!store.snapshot().unwrap().to_string().contains("embedding"));
    assert!(!store.library().to_string().contains("embedding"));
    assert!(!store
        .recording(key)
        .unwrap()
        .to_string()
        .contains("embedding"));
    assert!(!store
        .runtime_context(Some(key))
        .unwrap()
        .to_string()
        .contains("embedding"));
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert_eq!(
        reopened
            .version_voices(version["id"].as_str().unwrap())
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn copiar_version_reetiqueta_huellas_y_rechaza_origen_de_otra_nota() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("sample.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let other = dir.path().join("other.wav");
    fs::write(&other, b"other synthetic audio").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let key = store.import(&audio, None).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let other_key = store.import(&other, None).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    store
        .add_person_voice(
            "Rubén",
            &SpeakerVoice {
                speaker: "S".into(),
                model: "m".into(),
                embedding: vec![1.0, 0.0],
            },
            "muestra",
        )
        .unwrap();
    let recognized = store.recognize_transcription(&key, json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0,"end":1,"text":"hola","words":[]}],"voices":[{"speaker":"Speaker 1","model":"m","embedding":[1.0,0.01]}]})).unwrap();
    let source = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":recognized}),
        )
        .unwrap();
    let source_id = source["id"].as_str().unwrap();
    assert!(store.mutate("version_save", &json!({"recordingId":other_key,"sourceVersionId":source_id,"transcript":{"text":"otra","segments":[]}})).is_err());
    let corrected = json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0,"end":1,"text":"hola","words":[]}],"recognitions":[]});
    let copy = store.mutate("version_save", &json!({"recordingId":key,"sourceVersionId":source_id,"backend":"correccion","transcript":corrected})).unwrap();
    assert_eq!(copy["hasVoices"], true);
    assert_eq!(
        store.version_voices(copy["id"].as_str().unwrap()).unwrap()[0].speaker,
        "Speaker 1"
    );
    assert_eq!(store.version_voices(source_id).unwrap()[0].speaker, "Rubén");
}

#[test]
fn corregir_ensena_huellas_atomicamente_y_fusion_sin_persona_solo_reetiqueta() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("sample.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let key = store.import(&audio, None).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let transcript = store.recognize_transcription(&key, json!({"text":"hola","segments":[{"speaker":"Speaker 1","start":0,"end":1,"text":"hola","words":[]}],"voices":[{"speaker":"Speaker 1","model":"m","embedding":[1.0,0.0]}]})).unwrap();
    let source = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":transcript}),
        )
        .unwrap();
    let corrected = json!({"text":"hola","segments":[{"speaker":"Ana","start":0,"end":1,"text":"hola","words":[]}],"recognitions":[]});
    let taught = store.mutate("version_save", &json!({"recordingId":key,"sourceVersionId":source["id"],"backend":"correccion","transcript":corrected,"teaching":{"speaker":"Speaker 1","person":"Ana"}})).unwrap();
    assert_eq!(taught["learnedVoice"], true);
    assert_eq!(store.people().unwrap()[0]["name"], "Ana");
    assert_eq!(store.people().unwrap()[0]["voices"][0]["source"], key);
    assert_eq!(
        store
            .version_voices(taught["id"].as_str().unwrap())
            .unwrap()[0]
            .speaker,
        "Ana"
    );
    let merged = store.mutate("version_save", &json!({"recordingId":key,"sourceVersionId":taught["id"],"backend":"correccion","transcript":{"text":"hola","segments":[{"speaker":"Nadie","start":0,"end":1,"text":"hola","words":[]}],"recognitions":[]},"teaching":{"speaker":"Ana","person":"Nadie","existingOnly":true}})).unwrap();
    assert_eq!(merged["learnedVoice"], false);
    assert_eq!(
        store
            .version_voices(merged["id"].as_str().unwrap())
            .unwrap()[0]
            .speaker,
        "Nadie"
    );
    assert_eq!(store.people().unwrap().as_array().unwrap().len(), 1);
}

#[test]
fn avisar_de_cada_nota_se_guarda_aunque_la_biblioteca_no_lo_tuviera() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    store
        .mutate(
            "settings_save",
            &json!({"settings":{"notifyEveryNote":false,"legacyWatchAdopted":true}}),
        )
        .unwrap();
    assert_eq!(store.data_json()["settings"]["notifyEveryNote"], false);
    assert!(store.data_json()["settings"]
        .get("legacyWatchAdopted")
        .is_none());
}

#[test]
fn una_instalacion_nueva_vigila_notas_de_voz_una_sola_vez() {
    let dir = tempfile::tempdir().unwrap();
    let memos = dir.path().join("Recordings");
    let mut store = Store::open(dir.path().join("library")).unwrap();
    assert!(store.seed_voice_memos(&memos).unwrap());
    let folders = store.data_json()["settings"]["watchedFolders"].clone();
    assert_eq!(folders.as_array().unwrap().len(), 1);
    assert_eq!(folders[0]["style"], "voiceMemos");
    assert_eq!(folders[0]["path"], json!(memos));
    store
        .mutate("settings_save", &json!({"settings":{"watchedFolders":[]}}))
        .unwrap();
    assert!(!store.seed_voice_memos(&memos).unwrap());
    assert_eq!(store.data_json()["settings"]["watchedFolders"], json!([]));
}

#[test]
fn las_carpetas_que_vienen_de_swift_no_reciben_notas_de_voz_de_regalo() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let mut next = store.data_json();
    next["settings"]["legacyWatchAdopted"] = json!(true);
    store.replace(next).unwrap();
    assert!(!store
        .seed_voice_memos(&dir.path().join("Recordings"))
        .unwrap());
    assert_eq!(store.data_json()["settings"]["watchedFolders"], json!([]));
    assert_eq!(store.data_json()["settings"]["voiceMemosSeeded"], true);
}

#[test]
fn carpeta_autorizada_persiste_y_el_bookmark_no_sale_en_respuestas() {
    let dir = tempfile::tempdir().unwrap();
    let library = dir.path().join("library");
    let folder = dir.path().join("VoiceMemos");
    fs::create_dir_all(&folder).unwrap();
    let bytes = b"synthetic-private-bookmark";
    let mut store = Store::open(library.clone()).unwrap();
    let created = store
        .authorize_watched_folder(None, &folder, Some("Notas"), "voiceMemos", bytes)
        .unwrap();
    let id = created["id"].as_str().unwrap().to_owned();
    assert_eq!(created["authorizationSaved"], true);
    assert!(created.get("accessBookmark").is_none());
    assert_eq!(store.watched_folder_bookmarks().unwrap()[0].2, bytes);
    let snapshot = store.snapshot().unwrap();
    assert_eq!(
        snapshot["settings"]["watchedFolders"][0]["authorizationSaved"],
        true
    );
    assert!(snapshot["settings"]["watchedFolders"][0]
        .get("accessBookmark")
        .is_none());
    let reply = store
        .mutate(
            "settings_save",
            &json!({"settings":{"watchedFolders":snapshot["settings"]["watchedFolders"]}}),
        )
        .unwrap();
    assert!(reply["watchedFolders"][0].get("accessBookmark").is_none());
    assert_eq!(store.watched_folder_bookmarks().unwrap()[0].2, bytes);
    drop(store);
    let store = Store::open(library).unwrap();
    assert_eq!(store.watched_folder_bookmarks().unwrap()[0].0, id);
    assert_eq!(store.watched_folder_bookmarks().unwrap()[0].2, bytes);
    assert!(!store
        .snapshot()
        .unwrap()
        .to_string()
        .contains("synthetic-private-bookmark"));
}

#[test]
fn reautorizar_misma_ruta_conserva_metadatos_y_cambiar_o_quitar_revoca() {
    let dir = tempfile::tempdir().unwrap();
    let first = dir.path().join("first");
    let second = dir.path().join("second");
    fs::create_dir_all(&first).unwrap();
    fs::create_dir_all(&second).unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let folder = store
        .authorize_watched_folder(
            None,
            &first,
            Some("Original"),
            "voiceMemos",
            b"first-bookmark",
        )
        .unwrap();
    let id = folder["id"].as_str().unwrap().to_owned();
    store.mutate("settings_save", &json!({"settings":{"watchedFolders":[{"id":id,"path":first,"name":"Chosen","style":"any","enabled":false,"authorizationSaved":false,"accessBookmark":[1,2,3]}]}})).unwrap();
    assert_eq!(store.watched_folder_bookmarks().unwrap().len(), 0);
    let duplicate = store
        .authorize_watched_folder(
            None,
            &first,
            Some("Ignored"),
            "justPressRecord",
            b"second-bookmark",
        )
        .unwrap();
    assert_eq!(duplicate["id"], id);
    assert_eq!(duplicate["name"], "Chosen");
    assert_eq!(duplicate["style"], "any");
    assert_eq!(duplicate["enabled"], false);
    assert!(store
        .authorize_watched_folder(Some(&id), &second, None, "any", b"wrong-path")
        .is_err());
    assert_eq!(
        store.data_json()["settings"]["watchedFolders"][0]["accessBookmark"],
        json!(b"second-bookmark")
    );
    store.mutate("settings_save", &json!({"settings":{"watchedFolders":[{"id":id,"path":second,"name":"Moved","style":"any","enabled":true,"accessBookmark":[9,9],"authorizationSaved":true}]}})).unwrap();
    assert!(store.watched_folder_bookmarks().unwrap().is_empty());
    assert!(store.data_json()["settings"]["watchedFolders"][0]
        .get("accessBookmark")
        .is_none());
    store
        .mutate("settings_save", &json!({"settings":{"watchedFolders":[]}}))
        .unwrap();
    assert!(store.data_json()["settings"]["watchedFolders"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn renovar_bookmark_respeta_actualizaciones_concurrentes_y_traslados() {
    let dir = tempfile::tempdir().unwrap();
    let old = dir.path().join("old");
    let moved = dir.path().join("moved");
    fs::create_dir_all(&old).unwrap();
    fs::create_dir_all(&moved).unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let folder = store
        .authorize_watched_folder(None, &old, None, "any", b"original")
        .unwrap();
    let id = folder["id"].as_str().unwrap().to_owned();
    assert!(!store
        .refresh_watched_folder_bookmark(&id, b"stale", &moved, Some(b"replacement"))
        .unwrap());
    assert_eq!(
        store.data_json()["settings"]["watchedFolders"][0]["path"],
        json!(old.canonicalize().unwrap())
    );
    assert!(store
        .refresh_watched_folder_bookmark(&id, b"original", &moved, Some(b"replacement"))
        .unwrap());
    assert_eq!(
        store.data_json()["settings"]["watchedFolders"][0]["path"],
        json!(moved.canonicalize().unwrap())
    );
    assert_eq!(
        store.watched_folder_bookmarks().unwrap()[0].2,
        b"replacement"
    );
    assert!(!store
        .refresh_watched_folder_bookmark(&id, b"original", &old, None)
        .unwrap());
    store
        .mutate("settings_save", &json!({"settings":{"watchedFolders":[]}}))
        .unwrap();
    assert!(!store
        .refresh_watched_folder_bookmark(&id, b"replacement", &old, None)
        .unwrap());
}

#[test]
fn reautorizar_carpeta_trasladada_conserva_identidad_y_no_usurpa_otra() {
    let dir = tempfile::tempdir().unwrap();
    let first = dir.path().join("first");
    let moved = dir.path().join("moved");
    let second = dir.path().join("second");
    fs::create_dir_all(&first).unwrap();
    fs::create_dir_all(&second).unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let original = store
        .authorize_watched_folder(None, &first, Some("Original"), "voiceMemos", b"old")
        .unwrap();
    let other = store
        .authorize_watched_folder(None, &second, Some("Otra"), "any", b"other")
        .unwrap();
    let id = original["id"].as_str().unwrap();
    store
        .mutate(
            "settings_save",
            &json!({"settings":{"watchedFolders":[
                {"id":id,"path":first,"name":"Elegida","style":"voiceMemos","enabled":false},
                other
            ]}}),
        )
        .unwrap();
    fs::rename(&first, &moved).unwrap();
    assert!(store
        .authorize_watched_folder(Some(id), &second, None, "any", b"wrong")
        .is_err());
    let saved = store
        .authorize_watched_folder(
            Some(id),
            &moved,
            Some("Ignorado"),
            "justPressRecord",
            b"new",
        )
        .unwrap();
    assert_eq!(saved["id"], original["id"]);
    assert_eq!(saved["path"], json!(moved.canonicalize().unwrap()));
    assert_eq!(saved["name"], "Elegida");
    assert_eq!(saved["style"], "voiceMemos");
    assert_eq!(saved["enabled"], false);
    assert_eq!(saved["authorizationSaved"], true);
    assert!(saved.get("accessBookmark").is_none());
    let settings = store.settings_json();
    let folders = settings["watchedFolders"].as_array().unwrap();
    assert_eq!(folders.len(), 2);
    assert_eq!(folders[0]["accessBookmark"], json!(b"new"));
    assert_eq!(folders[1]["id"], other["id"]);
    assert_eq!(folders[1]["accessBookmark"], json!(b"other"));
}

#[test]
fn biblioteca_importada_conserva_transcripcion_y_descarte_al_reabrir_y_vigilar() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("note.wav");
    fs::write(&source, b"synthetic imported audio").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&source, None).unwrap();
    let id = record["id"].as_str().unwrap();
    store.mutate("version_save", &json!({"recordingId":id,"backend":"whisperkit","transcript":{"text":"Conservada","segments":[]}})).unwrap();
    let mut data = store.data_json();
    data["recordings"][0]["sourceKey"] = json!("swift:123");
    data["recordings"][0]["legacyKey"] = json!("123");
    data["recordings"].as_array_mut().unwrap().push(json!({"id":"discarded","status":"discarded","source":dir.path().join("old.wav"),"sourceKey":"swift:456","legacyKey":"456"}));
    store.replace(data).unwrap();
    let versions = store.recording(id).unwrap()["versions"].clone();
    drop(store);
    let mut store = Store::open(root).unwrap();
    let renamed = dir.path().join("renamed.wav");
    fs::rename(&source, &renamed).unwrap();
    let refreshed = store
        .import_with_metadata(
            &renamed,
            None,
            "Renamed",
            SystemTime::now(),
            "voiceMemos:folder/123",
        )
        .unwrap();
    assert_eq!(refreshed["id"], id);
    assert_eq!(store.recording(id).unwrap()["versions"], versions);
    assert!(refreshed["versions"][0]["transcript"]["segments"]
        .as_array()
        .unwrap()
        .is_empty());
    let discarded_source = dir.path().join("discarded-renamed.wav");
    fs::write(&discarded_source, b"discarded audio").unwrap();
    let discarded = store
        .import_with_metadata(
            &discarded_source,
            None,
            "Discarded",
            SystemTime::now(),
            "voiceMemos:folder/456",
        )
        .unwrap();
    assert_eq!(discarded["status"], "discarded");
    assert_eq!(discarded["id"], "discarded");
    assert_eq!(store.data_json()["recordings"].as_array().unwrap().len(), 2);
}

#[test]
fn preserves_versions_and_selection_across_restart() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("test.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let recording = store.import(&audio, None).unwrap();
    let key = recording["id"].as_str().unwrap();
    let first = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"backend":"test","transcript":{"text":"hola","segments":[]}}),
        )
        .unwrap();
    let second=store.mutate("version_save",&json!({"recordingId":key,"backend":"test","transcript":{"text":"corregido","segments":[]}})).unwrap();
    store.mutate("version_update",&json!({"recordingId":key,"versionId":first["id"],"digest":{"title":"Primera","summary":"Resumen","tags":[]}})).unwrap();
    assert_eq!(
        store.recording(key).unwrap()["currentVersionId"],
        second["id"]
    );
    drop(store);
    let store = Store::open(root).unwrap();
    let saved = store.recording(key).unwrap();
    assert_eq!(saved["versions"].as_array().unwrap().len(), 2);
    assert_eq!(saved["versions"][0]["digest"]["title"], "Primera");
}
#[test]
fn incorporar_sin_elegir_receta_no_fija_la_predeterminada() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("prueba.wav");
    fs::write(&audio, b"audio sintetico").unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let recording = store.import(&audio, None).unwrap();
    assert_eq!(recording["recipeId"], Value::Null);
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert_eq!(
        reopened
            .recording(recording["id"].as_str().unwrap())
            .unwrap()["recipeId"],
        Value::Null
    );
}

#[test]
fn una_grabacion_vacia_no_fija_receta_y_la_eleccion_explicita_se_conserva() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("prueba.wav");
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let empty = store
        .mutate("recording_abandoned", &json!({"path":audio}))
        .unwrap();
    assert_eq!(empty["recipeId"], Value::Null);
    fs::write(&audio, b"audio sintetico elegido").unwrap();
    let recording = store.import(&audio, Some("elegida")).unwrap();
    assert_eq!(recording["recipeId"], "elegida");
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert_eq!(
        reopened
            .recording(recording["id"].as_str().unwrap())
            .unwrap()["recipeId"],
        "elegida"
    );
}

#[test]
fn deduplicates_audio_and_retains_discard_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("test.wav");
    fs::write(&audio, b"audio").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let r = store.import(&audio, None).unwrap();
    store
        .mutate("recording_discard", &json!({"id":r["id"]}))
        .unwrap();
    let again = store.import(&audio, None).unwrap();
    assert_eq!(again["status"], "discarded");
    assert_eq!(
        store.snapshot().unwrap()["recordings"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn borrar_de_biblioteca_deja_solo_identidad_y_borra_contenido_y_copia() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("captura.wav");
    fs::write(&source, b"audio sintetico privado").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&source, None).unwrap();
    let key = record["id"].as_str().unwrap().to_owned();
    let copy = store.audio(&key).unwrap();
    store
        .mutate(
            "version_save",
            &json!({
                "recordingId":key,
                "transcript":{"text":"transcripción privada","segments":[]},
                "digest":{"title":"título privado","summary":"resumen privado"},
                "data":{"detalle":"dato privado"}
            }),
        )
        .unwrap();

    let discarded = store
        .mutate("recording_discard", &json!({"id":key}))
        .unwrap();
    let tombstone = json!({
        "id":key,"source":source,"sourceKey":null,"legacyKey":null,"status":"discarded"
    });
    assert_eq!(discarded, tombstone);
    assert!(!copy.exists());
    assert!(source.exists());
    drop(store);

    let reopened = Store::open(root).unwrap();
    assert_eq!(reopened.recording(&key).unwrap(), tombstone);
}

#[test]
fn descartar_guarda_borrado_pendiente_y_reintenta_tras_caida() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("original.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
    let record = store.import(&source, None).unwrap();
    let id = record["id"].as_str().unwrap();
    let copy = store.audio(id).unwrap();
    store
        .mutate("recording_discard", &json!({"id":id}))
        .unwrap();
    assert_eq!(
        store.recording(id).unwrap(),
        discarded_record(&record).unwrap()
    );
    assert!(copy.exists());
    assert_eq!(store.database.pending_audio_deletions().unwrap().len(), 1);
    assert!(!store
        .snapshot()
        .unwrap()
        .to_string()
        .contains(copy.to_str().unwrap()));
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert!(!copy.exists());
    assert!(source.exists());
    assert!(reopened
        .database
        .pending_audio_deletions()
        .unwrap()
        .is_empty());
    assert_eq!(
        reopened.recording(id).unwrap(),
        discarded_record(&record).unwrap()
    );
}

#[test]
fn arranque_guarda_el_borrado_de_audio_antes_de_limpiar_lapida_antigua() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("original.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&source, None).unwrap();
    let id = record["id"].as_str().unwrap();
    let copy = store.audio(id).unwrap();
    let mut legacy = store.data_json();
    legacy["recordings"][0]["status"] = json!("discarded");
    store.replace(legacy).unwrap();
    drop(store);
    let interrupted = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
    assert_eq!(
        interrupted.recording(id).unwrap(),
        discarded_record(&record).unwrap()
    );
    assert!(copy.exists());
    assert_eq!(
        interrupted
            .database
            .pending_audio_deletions()
            .unwrap()
            .len(),
        1
    );
    drop(interrupted);
    let reopened = Store::open(root).unwrap();
    assert!(!copy.exists());
    assert!(source.exists());
    assert!(reopened
        .database
        .pending_audio_deletions()
        .unwrap()
        .is_empty());
}

#[test]
fn borrado_pendiente_ausente_se_da_por_completado_al_abrir() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("original.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
    let record = store.import(&source, None).unwrap();
    let copy = store.audio(record["id"].as_str().unwrap()).unwrap();
    store
        .mutate("recording_discard", &json!({"id":record["id"]}))
        .unwrap();
    fs::remove_file(&copy).unwrap();
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert!(reopened
        .database
        .pending_audio_deletions()
        .unwrap()
        .is_empty());
    assert!(source.exists());
}

#[test]
fn borrado_pendiente_no_sigue_enlace_a_original_fuera_de_audio() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("original.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
    let record = store.import(&source, None).unwrap();
    let copy = store.audio(record["id"].as_str().unwrap()).unwrap();
    store
        .mutate("recording_discard", &json!({"id":record["id"]}))
        .unwrap();
    fs::remove_file(&copy).unwrap();
    std::os::unix::fs::symlink(&source, &copy).unwrap();
    drop(store);
    assert!(Store::open(root.clone()).is_err());
    assert!(Store::open(root.clone()).is_err());
    assert_eq!(fs::read(&source).unwrap(), b"audio sintetico");
    fs::remove_file(copy).unwrap();
    let reopened = Store::open(root).unwrap();
    assert!(reopened
        .database
        .pending_audio_deletions()
        .unwrap()
        .is_empty());
}

#[test]
fn borrado_pendiente_no_borra_otro_archivo_que_ocupa_la_misma_ruta() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("original.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open_with_audio_cleanup(root.clone(), false).unwrap();
    let record = store.import(&source, None).unwrap();
    let copy = store.audio(record["id"].as_str().unwrap()).unwrap();
    store
        .mutate("recording_discard", &json!({"id":record["id"]}))
        .unwrap();
    fs::remove_file(&copy).unwrap();
    fs::write(&copy, b"otro audio sintetico").unwrap();
    drop(store);
    assert!(Store::open(root.clone()).is_err());
    assert_eq!(fs::read(&copy).unwrap(), b"otro audio sintetico");
    fs::remove_file(copy).unwrap();
    let reopened = Store::open(root).unwrap();
    assert!(reopened
        .database
        .pending_audio_deletions()
        .unwrap()
        .is_empty());
    assert!(source.exists());
}

#[test]
fn origen_externo_no_comprobable_no_bloquea_borrado_de_copia_local() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("original.wav");
    let other = dir.path().join("other.wav");
    let not_a_directory = dir.path().join("archivo");
    fs::write(&source, b"audio uno").unwrap();
    fs::write(&other, b"audio dos").unwrap();
    fs::write(&not_a_directory, b"no es carpeta").unwrap();
    let mut store = Store::open(root).unwrap();
    let first = store.import(&source, None).unwrap();
    let second = store.import(&other, None).unwrap();
    let copy = store.audio(first["id"].as_str().unwrap()).unwrap();
    let mut changed = store.data_json();
    let records = changed["recordings"].as_array_mut().unwrap();
    records
        .iter_mut()
        .find(|record| record["id"] == second["id"])
        .unwrap()["source"] = json!(not_a_directory.join("child.wav"));
    store.replace(changed).unwrap();
    store
        .mutate("recording_discard", &json!({"id":first["id"]}))
        .unwrap();
    assert!(!copy.exists());
    assert!(source.exists());
    assert!(other.exists());
}

#[test]
fn descarte_no_borra_original_ajeno_ni_copia_compartida_activa() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("original.wav");
    let other = dir.path().join("other.wav");
    fs::write(&source, b"audio uno").unwrap();
    fs::write(&other, b"audio dos").unwrap();
    let mut store = Store::open(root).unwrap();
    let first = store.import(&source, None).unwrap();
    let second = store.import(&other, None).unwrap();
    let copy = store.audio(first["id"].as_str().unwrap()).unwrap();
    let mut changed = store.data_json();
    let records = changed["recordings"].as_array_mut().unwrap();
    records
        .iter_mut()
        .find(|record| record["id"] == second["id"])
        .unwrap()["audioPath"] = json!(copy);
    store.replace(changed).unwrap();
    store
        .mutate("recording_discard", &json!({"id":first["id"]}))
        .unwrap();
    assert!(copy.exists());
    assert!(store.database.pending_audio_deletions().unwrap().is_empty());

    let mut changed = store.data_json();
    let records = changed["recordings"].as_array_mut().unwrap();
    records
        .iter_mut()
        .find(|record| record["id"] == second["id"])
        .unwrap()["audioPath"] = json!(source);
    store.replace(changed).unwrap();
    assert!(store
        .mutate("recording_discard", &json!({"id":second["id"]}))
        .is_err());
    assert!(source.exists());
    assert_eq!(
        store.recording(second["id"].as_str().unwrap()).unwrap()["status"],
        "pending"
    );
}

#[test]
fn arranque_normaliza_descartados_antiguos_y_retira_su_copia_de_audio() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("captura.wav");
    fs::write(&source, b"audio sintetico privado").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let first = store.import(&source, None).unwrap();
    let key = first["id"].as_str().unwrap().to_owned();
    let copy = store.audio(&key).unwrap();
    let mut legacy = store.data_json();
    legacy["recordings"][0]["status"] = json!("discarded");
    store.replace(legacy).unwrap();
    drop(store);

    let reopened = Store::open(root).unwrap();

    assert_eq!(
        reopened.recording(&key).unwrap(),
        discarded_record(&first).unwrap()
    );
    assert!(!copy.exists());
    assert!(source.exists());
}

#[test]
fn borrar_limpia_memoria_traza_trabajo_y_huella_de_version_sin_olvidar_persona() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("captura.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let key = store.import(&source, None).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let voice = SpeakerVoice {
        speaker: "Hablante".into(),
        model: "modelo-sintetico".into(),
        embedding: vec![1.0, 0.0],
    };
    let transcript = store.recognize_transcription(&key, json!({
            "text":"texto privado","segments":[],"voices":[{"speaker":"Hablante","model":"modelo-sintetico","embedding":[1.0,0.0]}]
        })).unwrap();
    let version = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":transcript}),
        )
        .unwrap();
    let version_id = version["id"].as_str().unwrap();
    assert_eq!(store.version_voices(version_id).unwrap().len(), 1);
    store
        .memory_keep(
            &key,
            version_id,
            "huella-sintetica",
            &json!({"value":"recuerdo privado"}),
        )
        .unwrap();
    let memory_key = json!([key, version_id, "huella-sintetica"]).to_string();
    store
        .trace_save(
            &json!({"id":"traza","recordingId":key,"startedAt":"2026-10-10","detail":"privado"}),
        )
        .unwrap();
    store
        .job_save(&json!({"id":"trabajo","recordingId":key,"state":"cancelled"}))
        .unwrap();
    store.add_person_voice("Persona", &voice, &key).unwrap();

    store
        .mutate("recording_discard", &json!({"id":key}))
        .unwrap();

    assert!(store.version_voices(version_id).unwrap().is_empty());
    assert!(store.database.recall(&memory_key).unwrap().is_none());
    assert!(store.trace_list(Some(&key)).unwrap().is_empty());
    assert!(store.jobs().unwrap().is_empty());
    assert_eq!(store.people().unwrap()[0]["name"], "Persona");
}

#[test]
fn vigilancia_no_resucita_una_lapida_aunque_cambie_el_audio() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("nota.m4a");
    fs::write(&source, b"primera version sintetica").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let first = store
        .import_with_metadata(
            &source,
            None,
            "Nota",
            SystemTime::now(),
            "voiceMemos:folder/42",
        )
        .unwrap();
    let key = first["id"].as_str().unwrap();
    let tombstone = store
        .mutate("recording_discard", &json!({"id":key}))
        .unwrap();

    fs::write(&source, b"segunda version sintetica").unwrap();
    let scanned = store
        .import_with_metadata(
            &source,
            None,
            "Título posterior",
            SystemTime::now(),
            "voiceMemos:folder/42",
        )
        .unwrap();

    assert_eq!(scanned, tombstone);
    assert_eq!(store.recording(key).unwrap(), tombstone);
    assert!(store.jobs().unwrap().is_empty());
}

#[test]
fn vigilancia_reconoce_por_origen_la_lapida_de_una_importacion_manual() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("nota.m4a");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let first = store.import(&source, None).unwrap();
    let tombstone = store
        .mutate("recording_discard", &json!({"id":first["id"]}))
        .unwrap();

    let watched = store
        .import_with_metadata(
            &source,
            None,
            "Nota vigilada",
            SystemTime::now(),
            "voiceMemos:folder/42",
        )
        .unwrap();

    assert_eq!(watched, tombstone);
    assert_eq!(store.data_json()["recordings"].as_array().unwrap().len(), 1);
}

#[test]
fn respuestas_tardias_no_escriben_sobre_una_grabacion_descartada() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("nota.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let key = store.import(&source, None).unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let tombstone = store
        .mutate("recording_discard", &json!({"id":key}))
        .unwrap();

    assert!(store
        .mutate("recording_update", &json!({"id":key,"status":"done"}))
        .is_err());
    assert!(store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":{"text":"tarde","segments":[]}})
        )
        .is_err());
    assert!(store
        .mutate(
            "publication_save",
            &json!({"recordingId":key,"destinationId":"d","receipt":{}})
        )
        .is_err());
    assert!(store
        .trace_save(&json!({"recordingId":key,"detail":"tarde"}))
        .is_err());
    assert!(store
        .job_save(&json!({"id":"tarde","recordingId":key,"state":"queued"}))
        .is_err());
    assert!(store
        .recognize_transcription(&key, json!({"text":"tarde","segments":[],"voices":[]}))
        .is_err());
    assert!(store
        .mutate("recording_restore", &json!({"id":key}))
        .is_err());
    assert_eq!(store.recording(&key).unwrap(), tombstone);
    assert!(store.jobs().unwrap().is_empty());
    assert!(store.trace_list(Some(&key)).unwrap().is_empty());
}
#[test]
fn watched_voice_memo_rename_and_revision_keep_identity_and_versions() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("old.mov");
    fs::write(&source, b"first audio").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let started = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
    let first = store
        .import_with_metadata(&source, None, "Antiguo", started, "voiceMemos:folder/42")
        .unwrap();
    let recording_id = first["id"].as_str().unwrap();
    let first_copy = store.audio(recording_id).unwrap();
    store
        .mutate(
            "version_save",
            &json!({"recordingId":recording_id,"transcript":{"text":"primera","segments":[]}}),
        )
        .unwrap();
    let renamed = dir.path().join("new.mov");
    fs::rename(&source, &renamed).unwrap();
    let same = store
        .import_with_metadata(&renamed, None, "Nuevo", started, "voiceMemos:folder/42")
        .unwrap();
    assert_eq!(same["id"], first["id"]);
    assert_eq!(same["title"], "Nuevo");
    assert_eq!(same["source"], json!(renamed));
    assert_eq!(store.data_json()["recordings"].as_array().unwrap().len(), 1);
    fs::write(&renamed, b"second audio").unwrap();
    let revised = store
        .import_with_metadata(&renamed, None, "Nuevo", started, "voiceMemos:folder/42")
        .unwrap();
    assert_eq!(revised["id"], first["id"]);
    assert_eq!(revised["versions"].as_array().unwrap().len(), 1);
    assert_eq!(revised["status"], "pending");
    assert!(!first_copy.exists());
    assert_eq!(
        fs::read(store.audio(recording_id).unwrap()).unwrap(),
        b"second audio"
    );
}
#[test]
fn changed_watched_audio_waits_for_active_job_before_replacing_copy() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("voice.m4a");
    fs::write(&source, b"first audio").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let started = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_700_000_000);
    let first = store
        .import_with_metadata(&source, None, "Original", started, "voiceMemos:folder/42")
        .unwrap();
    let recording_id = first["id"].as_str().unwrap();
    let old_copy = store.audio(recording_id).unwrap();
    store
        .mutate(
            "version_save",
            &json!({"recordingId":recording_id,"transcript":{"text":"primera","segments":[]}}),
        )
        .unwrap();
    store
        .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":"queued"}))
        .unwrap();
    let renamed = dir.path().join("voice-renamed.m4a");
    fs::rename(&source, &renamed).unwrap();
    let same_audio = store
        .import_with_metadata(&renamed, None, "Renamed", started, "voiceMemos:folder/42")
        .unwrap();
    assert_eq!(same_audio["id"], first["id"]);
    assert_eq!(same_audio["status"], first["status"]);
    assert_eq!(same_audio["title"], "Renamed");
    assert_eq!(store.audio(recording_id).unwrap(), old_copy);
    fs::write(&renamed, b"second audio").unwrap();
    for state in ["queued", "running", "retry"] {
        store
            .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":state}))
            .unwrap();
        let error = store
            .import_with_metadata(
                &renamed,
                None,
                "Actualizado",
                started,
                "voiceMemos:folder/42",
            )
            .unwrap_err();
        assert!(error.contains("trabajo activo"), "{error}");
        assert_eq!(store.audio(recording_id).unwrap(), old_copy);
        assert_eq!(fs::read(&old_copy).unwrap(), b"first audio");
        assert_eq!(store.recording(recording_id).unwrap()["title"], "Renamed");
        assert_eq!(
            store.recording(recording_id).unwrap()["versions"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
    store
        .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":"succeeded"}))
        .unwrap();
    let revised = store
        .import_with_metadata(
            &renamed,
            None,
            "Actualizado",
            started,
            "voiceMemos:folder/42",
        )
        .unwrap();
    assert_eq!(revised["id"], first["id"]);
    assert_eq!(revised["title"], "Actualizado");
    assert_eq!(revised["versions"].as_array().unwrap().len(), 1);
    assert!(!old_copy.exists());
    assert_eq!(
        fs::read(store.audio(recording_id).unwrap()).unwrap(),
        b"second audio"
    );
}
#[test]
fn credentials_do_not_enter_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    store.mutate("config_save",&json!({"collection":"accounts","item":{"id":"notion","name":"Notion","provider":"notion","enabled":true,"token":"must-not-persist"}})).unwrap();
    store
        .save_credential("notion", "fake-local-secret")
        .unwrap();
    let state = store.snapshot().unwrap().to_string();
    assert!(!state.contains("fake-local-secret"));
    assert!(!state.contains("must-not-persist"));
    assert_eq!(
        store.credential("notion").unwrap().as_deref(),
        Some("fake-local-secret")
    );
}
#[test]
fn runtime_context_limits_a_large_library_to_the_requested_recording() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let selected_path = "/private/audio/selected.wav";
    let other_marker = "foreign-recording-marker";
    let selected = json!({
        "id":"selected", "status":"done", "title":"Selected", "audioPath":selected_path,
        "source":"/private/source/selected.wav", "sourceKey":"/private/source-key",
        "legacyKey":"/private/legacy-key",
        "versions":[{"id":"version-1","transcript":{"text":"reusable transcript","segments":[]},"inputs":{"backend":"local-stt"}}],
        "publications":[{"destinationId":"destination-1","receipt":{"locator":"receipt-1"}}]
    });
    let mut data = store.data_json();
    data["recordings"] = json!([
        selected.clone(),
        {"id":"other","status":"done","title":other_marker,"audioPath":"/private/audio/other.wav",
         "versions":[{"id":"other-version","transcript":{"text":"X".repeat(33 * 1024 * 1024),"segments":[]}}],"publications":[]}
    ]);
    data["settings"]["watchedFolders"] = json!([{
        "id":"folder-1","path":"/private/watched","name":"Watched","accessBookmark":[1,2,3]
    }]);
    data["logs"] = json!([{"id":"log-1","message":"private log marker"}]);
    data["accounts"] = json!([{"id":"account-1","name":"Account","provider":"okf","enabled":true,"folder":"/private/account-folder"}]);
    store.replace(data).unwrap();
    store
        .save_credential("account-1", "synthetic-secret")
        .unwrap();

    assert!(store.snapshot().unwrap().to_string().len() > 32 * 1024 * 1024);
    let context = store.runtime_context(Some("selected")).unwrap();
    let serialized = context.to_string();
    assert!(serialized.len() < 1024 * 1024);
    assert_eq!(context["recordings"].as_array().unwrap().len(), 1);
    assert_eq!(context["recordings"][0]["id"], "selected");
    assert_eq!(context["recordings"][0]["audioPath"], "available");
    assert_eq!(
        context["recordings"][0]["source"],
        "urn:escriba:recording:selected"
    );
    assert!(context["recordings"][0].get("sourceKey").is_none());
    assert!(context["recordings"][0].get("legacyKey").is_none());
    assert_eq!(context["recordings"][0]["versions"], selected["versions"]);
    assert_eq!(
        context["recordings"][0]["publications"],
        selected["publications"]
    );
    assert_eq!(context["accounts"][0]["hasCredential"], true);
    assert_eq!(context["settings"].as_object().unwrap().len(), 3);
    assert!(context.get("logs").is_none());
    assert!(context.get("dataPath").is_none());
    assert!(!serialized.contains(other_marker));
    assert!(!serialized.contains("other-version"));
    assert!(!serialized.contains(selected_path));
    assert!(!serialized.contains("/private/"));
    assert!(!serialized.contains("private log marker"));
    assert!(!serialized.contains("synthetic-secret"));
    assert!(!serialized.contains("accessBookmark"));

    let folder_fingerprint = context["accounts"][0]["folder"].as_str().unwrap();
    assert!(folder_fingerprint.starts_with("urn:escriba:folder:"));
    assert_eq!(
        store.runtime_context(None).unwrap()["accounts"][0]["folder"],
        folder_fingerprint
    );
    let mut changed = store.data_json();
    changed["accounts"][0]["folder"] = json!("/private/changed-folder");
    store.replace(changed).unwrap();
    assert_ne!(
        store.runtime_context(None).unwrap()["accounts"][0]["folder"],
        folder_fingerprint
    );

    let catalog = store.runtime_context(None).unwrap();
    assert!(catalog["recordings"].as_array().unwrap().is_empty());
    assert_eq!(catalog["recipes"], store.snapshot().unwrap()["recipes"]);
    assert_eq!(
        store.runtime_context(Some("missing")).unwrap_err(),
        "Grabación no encontrada"
    );
}
#[test]
fn rocksdb_preserves_versions_after_json_is_removed() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let audio = dir.path().join("note.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&audio, None).unwrap();
    store.mutate("version_save", &json!({"recordingId":record["id"],"backend":"test","transcript":{"text":"texto","segments":[]}})).unwrap();
    drop(store);
    if root.join("library.json").exists() {
        fs::remove_file(root.join("library.json")).unwrap();
    }
    let restored = Store::open(root.clone()).unwrap();
    assert!(root.join("library.rocksdb").is_dir());
    assert_eq!(
        restored.recording(record["id"].as_str().unwrap()).unwrap()["versions"][0]["transcript"]
            ["text"],
        "texto"
    );
}
#[test]
fn committed_surreal_rows_survive_forced_process_termination() {
    const ENV_KEY: &str = "ESCRIBA_CRASH_TEST_ROOT";
    if let Ok(root) = std::env::var(ENV_KEY) {
        let root = PathBuf::from(root);
        let mut store = Store::open(root.clone()).unwrap();
        store
            .mutate("log", &json!({"message":"committed before kill"}))
            .unwrap();
        fs::write(root.join("child-ready"), []).unwrap();
        loop {
            std::thread::sleep(std::time::Duration::from_secs(1));
        }
    }
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    fs::create_dir_all(&root).unwrap();
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "store::tests::committed_surreal_rows_survive_forced_process_termination",
            "--nocapture",
        ])
        .env(ENV_KEY, &root)
        .spawn()
        .unwrap();
    let ready = root.join("child-ready");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(20);
    while !ready.exists() && std::time::Instant::now() < deadline {
        if child.try_wait().unwrap().is_some() {
            panic!("El proceso hijo terminó antes de guardar");
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert!(ready.exists(), "El proceso hijo no confirmó el commit");
    child.kill().unwrap();
    child.wait().unwrap();
    let store = Store::open(root).unwrap();
    assert_eq!(
        store.log_list(&json!({})).unwrap()[0]["message"],
        "committed before kill"
    );
}
#[test]
fn surreal_records_expose_native_fields_and_objects() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("note.wav");
    fs::write(&source, b"synthetic audio").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let recording = store.import(&source, None).unwrap();
    store.mutate("version_save", &json!({"recordingId":recording["id"],"backend":"whisper","transcript":{"text":"hola","segments":[]}})).unwrap();
    store
        .job_save(&json!({"id":"job-1","recordingId":recording["id"],"state":"queued"}))
        .unwrap();
    let records = store
        .database
        .select_test("SELECT title, status, payload.title AS nestedTitle FROM recording")
        .unwrap();
    assert_eq!(records[0]["title"], "note");
    assert_eq!(records[0]["status"], "pending");
    assert_eq!(records[0]["nestedTitle"], "note");
    let versions = store
        .database
        .select_test("SELECT backend, payload.transcript.text AS transcriptText FROM version")
        .unwrap();
    assert_eq!(versions[0]["backend"], "whisper");
    assert_eq!(versions[0]["transcriptText"], "hola");
    let jobs = store
        .database
        .select_test("SELECT state, recordingId FROM job")
        .unwrap();
    assert_eq!(jobs[0]["state"], "queued");
    assert_eq!(jobs[0]["recordingId"], recording["id"]);
}
#[test]
fn earlier_surreal_string_rows_upgrade_transactionally_to_native_objects() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("note.wav");
    fs::write(&source, b"synthetic audio").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let recording = store.import(&source, None).unwrap();
    let recording_id = recording["id"].as_str().unwrap();
    store
        .job_save(&json!({"id":"job-1","recordingId":recording_id,"state":"queued"}))
        .unwrap();
    store.database.downgrade_v1_test().unwrap();
    drop(store);
    let store = Store::open(root).unwrap();
    assert_eq!(store.recording(recording_id).unwrap()["title"], "note");
    assert_eq!(store.jobs().unwrap()[0]["state"], "queued");
    assert_eq!(
        store
            .database
            .select_test("SELECT status, payload.title AS nestedTitle FROM recording")
            .unwrap()[0]["nestedTitle"],
        "note"
    );
    assert_eq!(
        store
            .database
            .select_test("SELECT payload FROM meta WHERE key = 'schema'")
            .unwrap()[0]["payload"],
        "2"
    );
}
#[test]
fn private_store_directories_and_imported_audio_have_restricted_permissions() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
    let source = dir.path().join("note.wav");
    fs::write(&source, b"synthetic audio").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    assert_eq!(
        fs::metadata(&root).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(root.join("audio"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    assert_eq!(
        fs::metadata(root.join("library.rocksdb"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
    let recording = store.import(&source, None).unwrap();
    let audio = store.audio(recording["id"].as_str().unwrap()).unwrap();
    assert_eq!(
        fs::metadata(audio).unwrap().permissions().mode() & 0o777,
        0o600
    );
}
#[test]
fn trabajos_sobreviven_al_reinicio_y_a_cambios_de_la_biblioteca() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let audio = dir.path().join("sample.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let recording = store.import(&audio, None).unwrap();
    let job = json!({"id":"job-1","recordingId":recording["id"],"state":"queued","stage":"Transcribiendo","attempt":2});
    store.job_save(&job).unwrap();
    store
        .mutate("log", &json!({"message":"other change"}))
        .unwrap();
    assert_eq!(store.jobs().unwrap(), vec![job.clone()]);
    drop(store);
    let mut store = Store::open(root).unwrap();
    assert_eq!(store.jobs().unwrap(), vec![job]);
    store.job_remove("job-1").unwrap();
    assert!(store.jobs().unwrap().is_empty());
}
#[test]
fn memories_and_traces_survive_restart_without_entering_snapshot() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let audio = dir.path().join("sample.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let recording = store.import(&audio, None).unwrap();
    let recording_id = recording["id"].as_str().unwrap();
    let version = store
        .mutate(
            "version_save",
            &json!({"recordingId":recording_id,"transcript":{"text":"hola","segments":[]}}),
        )
        .unwrap();
    let version_id = version["id"].as_str().unwrap();
    let answer = json!({"value":{"answer":"respuesta"}});
    store
        .memory_keep(recording_id, version_id, "fingerprint-1", &answer)
        .unwrap();
    store.trace_save(&json!({"recordingId":recording_id,"recipeId":"default","startedAt":"2026-10-01T00:00:00Z","finishedAt":"2026-10-01T00:00:01Z","steps":[]})).unwrap();
    assert_eq!(
        store
            .memory_recall(recording_id, version_id, "fingerprint-1")
            .unwrap(),
        Some(answer.clone())
    );
    assert_eq!(store.trace_list(Some(recording_id)).unwrap().len(), 1);
    assert!(!store
        .snapshot()
        .unwrap()
        .to_string()
        .contains("fingerprint-1"));
    drop(store);
    let store = Store::open(root).unwrap();
    assert_eq!(
        store
            .memory_recall(recording_id, version_id, "fingerprint-1")
            .unwrap(),
        Some(answer)
    );
    assert_eq!(store.trace_list(Some(recording_id)).unwrap().len(), 1);
}
#[test]
fn deleting_recording_cleans_owned_audio_memory_and_traces_but_not_source() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let source = dir.path().join("sample.wav");
    fs::write(&source, b"synthetic audio").unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let recording = store.import(&source, None).unwrap();
    let recording_id = recording["id"].as_str().unwrap();
    let copy = store.audio(recording_id).unwrap();
    let version = store
        .mutate(
            "version_save",
            &json!({"recordingId":recording_id,"transcript":{"text":"hola","segments":[]}}),
        )
        .unwrap();
    let version_id = version["id"].as_str().unwrap();
    store
        .memory_keep(
            recording_id,
            version_id,
            "fingerprint-1",
            &json!({"value":"x"}),
        )
        .unwrap();
    store
        .trace_save(
            &json!({"recordingId":recording_id,"startedAt":"2026-10-01T00:00:00Z","steps":[]}),
        )
        .unwrap();
    store
        .job_save(&json!({"id":"job-active","recordingId":recording_id,"state":"running"}))
        .unwrap();
    store
        .mutate("recording_delete", &json!({"id":recording_id}))
        .unwrap();
    assert!(store.recording(recording_id).is_err());
    assert!(!copy.exists());
    assert_eq!(fs::read(&source).unwrap(), b"synthetic audio");
    assert!(store.trace_list(Some(recording_id)).unwrap().is_empty());
    assert!(store.jobs().unwrap().is_empty());
    drop(store);
    let store = Store::open(root).unwrap();
    assert!(store.recording(recording_id).is_err());
    assert!(store.trace_list(Some(recording_id)).unwrap().is_empty());
    assert!(store.jobs().unwrap().is_empty());
    assert!(store
        .database
        .recall(&json!([recording_id, version_id, "fingerprint-1"]).to_string())
        .unwrap()
        .is_none());
}
#[test]
fn empty_file_is_visible_and_reactivated_when_audio_arrives() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("late.wav");
    fs::write(&path, []).unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let failed = store
        .mutate("recording_abandoned", &json!({"path":path}))
        .unwrap();
    assert_eq!(failed["status"], "failed");
    assert!(failed["audioPath"].is_null());
    fs::write(&path, b"synthetic audio").unwrap();
    let recovered = store.import(&path, None).unwrap();
    assert_eq!(recovered["id"], failed["id"]);
    assert_eq!(recovered["status"], "pending");
    assert_eq!(store.data_json()["recordings"].as_array().unwrap().len(), 1);
}
#[test]
fn empty_voice_memo_recovers_after_rename_by_source_key() {
    let dir = tempfile::tempdir().unwrap();
    let old = dir.path().join("empty.m4a");
    fs::write(&old, []).unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let failed = store
        .mutate(
            "recording_abandoned",
            &json!({"path":old,"sourceKey":"voiceMemos:folder/42","title":"Sin audio"}),
        )
        .unwrap();
    let renamed = dir.path().join("complete.m4a");
    fs::rename(&old, &renamed).unwrap();
    fs::write(&renamed, b"synthetic audio").unwrap();
    let restored = store
        .import_with_metadata(
            &renamed,
            None,
            "Con audio",
            SystemTime::now(),
            "voiceMemos:folder/42",
        )
        .unwrap();
    assert_eq!(restored["id"], failed["id"]);
    assert_eq!(restored["status"], "pending");
    assert_eq!(restored["title"], "Con audio");
    assert_eq!(store.data_json()["recordings"].as_array().unwrap().len(), 1);
}
#[test]
fn imports_previous_experiment_json_once_and_keeps_it_untouched() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    fs::create_dir_all(&root).unwrap();
    let mut previous = defaults();
    previous["settings"]["language"] = json!("gl");
    previous["logs"] =
        json!([{"id":"old-log","at":"2026-10-01T00:00:00Z","message":"original","level":"info"}]);
    let bytes = serde_json::to_vec(&previous).unwrap();
    fs::write(root.join("library.json"), &bytes).unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    assert_eq!(store.data_json()["settings"]["language"], "gl");
    store
        .mutate("settings_save", &json!({"settings":{"launchAtLogin":true}}))
        .unwrap();
    drop(store);
    assert_eq!(fs::read(root.join("library.json")).unwrap(), bytes);
    let store = Store::open(root).unwrap();
    assert_eq!(store.data_json()["settings"]["language"], "gl");
    assert_eq!(store.data_json()["settings"]["launchAtLogin"], true);
    assert_eq!(
        store.log_list(&json!({})).unwrap()[0]["message"],
        "original"
    );
    assert_eq!(
        store
            .log_list(&json!({}))
            .unwrap()
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
#[test]
fn removing_account_removes_its_credential() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let account = json!({"collection":"accounts","item":{"id":"notion","name":"Notion","provider":"notion","enabled":true}});
    store.mutate("config_save", &account).unwrap();
    store.save_credential("notion", "synthetic-secret").unwrap();
    store
        .mutate(
            "config_remove",
            &json!({"collection":"accounts","id":"notion"}),
        )
        .unwrap();
    store.mutate("config_save", &account).unwrap();
    assert_eq!(store.credential("notion").unwrap(), None);
}
#[test]
fn guardar_una_receta_o_un_destino_sin_su_programa_conserva_el_compilado() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let recipe = json!({"id":"resumen","name":"Resumen","kind":"code","values":{},"bundle":"var __recipe = 1;"});
    store
        .mutate(
            "config_save",
            &json!({"collection":"recipes","item":recipe}),
        )
        .unwrap();
    store
            .mutate(
                "config_save",
                &json!({"collection":"recipes","item":{"id":"resumen","name":"Resumen","kind":"code","values":{"idioma":"en"},"bundleFingerprint":"abc"}}),
            )
            .unwrap();
    let saved = store.item("recipes", "resumen").unwrap();
    assert_eq!(saved["bundle"], "var __recipe = 1;");
    assert_eq!(saved["values"]["idioma"], "en");
    assert!(saved.get("bundleFingerprint").is_none());
}

#[test]
fn quitar_conector_borra_cuenta_destino_token_y_valores_sin_borrar_publicaciones() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    store.mutate("config_save", &json!({"collection":"accounts","item":{"id":"conector","name":"Notion","provider":"notion","enabled":true}})).unwrap();
    store.mutate("config_save", &json!({"collection":"destinations","item":{"id":"conector","name":"Notion","provider":"notion","account":"conector","enabled":true,"configuration":{}}})).unwrap();
    store
        .save_credential("conector", "synthetic-token")
        .unwrap();
    store.mutate("config_save", &json!({"collection":"recipes","item":{"id":"form","name":"Form","kind":"form","values":{"conectores":["conector","otro"]}}})).unwrap();
    let audio = dir.path().join("sample.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let record = store.import(&audio, None).unwrap();
    store.mutate("publication_save", &json!({"recordingId":record["id"],"destinationId":"conector","accountId":"conector","receipt":{"locator":"page-1","state":"published"}})).unwrap();

    store.remove_connector("conector").unwrap();

    assert!(store.item("accounts", "conector").is_err());
    assert!(store.item("destinations", "conector").is_err());
    assert_eq!(store.credential("conector").unwrap(), None);
    assert_eq!(
        store.item("recipes", "form").unwrap()["values"]["conectores"],
        json!(["otro"])
    );
    assert_eq!(
        store.recording(record["id"].as_str().unwrap()).unwrap()["publications"][0]["receipt"]
            ["locator"],
        "page-1"
    );
}

#[test]
fn guardar_conector_persiste_cuenta_y_destino_juntos_y_rechaza_pareja_incoherente() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let folder = dir.path().join("bundle");
    fs::create_dir(&folder).unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let account = json!({"id":"connector","name":"OKF","provider":"okf","enabled":true,"folder":folder,"hasCredential":true});
    let destination = json!({"id":"connector","name":"OKF","provider":"okf","account":"connector","enabled":false,"configuration":{"folder":folder,"documents":[]}});
    store.save_connector(&account, &destination).unwrap();
    assert_eq!(
        store.item("accounts", "connector").unwrap()["folder"],
        json!(folder.canonicalize().unwrap())
    );
    assert_eq!(
        store.item("destinations", "connector").unwrap()["configuration"]["folder"],
        json!(folder.canonicalize().unwrap())
    );
    assert!(store
        .item("accounts", "connector")
        .unwrap()
        .get("hasCredential")
        .is_none());
    assert_eq!(
        store.item("destinations", "connector").unwrap()["account"],
        "connector"
    );
    let mut revoked = account.clone();
    revoked["enabled"] = json!(false);
    store.save_connector(&revoked, &destination).unwrap();
    assert_eq!(
        store.item("accounts", "connector").unwrap()["enabled"],
        false
    );
    let before = store.data_json();
    assert!(store.save_connector(&account, &json!({"id":"wrong","name":"OKF","provider":"okf","account":"connector","configuration":{}})).is_err());
    assert!(store.save_connector(&account, &json!({"id":"connector","name":"OKF","provider":"notion","account":"connector","configuration":{}})).is_err());
    assert_eq!(store.data_json(), before);
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert_eq!(
        reopened.item("accounts", "connector").unwrap()["name"],
        "OKF"
    );
    assert_eq!(
        reopened.item("destinations", "connector").unwrap()["provider"],
        "okf"
    );
}

#[test]
fn cuenta_notion_desconectada_conserva_la_revocacion() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let account = json!({"id":"notion-test","name":"Notion","provider":"notion","enabled":false});
    let destination = json!({"id":"notion-test","name":"Notion","provider":"notion","account":"notion-test","enabled":false,"configuration":{}});
    store.save_connector(&account, &destination).unwrap();
    let saved = store.item("accounts", "notion-test").unwrap();
    assert_eq!(saved["enabled"], false);
    assert!(crate::capabilities::authorized_access(&saved, None, &json!({}), "http").is_err());
}

#[test]
fn failed_library_write_preserves_the_audio_copy() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("sample.wav");
    fs::write(&audio, b"synthetic audio").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let recording = store.import(&audio, None).unwrap();
    let key = recording["id"].as_str().unwrap();
    let saved = store.audio(key).unwrap();
    store.database.query_test(
            "DEFINE FIELD OVERWRITE payload ON TABLE recording ASSERT !string::contains($value, '\"audioPath\":null')",
        ).unwrap();
    assert!(store
        .mutate("recording_remove_audio", &json!({"id":key}))
        .is_err());
    assert!(saved.exists());
    assert_eq!(store.audio(key).unwrap(), saved);
}
#[test]
fn actualizar_olvida_recetas_antiguas_una_vez_y_conserva_elecciones_nuevas() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    fs::create_dir_all(&root).unwrap();
    let mut legacy = defaults();
    legacy["recordings"] = json!([{
        "id":"anterior", "source":"/synthetic/old.wav", "status":"done",
        "recipeId":"receta-antigua", "publications":[],
        "versions":[{"id":"version-anterior","recipeId":"receta-ejecutada","transcript":{"text":"ejemplo","segments":[]}}]
    }]);
    fs::write(
        root.join("library.json"),
        serde_json::to_vec(&legacy).unwrap(),
    )
    .unwrap();
    let mut store = Store::open(root.clone()).unwrap();
    let previous = store.recording("anterior").unwrap();
    assert_eq!(previous["recipeId"], Value::Null);
    assert_eq!(previous["versions"][0]["recipeId"], "receta-ejecutada");
    let audio = dir.path().join("nueva.wav");
    fs::write(&audio, b"eleccion nueva sintetica").unwrap();
    let added = store.import(&audio, Some("elegida-despues")).unwrap();
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert_eq!(
        reopened.recording("anterior").unwrap()["recipeId"],
        Value::Null
    );
    assert_eq!(
        reopened.recording(added["id"].as_str().unwrap()).unwrap()["recipeId"],
        "elegida-despues"
    );
}

#[test]
fn rejects_second_instance_without_replacing_data() {
    let dir = tempfile::tempdir().unwrap();
    let _first = Store::open(dir.path().into()).unwrap();
    assert!(Store::open(dir.path().into()).is_err());
}

#[test]
fn ajustes_rechazan_tipos_invalidos_sin_cambiar_la_biblioteca() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().into()).unwrap();
    let before = store.snapshot().unwrap();
    assert!(store
        .mutate(
            "settings_save",
            &json!({"settings":{"notifyEveryNote":"sí"}})
        )
        .is_err());
    assert_eq!(store.snapshot().unwrap(), before);
}

#[test]
fn opciones_retiradas_no_se_modifican_aunque_estuvieran_guardadas() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().into()).unwrap();
    let before = store.data_json()["settings"].clone();
    store.mutate("settings_save", &json!({"settings":{"language":"en","theme":"dark","autoProcess":false,"recipeSelectionMigrated":false}})).unwrap();
    assert_eq!(store.data_json()["settings"], before);
}

#[test]
fn no_confirma_entidades_corruptas_ni_pierde_el_estado_anterior() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().into()).unwrap();
    let before = store.snapshot().unwrap();
    let mut next = store.data_json();
    next["recordings"] = json!([{"id":"rota","status":"done","versions":[{"id":"v","transcript":{"text":42,"segments":[]}}]}]);
    assert!(store.replace(next).is_err());
    assert_eq!(store.snapshot().unwrap(), before);
}

#[test]
fn versiones_conservan_campos_extensibles_nulos_y_ausentes_al_reabrir() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("sintetico.wav");
    fs::write(&source, b"audio sintetico").unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&source, None).unwrap();
    let version = store.mutate("version_save", &json!({"recordingId":record["id"],"transcript":{"text":"sintetico","segments":[{"text":"sintetico","start":0,"end":1.5,"speaker":null,"words":[{"text":"sintetico","start":0,"end":1.5,"confidence":0.95}],"custom":true}],"language":"es","recognitions":null,"custom":{"nested":null}},"digest":null,"data":{"custom":42},"inputs":null})).unwrap();
    let mut data = store.data_json();
    data["recordings"][0]["custom"] = json!({"legitimate":true});
    data["recordings"][0]["versions"][0]["dataSchema"] = json!({"type":"object"});
    store.replace(data.clone()).unwrap();
    store
        .mutate(
            "version_select",
            &json!({"recordingId":record["id"],"versionId":version["id"]}),
        )
        .unwrap();
    assert_eq!(store.data_json(), data);
    drop(store);
    let reopened = Store::open(root).unwrap();
    assert_eq!(reopened.data_json(), data);
    let detail = reopened.recording(record["id"].as_str().unwrap()).unwrap();
    assert!(detail["versions"][0].get("recipeId").is_none());
    assert_eq!(detail["versions"][0]["digest"], Value::Null);
    assert_eq!(detail["versions"][0]["transcript"], version["transcript"]);
}

#[test]
#[ignore = "Solo con una copia consistente autorizada mediante ESCRIBA_VERIFY_LIBRARY_COPY"]
fn verifica_compatibilidad_de_copia_sin_mostrar_contenido() {
    fn copy_tree(source: &Path, destination: &Path) {
        fs::create_dir_all(destination).unwrap();
        for entry in fs::read_dir(source).unwrap() {
            let entry = entry.unwrap();
            let target = destination.join(entry.file_name());
            if entry.file_type().unwrap().is_dir() {
                copy_tree(&entry.path(), &target);
            } else {
                fs::copy(entry.path(), target).unwrap();
            }
        }
    }
    let source = PathBuf::from(
        std::env::var_os("ESCRIBA_VERIFY_LIBRARY_COPY").expect("Falta la copia autorizada"),
    );
    let temporary = tempfile::tempdir().unwrap();
    fs::set_permissions(temporary.path(), fs::Permissions::from_mode(0o700)).unwrap();
    copy_tree(&source, &temporary.path().join("library.rocksdb"));
    let database = Persistence::open(&temporary.path().join("library.rocksdb")).unwrap();
    let before = database
        .load()
        .unwrap()
        .expect("La copia no contiene biblioteca");
    let typed = LibraryData::read(&before).expect("La copia no cumple el contrato de entidades");
    assert!(
        json!(&typed) == before,
        "La representación tipada cambió campos guardados"
    );
    let recordings = typed.recordings.len();
    let versions: usize = typed
        .recordings
        .iter()
        .filter_map(|record| record.versions.as_ref())
        .map(Vec::len)
        .sum();
    drop(database);
    let store = Store::open_with_audio_cleanup(temporary.path().into(), false)
        .expect("La copia no se puede reabrir");
    let jobs = store
        .jobs()
        .expect("No se pudieron leer trabajos guardados");
    for job in &jobs {
        let _: crate::jobs::Job = serde_json::from_value(job.clone())
            .expect("Un trabajo guardado no cumple el contrato tipado");
    }
    assert_eq!(store.data.recordings.len(), recordings);
    assert_eq!(
        store
            .data
            .recordings
            .iter()
            .filter_map(|record| record.versions.as_ref())
            .map(Vec::len)
            .sum::<usize>(),
        versions
    );
    for original in before["recordings"].as_array().unwrap() {
        let full = store.recording(original["id"].as_str().unwrap()).unwrap();
        if original["status"] == "discarded" {
            assert_eq!(original["versions"].as_array().map(Vec::len), Some(0));
            assert_eq!(original["publications"].as_array().map(Vec::len), Some(0));
            assert!(
                full == discarded_record(original).unwrap(),
                "La lápida cambió su identidad"
            );
            continue;
        }
        assert!(
            full["versions"] == original["versions"],
            "El índice alteró versiones guardadas"
        );
        assert!(
            full["publications"] == original["publications"],
            "El índice alteró recibos guardados"
        );
    }
    eprintln!("Compatibilidad confirmada: {recordings} grabaciones, {versions} versiones, {} trabajos; contenido no mostrado", jobs.len());
}

#[test]
fn biblioteca_tipificada_conserva_la_vista_ligera_sin_texto_completo_ni_programas() {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().into()).unwrap();
    let mut data = store.data_json();
    data["recordings"] = json!([{"id":"nota","status":"done","title":"sintetico","duration":1,"versions":[{"id":"v","backend":"test","transcript":{"text":"x".repeat(500),"segments":[{"text":"x","start":0,"end":1,"words":[{"text":"x","start":0,"end":1}]}],"language":"es"}}],"publications":[]}]);
    data["recipes"][0]["bundle"] = json!("programa sintetico".repeat(1000));
    store.replace(data).unwrap();
    let mut expected = crate::library_view::light_library(&store.data_json());
    expected["settings"] = redacted_settings(&expected["settings"]);
    expected["dataPath"] = json!(store.root);
    store.mark_credentials(&mut expected);
    assert_eq!(store.library(), expected);
    assert_eq!(
        store.library()["recordings"][0]["versions"][0]["transcript"]["text"]
            .as_str()
            .unwrap()
            .len(),
        400
    );
    assert!(store.library()["recipes"][0].get("bundle").is_none());
}
#[test]
fn operacion_de_cuenta_incierta_sobrevive_reapertura_hasta_resolucion_manual() {
    let temp = tempfile::tempdir().unwrap();
    let audio = temp.path().join("synthetic.wav");
    std::fs::write(&audio, b"synthetic audio").unwrap();
    let root = temp.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&audio, None).unwrap();
    let id = record["id"].as_str().unwrap();
    store
        .mutate("account_effect_begin", &json!({"recordingId":id}))
        .unwrap();
    assert_eq!(store.recording(id).unwrap()["accountEffectPending"], true);
    assert_eq!(
        store.runtime_context(Some(id)).unwrap()["recordings"][0]["accountEffectPending"],
        true
    );
    drop(store);
    let mut store = Store::open(root).unwrap();
    assert_eq!(store.recording(id).unwrap()["accountEffectPending"], true);
    store
        .mutate("account_effect_finish", &json!({"recordingId":id}))
        .unwrap();
    assert!(store.recording(id).unwrap()["accountEffectPending"].is_null());
    assert_eq!(
        store.runtime_context(Some(id)).unwrap()["recordings"][0]["accountEffectPending"],
        false
    );
}

#[test]
fn borrador_duradero_acumula_cambios_sin_crear_versiones() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("sintetico.wav");
    fs::write(&audio, b"audio sintetico").unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&audio, None).unwrap();
    let key = record["id"].as_str().unwrap();
    let version = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":{"text":"original","segments":[]}}),
        )
        .unwrap();
    let draft = store
        .mutate("note_draft_begin", &json!({"recordingId":key}))
        .unwrap();
    let mut content = draft["content"].clone();
    content["title"] = json!("Editado");
    content["transcript"]["text"] = json!("corregido");
    let saved = store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":draft["revision"],"content":content})).unwrap();
    let mut second_content = saved["content"].clone();
    second_content["data"] = json!({"segundo":true});
    let saved = store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1,"content":second_content})).unwrap();
    assert_eq!(saved["revision"], 2);
    drop(store);
    let mut store = Store::open(root).unwrap();
    assert_eq!(
        store
            .mutate("note_draft_get", &json!({"recordingId":key}))
            .unwrap(),
        saved
    );
    assert_eq!(store.recording(key).unwrap()["versions"], json!([version]));
    assert!(!store.index_json().to_string().contains("corregido"));
    assert!(!store.snapshot().unwrap().to_string().contains("corregido"));
    assert!(!store
        .runtime_context(Some(key))
        .unwrap()
        .to_string()
        .contains("corregido"));
}

#[test]
fn confirmar_borrador_crea_una_version_atomica_y_es_idempotente() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("sintetico.wav");
    fs::write(&audio, b"audio sintetico").unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    let record = store.import(&audio, None).unwrap();
    let key = record["id"].as_str().unwrap();
    let original = store.mutate("version_save", &json!({"recordingId":key,"recipeId":"sintetica","inputs":{"uno":1},"transcript":{"text":"original","segments":[]},"digest":{"title":"Original","summary":"Resumen","tags":[]},"data":{"uno":1}})).unwrap();
    let draft = store
        .mutate("note_draft_begin", &json!({"recordingId":key}))
        .unwrap();
    let mut content = draft["content"].clone();
    content["title"] = json!("Editado");
    content["transcript"]["text"] = json!("corregido");
    content["digest"]["summary"] = json!("Resumen editado");
    content["data"] = json!({"dos":2});
    let saved = store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content})).unwrap();
    let params =
        json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":saved["revision"]});
    let result = store.mutate("note_draft_commit", &params).unwrap();
    assert_eq!(result["created"], true);
    assert_eq!(result["version"]["digest"]["title"], "Editado");
    assert_eq!(result["version"]["transcript"]["text"], "corregido");
    assert_eq!(result["version"]["inputs"], json!({"uno":1}));
    assert_eq!(result["version"]["recipeId"], "sintetica");
    assert_eq!(result["version"]["data"], json!({"dos":2}));
    drop(store);
    let mut store = Store::open(root).unwrap();
    assert_eq!(store.mutate("note_draft_commit", &params).unwrap(), result);
    let detail = store.recording(key).unwrap();
    assert_eq!(detail["versions"].as_array().unwrap().len(), 2);
    assert_eq!(detail["versions"][0], original);
    assert_eq!(detail["audioPath"], record["audioPath"]);
    assert_eq!(
        store
            .mutate("note_draft_get", &json!({"recordingId":key}))
            .unwrap(),
        Value::Null
    );
    assert!(audio.exists());
}

fn note_draft_fixture() -> (tempfile::TempDir, Store, String, Value) {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("sintetico.wav");
    fs::write(&audio, b"audio sintetico").unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let record = store.import(&audio, None).unwrap();
    let key = record["id"].as_str().unwrap().to_owned();
    store.mutate("version_save", &json!({"recordingId":key,"transcript":{"text":"original","segments":[{"start":0,"end":1,"text":"original","speaker":"A"}]}})).unwrap();
    let draft = store
        .mutate("note_draft_begin", &json!({"recordingId":key}))
        .unwrap();
    (dir, store, key, draft)
}

#[test]
fn borrador_rechaza_carreras_y_base_modificada_sin_perder_ediciones() {
    let (_dir, mut store, key, draft) = note_draft_fixture();
    let mut content = draft["content"].clone();
    content["title"] = json!("Edición local");
    let params =
        json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content});
    let saved = store.mutate("note_draft_save", &params).unwrap();
    assert!(store.mutate("note_draft_save", &params).is_err());
    assert!(store.mutate("note_draft_commit", &params).is_err());
    assert!(store.mutate("note_draft_discard", &params).is_err());
    store
        .mutate(
            "version_update",
            &json!({"recordingId":key,"versionId":draft["baseVersionId"],"data":{"externo":true}}),
        )
        .unwrap();
    let latest =
        json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1,"content":content});
    assert!(store.mutate("note_draft_commit", &latest).is_err());
    assert!(store.mutate("note_draft_save", &latest).is_err());
    assert_eq!(
        store
            .mutate("note_draft_get", &json!({"recordingId":key}))
            .unwrap(),
        saved
    );
    store.mutate("note_draft_discard", &latest).unwrap();
    assert_eq!(
        store.recording(&key).unwrap()["versions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn borrador_sin_cambios_se_cierra_sin_version_y_descartada_no_resucita() {
    let (dir, mut store, key, draft) = note_draft_fixture();
    let params = json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0});
    let original = store.recording(&key).unwrap();
    let result = store.mutate("note_draft_commit", &params).unwrap();
    assert_eq!(result["created"], false);
    assert_eq!(store.recording(&key).unwrap(), original);
    assert_eq!(store.mutate("note_draft_commit", &params).unwrap(), result);
    let draft = store
        .mutate("note_draft_begin", &json!({"recordingId":key}))
        .unwrap();
    store
        .mutate("recording_discard", &json!({"id":key}))
        .unwrap();
    drop(store);
    let mut store = Store::open(dir.path().join("library")).unwrap();
    for method in [
        "note_draft_begin",
        "note_draft_get",
        "note_draft_save",
        "note_draft_commit",
    ] {
        assert!(store.mutate(method, &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":draft["content"]})).is_err());
    }
}

#[test]
fn borrador_rechaza_tiempos_y_tipos_invalidos_sin_reemplazarlo() {
    let (_dir, mut store, key, draft) = note_draft_fixture();
    for invalid in [json!(4), json!(false), Value::Null, json!([])] {
        assert!(store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":invalid})).is_err());
    }

    for bad in [
        json!({"start":2,"end":1,"text":"invalido"}),
        json!({"start":-1,"end":1,"text":"invalido"}),
        json!({"start":0,"end":1,"text":false}),
    ] {
        let mut content = draft["content"].clone();
        content["transcript"]["segments"] = json!([bad]);
        assert!(store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content})).is_err());
    }
    assert_eq!(
        store
            .mutate("note_draft_get", &json!({"recordingId":key}))
            .unwrap(),
        draft
    );
}

#[test]
fn borrador_confirmado_falla_atomicamente_y_permite_reintentar() {
    let (_dir, mut store, key, draft) = note_draft_fixture();
    let original = store.recording(&key).unwrap();
    let mut content = draft["content"].clone();
    content["title"] = json!("Cambio");
    let saved = store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content})).unwrap();
    store
        .database
        .query_test(
            "DEFINE FIELD OVERWRITE payload ON TABLE note_draft_receipt TYPE object ASSERT false",
        )
        .unwrap();
    let params = json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1});
    assert!(store.mutate("note_draft_commit", &params).is_err());
    assert_eq!(store.recording(&key).unwrap(), original);
    assert_eq!(
        store
            .mutate("note_draft_get", &json!({"recordingId":key}))
            .unwrap(),
        saved
    );
    store
        .database
        .query_test("DEFINE FIELD OVERWRITE payload ON TABLE note_draft_receipt TYPE object")
        .unwrap();
    assert_eq!(
        store.mutate("note_draft_commit", &params).unwrap()["created"],
        true
    );
    assert_eq!(
        store.recording(&key).unwrap()["versions"][0],
        original["versions"][0]
    );
}

#[test]
fn borrador_asigna_fragmentos_sin_aprender_huellas_ambiguas() {
    let (_dir, mut store, key, initial) = note_draft_fixture();
    store
        .mutate(
            "note_draft_discard",
            &json!({"recordingId":key,"draftId":initial["id"],"expectedRevision":0}),
        )
        .unwrap();
    let transcript = store.recognize_transcription(&key, json!({"text":"uno dos tres","segments":[{"start":0,"end":1,"text":"uno","speaker":"A"},{"start":1,"end":2,"text":"dos","speaker":"A"},{"start":2,"end":3,"text":"tres","speaker":"B"}],"voices":[{"speaker":"A","model":"m","embedding":[1.0,0.0]},{"speaker":"B","model":"m","embedding":[0.0,1.0]}]})).unwrap();
    let source = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":transcript}),
        )
        .unwrap();
    let draft = store
        .mutate("note_draft_begin", &json!({"recordingId":key}))
        .unwrap();
    let mut content = draft["content"].clone();
    content["transcript"]["segments"][0]["speaker"] = json!("Persona");
    store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content})).unwrap();
    let committed = store
        .mutate(
            "note_draft_commit",
            &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1}),
        )
        .unwrap();
    let copied = store
        .database
        .version_voices(committed["version"]["id"].as_str().unwrap())
        .unwrap();
    assert_eq!(copied.len(), 1);
    assert_eq!(copied[0].speaker, "B");
    assert!(store.known_voices().unwrap().is_empty());
    assert_eq!(
        store
            .database
            .version_voices(source["id"].as_str().unwrap())
            .unwrap()
            .len(),
        2
    );
    assert!(!committed.to_string().contains("embedding"));
    store
        .mutate(
            "version_select",
            &json!({"recordingId":key,"versionId":source["id"]}),
        )
        .unwrap();
    let draft = store
        .mutate("note_draft_begin", &json!({"recordingId":key}))
        .unwrap();
    let mut content = draft["content"].clone();
    content["transcript"]["segments"][0]["speaker"] = json!("B");
    store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content})).unwrap();
    let committed = store
        .mutate(
            "note_draft_commit",
            &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1}),
        )
        .unwrap();
    assert_eq!(committed["version"]["hasVoices"], false);
}

#[test]
fn borrador_legacy_sin_version_vigente_usa_la_ultima_por_fecha_sin_duplicarla() {
    for current_id in [Value::Null, json!("inexistente")] {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(dir.path().join("library")).unwrap();
        let mut legacy = store.data_json();
        legacy["recordings"] = json!([{"id":"legacy","title":"Original","status":"done","currentVersionId":current_id,"versions":[
            {"id":"reciente","createdAt":"2026-02-01","transcript":{"text":"reciente","segments":[]}},
            {"id":"antigua","createdAt":"2026-01-01","transcript":{"text":"antigua","segments":[]}}
        ],"publications":[]}]);
        if current_id.is_null() {
            legacy["recordings"][0]
                .as_object_mut()
                .unwrap()
                .remove("currentVersionId");
        }
        store.replace(legacy).unwrap();
        let before = store.recording("legacy").unwrap();
        let draft = store
            .mutate("note_draft_begin", &json!({"recordingId":"legacy"}))
            .unwrap();
        assert_eq!(draft["baseVersionId"], "reciente");
        let params = json!({"recordingId":"legacy","draftId":draft["id"],"expectedRevision":0});
        let result = store.mutate("note_draft_commit", &params).unwrap();
        assert_eq!(result["created"], false);
        assert_eq!(result["version"]["id"], "reciente");
        assert_eq!(store.mutate("note_draft_commit", &params).unwrap(), result);
        assert_eq!(store.recording("legacy").unwrap(), before);
        let draft = store
            .mutate("note_draft_begin", &json!({"recordingId":"legacy"}))
            .unwrap();
        let mut content = draft["content"].clone();
        content["title"] = json!("Título manual");
        store.mutate("note_draft_save", &json!({"recordingId":"legacy","draftId":draft["id"],"expectedRevision":0,"content":content})).unwrap();
        let params = json!({"recordingId":"legacy","draftId":draft["id"],"expectedRevision":1});
        let result = store.mutate("note_draft_commit", &params).unwrap();
        assert_eq!(result["created"], true);
        assert_eq!(result["version"]["transcript"]["text"], "reciente");
        assert_eq!(store.mutate("note_draft_commit", &params).unwrap(), result);
        let detail = store.recording("legacy").unwrap();
        assert_eq!(detail["versions"].as_array().unwrap().len(), 3);
        assert_eq!(detail["versions"][0], before["versions"][0]);
        assert_eq!(detail["versions"][1], before["versions"][1]);
    }
}

#[test]
fn borrador_conserva_titulo_manual_tras_regenerar_resumen() {
    let (_dir, mut store, key, draft) = note_draft_fixture();
    let mut content = draft["content"].clone();
    content["title"] = json!("Título manual");
    store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content})).unwrap();
    let result = store
        .mutate(
            "note_draft_commit",
            &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1}),
        )
        .unwrap();
    store.mutate("version_update", &json!({"recordingId":key,"versionId":result["version"]["id"],"digest":{"title":"Título regenerado","summary":"Resumen nuevo","tags":[]}})).unwrap();
    let draft = store
        .mutate("note_draft_begin", &json!({"recordingId":key}))
        .unwrap();
    assert_eq!(draft["content"]["title"], "Título manual");
    assert_eq!(draft["content"]["digest"]["summary"], "Resumen nuevo");
    store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":draft["content"]})).unwrap();
    let result = store
        .mutate(
            "note_draft_commit",
            &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1}),
        )
        .unwrap();
    assert_eq!(result["created"], false);
}

#[test]
fn color_persona_se_conserva_al_anadir_huellas_reabrir_y_renombrar() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let store = Store::open(root.clone()).unwrap();
    let voice = SpeakerVoice {
        speaker: "S".into(),
        model: "m".into(),
        embedding: vec![1.0, 0.0],
    };
    store.add_person_voice("Ana", &voice, "sintetico").unwrap();
    store.set_person_color("Ana", "#Ab12Cd").unwrap();
    store.add_person_voice("Ana", &voice, "sintetico2").unwrap();
    drop(store);
    let store = Store::open(root).unwrap();
    store.rename_person("Ana", "Alicia").unwrap();
    let people = store.people().unwrap();
    assert_eq!(people[0]["name"], "Alicia");
    assert_eq!(people[0]["color"], "#Ab12Cd");
    assert_eq!(people[0]["voices"].as_array().unwrap().len(), 2);
    assert!(!people.to_string().contains("embedding"));
    for invalid in ["red", "#abc", "#12345678", "#GG1234", "123456", "#12 456"] {
        assert!(store.set_person_color("Alicia", invalid).is_err());
    }
    assert!(store.set_person_color("Desconocida", "#123456").is_err());
    assert_eq!(store.people().unwrap(), people);
    store.remove_person("Alicia").unwrap();
    store
        .add_person_voice("Alicia", &voice, "sintetico3")
        .unwrap();
    assert!(store.people().unwrap()[0].get("color").is_none());
}

#[test]
fn color_persona_fusionada_prioriza_destino_y_hereda_si_no_tiene() {
    for target_color in [None, Some("#112233")] {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().join("library");
        let store = Store::open(root.clone()).unwrap();
        let voice = SpeakerVoice {
            speaker: "S".into(),
            model: "m".into(),
            embedding: vec![1.0, 0.0],
        };
        store
            .add_person_voice("Origen", &voice, "sintetico")
            .unwrap();
        store
            .add_person_voice("Destino", &voice, "sintetico")
            .unwrap();
        store.set_person_color("Origen", "#AABBCC").unwrap();
        if let Some(color) = target_color {
            store.set_person_color("Destino", color).unwrap();
        }
        store.rename_person("Origen", "Destino").unwrap();
        drop(store);
        let store = Store::open(root).unwrap();
        let people = store.people().unwrap();
        assert_eq!(people.as_array().unwrap().len(), 1);
        assert_eq!(people[0]["name"], "Destino");
        assert_eq!(people[0]["color"], target_color.unwrap_or("#AABBCC"));
        assert_eq!(people[0]["voices"].as_array().unwrap().len(), 2);
    }
}

#[test]
fn dividir_hablante_conserva_solo_huellas_con_intervalos_inequivocos() {
    let (_dir, mut store, key, initial) = note_draft_fixture();
    store
        .mutate(
            "note_draft_discard",
            &json!({"recordingId":key,"draftId":initial["id"],"expectedRevision":0}),
        )
        .unwrap();
    let transcript = store.recognize_transcription(&key, json!({"text":"uno dos tres","segments":[{"start":0,"end":2,"text":"uno dos","speaker":"A"},{"start":2,"end":3,"text":"tres","speaker":"B"}],"voices":[{"speaker":"A","model":"m","embedding":[1.0,0.0]},{"speaker":"B","model":"m","embedding":[0.0,1.0]}]})).unwrap();
    let source = store
        .mutate(
            "version_save",
            &json!({"recordingId":key,"transcript":transcript}),
        )
        .unwrap();
    for (segments, expected) in [
        (
            json!([{"start":0,"end":1,"text":"uno","speaker":"A"},{"start":1,"end":2,"text":"dos","speaker":"Persona"},{"start":2,"end":3,"text":"tres","speaker":"B"}]),
            vec!["B"],
        ),
        (
            json!([{"start":0,"end":2,"text":"uno","speaker":"A","timingShared":true},{"start":0,"end":2,"text":"dos","speaker":"Persona","timingShared":true},{"start":2,"end":3,"text":"tres","speaker":"B"}]),
            vec!["B"],
        ),
        (
            json!([{"start":0,"end":1,"text":"uno","speaker":"A"},{"start":1,"end":2,"text":"dos","speaker":"B"},{"start":2,"end":3,"text":"tres","speaker":"B"}]),
            vec![],
        ),
        (
            json!([{"start":0,"end":2,"text":"uno dos","speaker":"A"},{"start":2,"end":3,"text":"tres","speaker":"B"},{"start":2,"end":3,"text":"duplicado","speaker":"Otra"}]),
            vec!["A"],
        ),
        (
            json!([{"start":0,"end":2,"text":"uno dos","speaker":"Renombrada"},{"start":2,"end":3,"text":"tres","speaker":"B"}]),
            vec!["Renombrada", "B"],
        ),
    ] {
        store
            .mutate(
                "version_select",
                &json!({"recordingId":key,"versionId":source["id"]}),
            )
            .unwrap();
        let draft = store
            .mutate("note_draft_begin", &json!({"recordingId":key}))
            .unwrap();
        let mut content = draft["content"].clone();
        content["transcript"]["segments"] = segments;
        store.mutate("note_draft_save", &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":0,"content":content})).unwrap();
        let result = store
            .mutate(
                "note_draft_commit",
                &json!({"recordingId":key,"draftId":draft["id"],"expectedRevision":1}),
            )
            .unwrap();
        let voices = store
            .version_voices(result["version"]["id"].as_str().unwrap())
            .unwrap();
        assert_eq!(
            voices
                .iter()
                .map(|voice| voice.speaker.as_str())
                .collect::<Vec<_>>(),
            expected
        );
        assert_eq!(
            store
                .version_voices(source["id"].as_str().unwrap())
                .unwrap()
                .len(),
            2
        );
        assert!(store.known_voices().unwrap().is_empty());
        assert!(!result.to_string().contains("embedding"));
    }
}

fn drain_knowledge(store: &Store) -> Vec<String> {
    let mut changed = Vec::new();
    while let Some(change) = store.knowledge_change().unwrap() {
        changed.push(change.id.clone());
        store.knowledge_ack(&change.key, &change.revision).unwrap();
    }
    changed
}

fn synthetic_library(count: usize) -> (tempfile::TempDir, Store, Vec<String>) {
    let dir = tempfile::tempdir().unwrap();
    let mut store = Store::open(dir.path().join("library")).unwrap();
    let mut ids = Vec::new();
    for index in 0..count {
        let audio = dir.path().join(format!("nota-{index}.wav"));
        fs::write(&audio, format!("audio sintético {index}")).unwrap();
        let recording = store.import(&audio, None).unwrap();
        ids.push(recording["id"].as_str().unwrap().to_owned());
    }
    drain_knowledge(&store);
    (dir, store, ids)
}

#[test]
fn incorporar_una_nota_solo_reescribe_esa_nota() {
    let (dir, mut store, ids) = synthetic_library(12);
    let audio = dir.path().join("nueva.wav");
    fs::write(&audio, b"audio sintetico nuevo").unwrap();
    let recording = store.import(&audio, None).unwrap();
    assert_eq!(
        drain_knowledge(&store),
        vec![recording["id"].as_str().unwrap().to_owned()]
    );
    store
        .mutate(
            "recording_update",
            &json!({"id":ids[5],"title":"Otro título"}),
        )
        .unwrap();
    assert_eq!(drain_knowledge(&store), vec![ids[5].clone()]);
}

#[test]
fn registrar_una_linea_no_toca_la_biblioteca_y_se_lee_aparte() {
    let (_dir, mut store, ids) = synthetic_library(3);
    store
        .mutate(
            "log",
            &json!({"message":"primera","level":"warn","recordingId":ids[1]}),
        )
        .unwrap();
    store.mutate("log", &json!({"message":"segunda"})).unwrap();
    assert!(drain_knowledge(&store).is_empty());
    assert!(store.library().get("logs").is_none());
    assert!(store.snapshot().unwrap().get("logs").is_none());
    let lines = store.log_list(&json!({})).unwrap();
    let messages: Vec<_> = lines
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line["message"].as_str().unwrap())
        .collect();
    assert_eq!(messages, vec!["segunda", "primera"]);
    let only = store.log_list(&json!({"recordingId":ids[1]})).unwrap();
    assert_eq!(only.as_array().unwrap().len(), 1);
    assert_eq!(only[0]["level"], "warn");
    let first_at = lines[0]["at"].as_str().unwrap();
    let older = store
        .log_list(&json!({"before":first_at,"limit":5}))
        .unwrap();
    assert_eq!(older[0]["message"], "primera");
    assert!(store
        .mutate("log", &json!({"message":"x","level":"grave"}))
        .is_err());
    assert!(store.log_list(&json!({"desconocido":true})).is_err());
}

#[test]
fn los_registros_anteriores_se_leen_por_fecha_sin_reescribirse() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let store = Store::open(root.clone()).unwrap();
    for (position, (id, at)) in [
        ("antigua", "2026-10-01T08:00:00+00:00"),
        ("reciente", "2026-10-03T08:00:00+00:00"),
        ("media", "2026-10-02T08:00:00+00:00"),
    ]
    .into_iter()
    .enumerate()
    {
        store
            .database
            .query_test(&format!("CREATE log:{id} SET key = '{id}', parent = '', position = {position}, payload = {{ id: '{id}', at: '{at}', message: '{id}', level: 'info' }}"))
            .unwrap();
    }
    drop(store);
    let store = Store::open(root).unwrap();
    let lines = store.log_list(&json!({})).unwrap();
    let ids: Vec<_> = lines
        .as_array()
        .unwrap()
        .iter()
        .map(|line| line["id"].as_str().unwrap())
        .collect();
    assert_eq!(ids, vec!["reciente", "media", "antigua"]);
    assert!(store.library().get("logs").is_none());
}

#[test]
fn el_registro_conserva_las_ultimas_lineas() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let store = Store::open(root.clone()).unwrap();
    let total = crate::persistence::LOG_RETAINED + 70;
    store
        .database
        .query_test(&format!("FOR $index IN 0..{total} {{ LET $id = 'l' + <string> $index; CREATE type::record('log', $id) SET key = $id, parent = '', position = 0, payload = {{ id: $id, at: '2026-10-11T00:00:00.' + string::slice('000000' + <string> $index, -6) + '+00:00', message: 'línea', level: 'info' }}; }}"))
        .unwrap();
    drop(store);
    let store = Store::open(root).unwrap();
    let stored = store.database.select_test("SELECT key FROM log").unwrap();
    assert!(stored.len() <= crate::persistence::LOG_RETAINED);
    let lines = store.log_list(&json!({})).unwrap();
    assert_eq!(lines[0]["id"], format!("l{}", total - 1));
}

#[test]
fn la_lista_ordena_por_fecha_al_reabrir_aunque_se_incorpore_fuera_de_orden() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("library");
    let mut store = Store::open(root.clone()).unwrap();
    for (name, day) in [("b", 2), ("c", 3), ("a", 1)] {
        let audio = dir.path().join(format!("{name}.m4a"));
        fs::write(&audio, format!("audio {name}")).unwrap();
        let started =
            std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_790_000_000 + day * 86_400);
        store
            .import_with_metadata(&audio, None, name, started, &format!("clave-{name}"))
            .unwrap();
    }
    drop(store);
    let store = Store::open(root).unwrap();
    let titles: Vec<_> = store
        .data
        .recordings
        .iter()
        .map(|record| record.title.as_ref().unwrap().clone())
        .collect();
    assert_eq!(titles, vec!["c", "b", "a"]);
}

#[test]
fn preparar_el_audio_no_toca_la_biblioteca_y_limpia_su_copia() {
    let (dir, mut store, _) = synthetic_library(0);
    let audio = dir.path().join("preparada.wav");
    fs::write(&audio, b"audio sintetico preparado").unwrap();
    let temporaries = |root: &Path| {
        fs::read_dir(root.join("audio"))
            .unwrap()
            .filter(|entry| {
                entry
                    .as_ref()
                    .unwrap()
                    .file_name()
                    .to_string_lossy()
                    .ends_with(".import")
            })
            .count()
    };
    let staged = stage_audio(&store.root, &audio, false).unwrap();
    assert_eq!(temporaries(&store.root), 1);
    assert!(drain_knowledge(&store).is_empty());
    let other = dir.path().join("otra.wav");
    fs::write(&other, b"otro audio").unwrap();
    assert!(store.import_staged(staged, &other, None).is_err());
    assert_eq!(temporaries(&store.root), 0);
    let staged = stage_audio(&store.root, &audio, false).unwrap();
    let record = store.import_staged(staged, &audio, None).unwrap();
    assert_eq!(temporaries(&store.root), 0);
    assert_eq!(
        store.recording(record["id"].as_str().unwrap()).unwrap()["status"],
        "pending"
    );
    drop(stage_audio(&store.root, &audio, false).unwrap());
    assert_eq!(temporaries(&store.root), 0);
}
