import type { Destination, JSONObject, Publication } from "../types";

export function publicationConfiguration(operation: string, destination: Destination | undefined, publication: Publication | undefined): JSONObject {
  if (destination && (!publication || (operation === "publish" && !destination.program))) return destination.configuration;
  return publication?.configuration ?? {};
}
