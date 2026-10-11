use super::*;
use surrealdb_expr::expr::{
    visit::{Visit, Visitor},
    Expr, LogicalPlan, TopLevelExpr,
};

pub(super) fn validate(sql: &str) -> Result<(), String> {
    let ast = surrealdb_core::syn::parse(sql).map_err(error)?;
    let plan: LogicalPlan = ast.into();
    let mut guard = ReadOnlyGuard;
    for expression in plan.expressions {
        guard.visit_top_level_expr(&expression)?;
    }
    Ok(())
}

struct ReadOnlyGuard;

impl Visitor for ReadOnlyGuard {
    type Error = String;

    fn visit_top_level_expr(&mut self, value: &TopLevelExpr) -> Result<(), String> {
        match value {
            TopLevelExpr::Expr(
                Expr::Select(_)
                | Expr::Return(_)
                | Expr::Let(_)
                | Expr::IfElse(_)
                | Expr::Foreach(_)
                | Expr::Block(_),
            ) => value.visit(self),
            _ => Err("La base de Escriba solo admite consultas de lectura".into()),
        }
    }

    fn visit_expr(&mut self, value: &Expr) -> Result<(), String> {
        if !value.read_only()
            || matches!(
                value,
                Expr::Info(_)
                    | Expr::Sleep(_)
                    | Expr::Throw(_)
                    | Expr::Explain { .. }
                    | Expr::Match(_)
                    | Expr::Mock(_)
            )
        {
            return Err("La base de Escriba solo admite consultas de lectura".into());
        }
        value.visit(self)
    }
}

#[cfg(test)]
mod tests {
    use super::validate;

    #[test]
    fn admite_lecturas_y_expresiones_puras() {
        for sql in [
            "SELECT id, text FROM segment WHERE recordingId = $recording",
            "SELECT VALUE ->has_version->version FROM recording",
            "RETURN type::record('recording', $key)",
            "LET $version = (SELECT VALUE currentVersion FROM recording LIMIT 1); RETURN $version",
            "IF true { RETURN (SELECT VALUE id FROM recording); }",
            "FOR $id IN [1, 2] { LET $value = $id; RETURN $value; };",
        ] {
            assert!(validate(sql).is_ok(), "{sql}");
        }
    }

    #[test]
    fn rechaza_escrituras_y_control_de_sesion_incluso_anidados() {
        for sql in [
            "UPDATE segment SET text = 'cambiado'",
            "CREATE segment CONTENT { text: 'nuevo' }",
            "UPSERT segment:uno SET text = 'nuevo'",
            "DELETE segment:uno",
            "INSERT INTO segment { text: 'nuevo' }",
            "RELATE recording:uno->has_version->version:dos",
            "DEFINE TABLE extra",
            "REMOVE TABLE segment",
            "ALTER TABLE segment COMMENT 'cambio'",
            "BEGIN; SELECT * FROM segment; COMMIT;",
            "USE NS knowledge DB registry",
            "INFO FOR DB",
            "RETURN (UPDATE segment SET text = 'oculto')",
            "RETURN fn::mutar()",
            "LET $x = (DELETE segment:uno); RETURN $x",
            "IF true { UPDATE segment SET text = 'oculto'; };",
            "FOR $id IN [1, 2] { DELETE segment:uno; };",
        ] {
            assert!(validate(sql).is_err(), "{sql}");
        }
    }
}
