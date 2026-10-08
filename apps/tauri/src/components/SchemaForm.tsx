import type { JSONObject, JSONValue } from "../types";

type Field = {
  type?: string | string[];
  title?: string;
  description?: string;
  default?: JSONValue;
  enum?: JSONValue[];
  const?: JSONValue;
  anyOf?: Field[];
  oneOf?: Field[];
  properties?: Record<string, Field>;
  items?: Field;
  minimum?: number;
  maximum?: number;
};

interface Props {
  schema: JSONObject | undefined;
  values: JSONObject;
  onChange: (value: JSONObject) => void;
  disabled?: boolean;
}

function labelFor(key: string, field: Field) {
  return (
    field.title ||
    key
      .replace(/([A-Z])/g, " $1")
      .replace(/^./, (letter) => letter.toUpperCase())
  );
}

function fieldValue(value: JSONValue | undefined, field: Field): JSONValue {
  return value === undefined ? (field.default ?? null) : value;
}

function choices(field: Field): JSONValue[] | undefined {
  if (field.enum) return field.enum;
  const variants = field.anyOf || field.oneOf;
  if (!variants?.length) return undefined;
  const options = variants.flatMap((item) =>
    item.const !== undefined ? [item.const] : item.enum || [],
  );
  return options.length ? options : undefined;
}

function Fields({
  schema,
  values,
  onChange,
  disabled,
  prefix = "",
}: Props & { prefix?: string }) {
  const properties = (schema?.properties || {}) as Record<string, Field>;
  if (!Object.keys(properties).length)
    return (
      <p className="muted compact">
        Esta receta no declara parámetros editables.
      </p>
    );
  return (
    <div className="schema-fields">
      {Object.entries(properties).map(([key, field]) => {
        const id = `schema-${prefix}${key}`;
        const value = fieldValue(values[key], field);
        const update = (next: JSONValue) =>
          onChange({ ...values, [key]: next });
        const type = Array.isArray(field.type)
          ? field.type.find((item) => item !== "null")
          : field.type;
        const options = choices(field);
        return (
          <div className="field" key={key}>
            {type === "object" && field.properties ? (
              <>
                <div className="field-label">{labelFor(key, field)}</div>
                <div className="nested-fields">
                  <Fields
                    schema={field as unknown as JSONObject}
                    values={
                      value &&
                      typeof value === "object" &&
                      !Array.isArray(value)
                        ? (value as JSONObject)
                        : {}
                    }
                    onChange={update}
                    disabled={disabled}
                    prefix={`${prefix}${key}-`}
                  />
                </div>
              </>
            ) : type === "boolean" ? (
              <label className="toggle-row" htmlFor={id}>
                <span>
                  <strong>{labelFor(key, field)}</strong>
                  {field.description && <small>{field.description}</small>}
                </span>
                <input
                  id={id}
                  type="checkbox"
                  checked={Boolean(value)}
                  onChange={(event) => update(event.target.checked)}
                  disabled={disabled}
                />
              </label>
            ) : (
              <>
                <label htmlFor={id}>{labelFor(key, field)}</label>
                {type === "array" && field.items && choices(field.items) ? (
                  <div className="choice-list">
                    {choices(field.items)?.map((choice) => (
                      <label key={String(choice)}>
                        <input
                          type="checkbox"
                          disabled={disabled}
                          checked={
                            Array.isArray(value) && value.includes(choice)
                          }
                          onChange={(event) =>
                            update(
                              event.target.checked
                                ? [
                                    ...(Array.isArray(value) ? value : []),
                                    choice,
                                  ]
                                : (Array.isArray(value) ? value : []).filter(
                                    (item) => item !== choice,
                                  ),
                            )
                          }
                        />
                        {String(choice)}
                      </label>
                    ))}
                  </div>
                ) : options ? (
                  <select
                    id={id}
                    value={String(value ?? "")}
                    onChange={(event) =>
                      update(
                        event.target.value === ""
                          ? null
                          : (options.find(
                              (item) => String(item) === event.target.value,
                            ) ?? event.target.value),
                      )
                    }
                    disabled={disabled}
                  >
                    {(field.anyOf || field.oneOf)?.some(
                      (item) => item.type === "null",
                    ) && <option value="">Sin elegir</option>}
                    {options.map((choice) => (
                      <option key={String(choice)} value={String(choice)}>
                        {String(choice)}
                      </option>
                    ))}
                  </select>
                ) : type === "number" || type === "integer" ? (
                  <input
                    id={id}
                    type="number"
                    min={field.minimum}
                    max={field.maximum}
                    step={type === "integer" ? 1 : "any"}
                    value={typeof value === "number" ? value : ""}
                    onChange={(event) =>
                      update(
                        event.target.value === ""
                          ? null
                          : Number(event.target.value),
                      )
                    }
                    disabled={disabled}
                  />
                ) : type === "array" ? (
                  <textarea
                    id={id}
                    rows={3}
                    value={Array.isArray(value) ? value.join("\n") : ""}
                    onChange={(event) =>
                      update(
                        event.target.value
                          .split("\n")
                          .map((item) => item.trim())
                          .filter(Boolean),
                      )
                    }
                    disabled={disabled}
                    placeholder="Un valor por línea"
                  />
                ) : (
                  <input
                    id={id}
                    value={typeof value === "string" ? value : ""}
                    onChange={(event) => update(event.target.value)}
                    disabled={disabled}
                  />
                )}
                {field.description && <small>{field.description}</small>}
              </>
            )}
          </div>
        );
      })}
    </div>
  );
}

export function SchemaForm(props: Props) {
  return <Fields {...props} />;
}
