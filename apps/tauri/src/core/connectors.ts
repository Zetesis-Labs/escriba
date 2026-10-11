import { builtinProviders } from "@escriba/conectores";
import type { Destination } from "../types";

export const isAppConnector = (destination: Destination) => destination.id === destination.account && (destination.managed === true || (!destination.program && !destination.programFingerprint && builtinProviders.some((provider) => provider.id === destination.provider)));

export function nextConnectorName(providerName: string, names: string[]): string {
  if (!names.includes(providerName)) return providerName;
  for (let number = 2; ; number++) {
    const name = `${providerName} ${number}`;
    if (!names.includes(name)) return name;
  }
}
