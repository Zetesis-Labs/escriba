const triples = {
  "win32-x64": "x86_64-pc-windows-msvc",
  "darwin-arm64": "aarch64-apple-darwin",
  "darwin-x64": "x86_64-apple-darwin",
  "linux-arm64": "aarch64-unknown-linux-gnu",
  "linux-x64": "x86_64-unknown-linux-gnu",
};
const bunTargets = {
  "x86_64-pc-windows-msvc": "bun-windows-x64",
  "aarch64-apple-darwin": "bun-darwin-arm64",
  "x86_64-apple-darwin": "bun-darwin-x64",
  "aarch64-unknown-linux-gnu": "bun-linux-arm64",
  "x86_64-unknown-linux-gnu": "bun-linux-x64",
};

export function hostTriple(platform, arch) {
  const triple = triples[`${platform}-${arch}`];
  if (!triple) throw Error(`Plataforma no soportada: ${platform}-${arch}`);
  return triple;
}

export function typescriptPackage(platform, arch) {
  hostTriple(platform, arch);
  return `@typescript/typescript-${platform}-${arch}`;
}

export function bunTarget(triple) {
  const target = bunTargets[triple];
  if (!target) throw Error(`Plataforma Bun no soportada: ${triple}`);
  return target;
}

// The SurrealDB binding the controller loads; Linux packages target glibc.
export function surrealNative(platform, arch) {
  hostTriple(platform, arch);
  const name = platform === "linux" ? `linux-${arch}-gnu` : platform === "win32" ? `win32-${arch}-msvc` : `${platform}-${arch}`;
  return { package: `@surrealdb/node-native-${name}`, file: `surrealdb-node.${name}.node` };
}
