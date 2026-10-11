import { builtinProviders, type Provider, type ProviderAccess, type ProviderManifest } from "@escriba/conectores";
import type { Account } from "../types";
import { z } from "zod";

const manifestSchema = z.object({
  id: z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/),
  name: z.string().min(1),
  description: z.string().optional(),
  capability: z.enum(["http", "folder"]),
  origin: z.string().url().optional(),
  allowedHeaders: z.array(z.string().regex(/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/)),
  credential: z.object({ label: z.string().min(1), header: z.string().regex(/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/), prefix: z.string().regex(/^[^\r\n]*$/).optional(), help: z.string().optional() }).optional(),
  defaultConfiguration: z.record(z.string(), z.json()),
  configurationSchema: z.record(z.string(), z.json()).optional(),
  autoPublishLabel: z.string().optional(),
  removalMessage: z.string().optional(),
  connectAction: z.string().optional(),
});
export function providerManifest(value: unknown): ProviderManifest {
  const provider = manifestSchema.parse(value);
  if (provider.capability === "http" && !provider.origin) throw Error("El proveedor HTTP necesita un origen");
  if (provider.origin) {
    const url = new URL(provider.origin);
    if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || url.pathname !== "/" || url.search || url.hash) throw Error("El origen del proveedor no es válido");
  }
  return provider;
}
export function providerAccess(provider: ProviderAccess): ProviderAccess {
  return {
    capability: provider.capability,
    ...(provider.origin ? { origin: provider.origin } : {}),
    allowedHeaders: provider.allowedHeaders,
    ...(provider.credential ? { credential: provider.credential } : {}),
  };
}
export function authorityKey(grant: ProviderAccess): string {
  return JSON.stringify({
    capability: grant.capability,
    origin: grant.origin ? new URL(grant.origin).origin : null,
    headers: [...new Set(grant.allowedHeaders.map((header) => header.toLowerCase()))].sort(),
    credential: grant.credential ? { header: grant.credential.header.toLowerCase(), prefix: grant.credential.prefix ?? "" } : null,
  });
}
export function accountAuthority(account: Account, providers: Provider[] = [], retained = false): ProviderAccess {
  if (!account.enabled) throw Error("La cuenta está desactivada o revocada");
  const provider = builtinProviders.find((entry) => entry.id === account.provider)
    ?? providers.find((entry) => entry.id === account.provider);
  if (!provider || ("unavailable" in provider && provider.unavailable && !retained)) throw Error("El proveedor de la cuenta no está disponible");
  const grant = account.grant ?? (builtinProviders.some((entry) => entry.id === account.provider) ? providerAccess(provider) : undefined);
  if (!grant || authorityKey(grant) !== authorityKey(providerAccess(provider))) throw Error("Los permisos del proveedor han cambiado; vuelve a autorizar la cuenta");
  return grant;
}
