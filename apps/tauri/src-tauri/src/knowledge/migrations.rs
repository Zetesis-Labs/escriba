use super::*;
use surrealdb_expr::expr::{
    statements::{AlterStatement, DefineStatement, RemoveStatement},
    visit::{Visit, Visitor},
    Expr, Literal, LogicalPlan, TopLevelExpr,
};

pub(super) fn validate_sql(sql: &str) -> Result<(), String> {
    let ast = surrealdb_core::syn::parse(sql).map_err(error)?;
    let plan: LogicalPlan = ast.into();
    let mut guard = MigrationGuard;
    for expression in plan.expressions {
        guard.visit_top_level_expr(&expression)?;
    }
    Ok(())
}
struct MigrationGuard;
impl Visitor for MigrationGuard {
    type Error = String;
    fn visit_top_level_expr(&mut self, value: &TopLevelExpr) -> Result<(), String> {
        if !matches!(value, TopLevelExpr::Expr(_)) {
            return Err(
                "Las migraciones no admiten control de sesión, transacción ni administración"
                    .into(),
            );
        }
        value.visit(self)
    }
    fn visit_define(&mut self, value: &DefineStatement) -> Result<(), String> {
        if !matches!(
            value,
            DefineStatement::Table(_)
                | DefineStatement::Field(_)
                | DefineStatement::Index(_)
                | DefineStatement::Function(_)
                | DefineStatement::Analyzer(_)
                | DefineStatement::Sequence(_)
                | DefineStatement::Param(_)
        ) {
            return Err(
                "La migración no puede definir eventos, autenticación ni recursos administrativos"
                    .into(),
            );
        }
        if let DefineStatement::Table(table) = value {
            if table.view.is_some() {
                return Err("Las vistas de tabla no están disponibles para ontologías".into());
            }
        }
        value.visit(self)
    }
    fn visit_alter(&mut self, value: &AlterStatement) -> Result<(), String> {
        if !matches!(
            value,
            AlterStatement::Table(_)
                | AlterStatement::Field(_)
                | AlterStatement::Index(_)
                | AlterStatement::Function(_)
                | AlterStatement::Analyzer(_)
                | AlterStatement::Sequence(_)
                | AlterStatement::Param(_)
        ) {
            return Err("La migración no puede alterar eventos ni recursos administrativos".into());
        }
        value.visit(self)
    }
    fn visit_remove(&mut self, value: &RemoveStatement) -> Result<(), String> {
        if !matches!(
            value,
            RemoveStatement::Table(_)
                | RemoveStatement::Field(_)
                | RemoveStatement::Index(_)
                | RemoveStatement::Function(_)
                | RemoveStatement::Analyzer(_)
                | RemoveStatement::Sequence(_)
                | RemoveStatement::Param(_)
        ) {
            return Err("La migración no puede quitar eventos ni recursos administrativos".into());
        }
        value.visit(self)
    }
    fn visit_reference(
        &mut self,
        value: &surrealdb_expr::expr::reference::Reference,
    ) -> Result<(), String> {
        if matches!(
            value.on_delete,
            surrealdb_expr::expr::reference::ReferenceDeleteStrategy::Custom(_)
        ) {
            return Err(
                "Las acciones personalizadas ON DELETE no están disponibles para ontologías".into(),
            );
        }
        value.visit(self)
    }
    fn visit_expr(&mut self, value: &Expr) -> Result<(), String> {
        if let Expr::Table(table) = value {
            reserved(table.as_str())?;
        }
        value.visit(self)
    }
    fn visit_literal(&mut self, value: &Literal) -> Result<(), String> {
        match value {
            Literal::String(value) => reserved(value.as_str())?,
            Literal::RecordId(value) => reserved(value.table.as_str())?,
            _ => {}
        }
        value.visit(self)
    }
}
fn reserved(value: &str) -> Result<(), String> {
    if value.starts_with("_escriba_") {
        return Err("El espacio _escriba_ está reservado al host".into());
    }
    Ok(())
}

pub(super) async fn host_state(
    tx: &surrealdb::method::Transaction<Db>,
) -> Result<Vec<DbValue>, String> {
    let mut state=values(tx.query("SELECT * FROM _escriba_manifest ORDER BY id; SELECT * FROM _escriba_manual ORDER BY id; SELECT * FROM _escriba_source ORDER BY id; SELECT * FROM _escriba_principal ORDER BY id; INFO FOR TABLE _escriba_manifest; INFO FOR TABLE _escriba_manual; INFO FOR TABLE _escriba_source; INFO FOR TABLE _escriba_principal;").await.map_err(error)?)?;
    let mut info = tx
        .query("INFO FOR DB")
        .await
        .map_err(error)?
        .check()
        .map_err(error)?;
    let info: DbValue = info.take(0).map_err(error)?;
    let info = info.into_json_value();
    for table in [
        "_escriba_manifest",
        "_escriba_manual",
        "_escriba_source",
        "_escriba_principal",
    ] {
        state.push(info["tables"][table].clone().into_value());
    }
    Ok(state)
}
