import type { ProcessOptions, Recording, Settings } from "../types";

export function processingRecipeId(
  options: Pick<ProcessOptions, "recipeId">,
  recording: Pick<Recording, "recipeId">,
  settings: Pick<Settings, "defaultRecipeId">,
): string {
  return options.recipeId || recording.recipeId || settings.defaultRecipeId;
}
