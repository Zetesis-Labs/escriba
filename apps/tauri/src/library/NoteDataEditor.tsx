import { useEffect, useRef, useState } from "react";
import type { JSONValue } from "../types";
import "./noteDataEditor.css";

type JSONRecord = Record<string, JSONValue>;

export interface NoteDataEditorProps {
  value: JSONValue;
  schema?: JSONValue;
  onChange: (value: JSONValue) => void;
  disabled?: boolean;
}

function object(value: JSONValue | undefined): value is JSONRecord {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function resolvedSchema(schema: JSONValue | undefined): JSONRecord | undefined {
  if (!object(schema)) return undefined;
  if (Array.isArray(schema.anyOf)) {
    const typed = schema.anyOf.find((option) => object(option) && option.type !== "null");
    return object(typed) ? typed : schema;
  }
  return schema;
}

function schemaType(schema: JSONValue | undefined): string | undefined {
  const type = resolvedSchema(schema)?.type;
  if (typeof type === "string") return type;
  if (Array.isArray(type)) return type.find((item): item is string => typeof item === "string" && item !== "null");
  return undefined;
}

function emptyFromSchema(schema: JSONValue | undefined): JSONValue | undefined {
  const node = resolvedSchema(schema);
  if (node && "default" in node) return node.default;
  if (Array.isArray(node?.enum)) return node.enum.find((item) => item !== null) ?? node.enum[0];
  switch (schemaType(schema)) {
    case "string": return "";
    case "number":
    case "integer": return 0;
    case "boolean": return false;
    case "array": return [];
    case "object": {
      const properties = node?.properties;
      return object(properties) ? Object.fromEntries(Object.entries(properties).flatMap(([name, child]) => {
        const initial = emptyFromSchema(child);
        return initial === undefined ? [] : [[name, initial]];
      })) : {};
    }
    default: return undefined;
  }
}

function emptyLike(value: JSONValue): JSONValue {
  if (Array.isArray(value)) return [];
  if (object(value)) return Object.fromEntries(Object.entries(value).map(([name, child]) => [name, emptyLike(child)]));
  if (typeof value === "string") return "";
  if (typeof value === "number") return 0;
  if (typeof value === "boolean") return false;
  return null;
}

function NumberEditor({ value, onChange, disabled, label, integer }: { value: number; onChange: (value: number) => void; disabled: boolean; label: string; integer: boolean }) {
  const [draft, setDraft] = useState(String(value));
  const input = useRef<HTMLInputElement>(null);
  const editing = useRef(false);
  useEffect(() => { if (!editing.current) setDraft(String(value)); }, [value]);
  const validNumber = (text: string) => text.trim() !== "" && Number.isFinite(Number(text)) && (!integer || /^-?\d+$/.test(text));
  const invalid = !validNumber(draft);
  const error = integer ? "Introduce un número entero." : "Introduce un número válido.";
  useEffect(() => { input.current?.setCustomValidity(invalid ? error : ""); }, [invalid, error]);
  return (
    <span className="note-editor-number-wrap">
      <input
        ref={input}
        className="note-editor-input selectable"
        type="text"
        inputMode={integer ? "numeric" : "decimal"}
        pattern={integer ? "-?\\d+" : undefined}
        value={draft}
        disabled={disabled}
        aria-label={label}
        aria-invalid={invalid}
        onFocus={() => { editing.current = true; }}
        onBlur={() => { editing.current = false; if (!invalid) setDraft(String(Number(draft))); }}
        onChange={(event) => {
          const next = event.target.value;
          setDraft(next);
          event.target.setCustomValidity(validNumber(next) ? "" : error);
          if (validNumber(next)) onChange(Number(next));
        }}
      />
      {invalid && <span className="note-editor-error">{error}</span>}
    </span>
  );
}

function ValueEditor({ value, schema, label, onChange, disabled }: NoteDataEditorProps & { label: string; disabled: boolean }) {
  const node = resolvedSchema(schema);
  const enumerated = Array.isArray(node?.enum) ? node.enum : undefined;
  const [newItemType, setNewItemType] = useState("string");

  if (enumerated && !Array.isArray(value) && !object(value)) return <select className="note-editor-input" aria-label={label} value={enumerated.findIndex((option) => option === value)} disabled={disabled}
    onChange={(event) => onChange(enumerated[Number(event.target.value)])}>
    {enumerated.map((option, index) => <option value={index} key={index}>{option === null ? "Sin valor" : String(option)}</option>)}
  </select>;

  if (value === null) {
    const initial = emptyFromSchema(schema);
    return initial === undefined ? (
      <span className="note-editor-null">
        <span>Sin valor</span>
        <select aria-label={`Tipo de ${label}`} value={newItemType} onChange={(event) => setNewItemType(event.target.value)} disabled={disabled}>
          <option value="string">Texto</option><option value="number">Número</option><option value="boolean">Sí/No</option>
          <option value="array">Lista</option><option value="object">Grupo</option>
        </select>
        <button type="button" className="note-editor-action" disabled={disabled} onClick={() => onChange(emptyFromSchema({ type: newItemType }) ?? "")}>Añadir</button>
      </span>
    ) : <button type="button" className="note-editor-action" disabled={disabled} onClick={() => onChange(initial)}>Añadir {label.toLowerCase()}</button>;
  }

  if (Array.isArray(value)) {
    const itemSchema = node?.items;
    const sample = value[0];
    const newItem = emptyFromSchema(itemSchema) ?? (sample === undefined ? emptyFromSchema({ type: newItemType }) : emptyLike(sample));
    return <div className="note-editor-list">
      {value.map((item, index) => <div className="note-editor-list-item" key={index}>
        <span className="note-editor-index">{index + 1}</span>
        <ValueEditor value={item} schema={itemSchema} label={`${label} ${index + 1}`} disabled={disabled}
          onChange={(next) => onChange(value.map((current, position) => position === index ? next : current))} />
        <button type="button" className="note-editor-remove" aria-label={`Quitar ${label} ${index + 1}`} disabled={disabled}
          onClick={() => onChange(value.filter((_, position) => position !== index))}>Quitar</button>
      </div>)}
      <div className="note-editor-list-add">
        {itemSchema === undefined && sample === undefined && <select aria-label={`Tipo de nuevo elemento en ${label}`} value={newItemType} disabled={disabled} onChange={(event) => setNewItemType(event.target.value)}>
          <option value="string">Texto</option><option value="number">Número</option><option value="boolean">Sí/No</option>
          <option value="array">Lista</option><option value="object">Grupo</option>
        </select>}
        <button type="button" className="note-editor-action" disabled={disabled || newItem === undefined} onClick={() => onChange([...value, newItem ?? null])}>Añadir elemento</button>
      </div>
    </div>;
  }

  if (object(value)) {
    const properties = object(node?.properties) ? node.properties : {};
    const names = [...new Set([...Object.keys(value), ...Object.keys(properties)])];
    return <div className="note-editor-group">
      {names.map((name) => {
        const childSchema = properties[name];
        const title = resolvedSchema(childSchema)?.title;
        const childLabel = typeof title === "string" ? title : name;
        const exists = Object.hasOwn(value, name);
        const initial = emptyFromSchema(childSchema);
        return <div className="note-editor-row" key={name}>
          <label className="note-editor-label">{childLabel}</label>
          {exists ? <ValueEditor value={value[name]} schema={childSchema} label={childLabel} disabled={disabled}
            onChange={(next) => onChange(Object.fromEntries(Object.entries(value).map(([key, current]) => [key, key === name ? next : current])))} />
            : <button type="button" className="note-editor-action" disabled={disabled || initial === undefined}
              onClick={() => onChange(Object.fromEntries([...Object.entries(value), [name, initial ?? null]]))}>Añadir {childLabel.toLowerCase()}</button>}
        </div>;
      })}
      {names.length === 0 && <span className="note-editor-muted">Sin campos</span>}
    </div>;
  }

  if (typeof value === "boolean") return <label className="note-editor-checkbox"><input type="checkbox" checked={value} disabled={disabled} onChange={(event) => onChange(event.target.checked)} />{value ? "Sí" : "No"}</label>;
  if (typeof value === "number") return <NumberEditor value={value} onChange={onChange} disabled={disabled} label={label} integer={schemaType(schema) === "integer"} />;
  return <textarea className="note-editor-input note-editor-text selectable" value={value} rows={Math.min(5, Math.max(2, value.split("\n").length))}
    aria-label={label} disabled={disabled} onChange={(event) => onChange(event.target.value)} />;
}

export function NoteDataEditor({ value, schema, onChange, disabled = false }: NoteDataEditorProps) {
  if (value === null && schema === undefined) return <p className="note-editor-muted">La receta no guardó datos.</p>;
  return <div className="note-data-editor"><ValueEditor value={value} schema={schema} label="Datos" onChange={onChange} disabled={disabled} /></div>;
}
