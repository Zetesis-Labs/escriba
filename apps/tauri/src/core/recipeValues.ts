import type { JSONObject, Recipe } from "../types";

export function recipeWithValues(recipe: Recipe, values?: JSONObject): Recipe {
  return values === undefined ? recipe : { ...recipe, values };
}
