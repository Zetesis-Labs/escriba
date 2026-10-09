import { dataRows } from "../core/noteData";
import type { JSONValue } from "../types";

export function NoteDataView({ data, schema, small }: { data: JSONValue | undefined; schema?: JSONValue; small?: boolean }) {
  const rows = dataRows(data, schema);
  return (
    <div className={`note-data ${small ? "font-caption" : ""}`}>
      {rows.map((row, index) => (
        <div className="note-data-row" key={`${row.label}-${index}`}>
          <span
            className={row.value.kind === "group" ? "note-data-group" : "secondary"}
            style={{ paddingLeft: row.depth * 14 }}
          >
            {row.label}
          </span>
          {row.value.kind === "text" && <span className="selectable">{row.value.text}</span>}
          {row.value.kind === "list" && (
            <span className="selectable">
              {row.value.items.map((item, itemIndex) => (
                <div key={itemIndex}>• {item}</div>
              ))}
            </span>
          )}
          {row.value.kind === "group" && <span />}
        </div>
      ))}
    </div>
  );
}

export function NoteDataSection({ data, schema }: { data: JSONValue | undefined; schema?: JSONValue }) {
  if (!dataRows(data, schema).length) return null;
  return (
    <section className="detail-section">
      <h2 className="font-headline">Datos</h2>
      <NoteDataView data={data} schema={schema} />
    </section>
  );
}
