import type { JSONObject, JSONValue } from "../types";
import { recipeFormOverrides, recipeFormValues, type RecipeFormLoad } from "./recipeForm";

export interface ReprocessDraft {
  recipeId: string;
  load: RecipeFormLoad | null;
  values: JSONValue;
}

type ReprocessAction =
  | { type: "select"; recipeId: string }
  | { type: "loaded"; recipeId: string; load: RecipeFormLoad; saved: JSONObject }
  | { type: "change"; values: JSONValue };

export function reprocessDraft(recipeId: string): ReprocessDraft {
  return { recipeId, load: null, values: {} };
}

export function reprocessTransition(draft: ReprocessDraft, action: ReprocessAction): ReprocessDraft {
  if (action.type === "select") return reprocessDraft(action.recipeId);
  if (action.type === "change") return { ...draft, values: action.values };
  if (action.recipeId !== draft.recipeId) return draft;
  return {
    ...draft,
    load: action.load,
    values: action.load.kind === "form" ? recipeFormValues(action.load.form, action.saved) : {},
  };
}

export function reprocessChoice(draft: ReprocessDraft): { recipeId: string; values?: JSONObject } {
  return draft.load?.kind === "form"
    ? { recipeId: draft.recipeId, values: recipeFormOverrides(draft.load.form, draft.values) ?? {} }
    : { recipeId: draft.recipeId };
}

