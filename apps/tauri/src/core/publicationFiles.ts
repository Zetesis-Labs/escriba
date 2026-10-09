export function okfPublicationFile(folder: string | undefined, receipt: Record<string, unknown>): string | null {
  if (!folder) return null;
  if (typeof receipt.url === "string" && receipt.url.startsWith("file:")) {
    try {
      const url = new URL(receipt.url);
      return url.hostname && url.hostname !== "localhost" ? null : decodeURIComponent(url.pathname);
    } catch {
      return null;
    }
  }
  if (typeof receipt.locator !== "string" || !receipt.locator) return null;
  if (receipt.locator.startsWith("/")) return receipt.locator;
  const root = typeof receipt.folder === "string" && receipt.folder.startsWith("/") ? receipt.folder : folder;
  return `${root}/${receipt.locator}`.replace(/\/+/g, "/");
}
