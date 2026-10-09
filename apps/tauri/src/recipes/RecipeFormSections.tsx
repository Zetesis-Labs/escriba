import { AlertTriangle } from "lucide-react";
import {
  recipeFormIssue,
  recipeFormIsVisible,
  recipeFormNumberChoices,
  recipeFormNumberText,
  recipeFormSections,
  setting,
  valueAt,
  type FormField,
  type RecipeForm,
} from "../core/recipeForm";
import { FormRow, FormSection, InlineField, LabeledRow, PopupButton, TextArea, Toggle } from "../mac/controls";
import type { JSONValue } from "../types";

const none = "__ninguno__";

export function RecipeFormSections({ form, values, onChange }: { form: RecipeForm; values: JSONValue; onChange: (values: JSONValue) => void }) {
  const sections = recipeFormSections(form);
  return (
    <>
      {sections.map((section, index) => (
        <FormSection key={`${section.path.join(".")}-${section.fields[0]?.name ?? index}`} header={section.title ?? (index === 0 ? "Parámetros" : undefined)}>
          {section.fields
            .filter((field) => recipeFormIsVisible(field, values, section.path))
            .map((field) => (
              <FieldRow key={field.name} field={field} path={[...section.path, field.name]} values={values} onChange={onChange} />
            ))}
        </FormSection>
      ))}
    </>
  );
}

function FieldRow({ field, path, values, onChange }: { field: FormField; path: string[]; values: JSONValue; onChange: (values: JSONValue) => void }) {
  const value = valueAt(values, path);
  const empty = field.nullable ? null : undefined;
  const set = (next: JSONValue | undefined) => onChange(setting(values, next, path));
  const issue = recipeFormIssue(field, value);
  const help = field.help && !(field.kind.type === "text") ? <div className="font-caption secondary field-help">{field.help}</div> : null;
  const warning = issue ? (
    <div className="font-caption warning field-help">
      <AlertTriangle size={11} strokeWidth={2} /> {issue}
    </div>
  ) : null;
  const choice = (options: { value: string; label: string }[], numeric: boolean) => {
    const current = numeric ? (typeof value === "number" ? recipeFormNumberText(value) : undefined) : typeof value === "string" ? value : undefined;
    const stale = current !== undefined && !options.some((option) => option.value === current) ? current : undefined;
    const list = [
      ...(field.nullable || current === undefined ? [{ value: none, label: "—" }] : []),
      ...options,
      ...(stale !== undefined ? [{ value: stale, label: `${stale} (ya no está)` }] : []),
    ];
    return (
      <PopupButton
        label={field.label}
        value={current ?? none}
        options={list}
        onChange={(picked) => set(picked === none ? empty : numeric ? Number(picked) : picked)}
      />
    );
  };

  let control: React.ReactNode;
  switch (field.kind.type) {
    case "toggle":
      control = (
        <LabeledRow label={field.label}>
          <Toggle label={field.label} checked={value === true} onChange={(checked) => set(checked)} />
        </LabeledRow>
      );
      break;
    case "text":
      control =
        field.kind.lines > 1 ? (
          <FormRow>
            <div className="field-stack">
              <span>{field.label}</span>
              <TextArea value={typeof value === "string" ? value : ""} lines={field.kind.lines} placeholder={field.help ?? undefined} onChange={(text) => set(text ? text : empty)} />
            </div>
          </FormRow>
        ) : (
          <LabeledRow label={field.label}>
            <InlineField value={typeof value === "string" ? value : ""} placeholder={field.help ?? "Vacío"} onChange={(text) => set(text ? text : empty)} />
          </LabeledRow>
        );
      break;
    case "number": {
      const choices = recipeFormNumberChoices(field);
      const integer = field.kind.integer;
      control = (
        <LabeledRow label={field.label}>
          {choices ? (
            choice(choices.map((number) => ({ value: String(number), label: String(number) })), true)
          ) : (
            <InlineField
              value={typeof value === "number" ? recipeFormNumberText(value) : ""}
              onChange={(text) => {
                const parsed = Number(text.replace(",", "."));
                set(text.trim() === "" || Number.isNaN(parsed) ? empty : integer ? Math.round(parsed) : parsed);
              }}
            />
          )}
        </LabeledRow>
      );
      break;
    }
    case "choice":
      control = <LabeledRow label={field.label}>{choice(field.kind.options, false)}</LabeledRow>;
      break;
    case "choices": {
      const picked = Array.isArray(value) ? value : [];
      control = (
        <FormRow>
          <div className="field-stack">
            <span>{field.label}</span>
            {field.kind.options.length === 0 && <span className="secondary">No hay ninguno</span>}
            {field.kind.options.map((option) => (
              <div className="choice-row" key={option.value}>
                <span>{option.label}</span>
                <Toggle
                  label={option.label}
                  checked={picked.includes(option.value)}
                  onChange={(on) => set([...picked.filter((item) => item !== option.value), ...(on ? [option.value] : [])])}
                />
              </div>
            ))}
          </div>
        </FormRow>
      );
      break;
    }
    case "group":
      control = null;
  }
  if (!control) return null;
  return (
    <>
      {control}
      {(help || warning) && (
        <FormRow>
          <div>
            {help}
            {warning}
          </div>
        </FormRow>
      )}
    </>
  );
}
