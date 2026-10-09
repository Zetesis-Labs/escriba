import type { NativeStatus, Resolver } from "../types";
import type { RuntimeContext } from "../runtime/contracts";
import { localProblem, resolverProblem, type Role } from "./resolvers";

export interface NotificationProblem {
  role: Role;
  name: string;
  reason: string;
}

export function notificationProblems(context: RuntimeContext, nativeStatus: NativeStatus): NotificationProblem[] {
  const recipe = context.recipes.find((candidate) => candidate.id === context.settings.defaultRecipeId);
  const values = recipe?.kind === "form" && !recipe.base ? recipe.values : {};
  const chosen = (role: Role, key: unknown): Resolver | undefined => {
    const resolvers = context.resolvers.filter((candidate) => candidate.role === role && candidate.enabled);
    const local = resolvers.find((candidate) => candidate.local);
    return (typeof key === "string" ? resolvers.find((candidate) => candidate.id === key) : undefined) ?? local;
  };
  const problems: NotificationProblem[] = [];
  for (const role of ["stt", "llm"] as const) {
    if (role === "llm" && values.resumir !== undefined && values.resumir !== true) continue;
    const resolver = chosen(role, values[role]);
    if (!resolver) continue;
    const reason = resolverProblem(resolver, localProblem(role, nativeStatus));
    if (reason) problems.push({ role, name: resolver.name, reason });
  }
  return problems;
}
