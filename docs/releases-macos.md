# Releases de macOS

La release de macOS se construye en `macos-26` para Apple Silicon y añade un
ZIP a una release existente. El workflow manual recibe el tag de destino. En la
rama de preparación actual se lanza así:

```sh
gh workflow run release.yml --ref ci/macos-release-sin-notarizar -f tag=v0.2.0
```

Una vez integrado el workflow, se puede omitir `--ref`:

```sh
gh workflow run release.yml -f tag=v0.2.0
```

La variable del repositorio `MACOS_NOTARIZE` controla el modo. Se configura en
**Settings > Secrets and variables > Actions > Variables**. Si no está definida
o vale `false`, la app
lleva firma ad hoc y el artefacto se llama
`Escriba_X.Y.Z_macos_arm64_sin-notarizar.zip`. Si vale `true`, se usa firma
Developer ID, `notarytool` para enviar y consultar la notarización, y `stapler`
para grapar el ticket aprobado. El ZIP se llama
`Escriba_X.Y.Z_macos_arm64.zip`.

Para habilitar el modo notarizado, configurar una vez estos GitHub Actions
secrets en el repositorio, sin guardar sus valores en el código ni en la
documentación:

- `APPLE_CERTIFICATE`: certificado Developer ID en formato PKCS#12 codificado
  en base64 (`base64p12`).
- `APPLE_CERTIFICATE_PASSWORD`: contraseña del PKCS#12.
- `APPLE_SIGNING_IDENTITY`: identidad `Developer ID Application: ...`.
- `APPLE_ID`: Apple ID usado para la notarización.
- `APPLE_APP_SPECIFIC_PASSWORD`: contraseña específica de la app.
- `APPLE_TEAM_ID`: identificador del equipo de Apple.

Con los secretos configurados, activar la notarización solo requiere cambiar
`MACOS_NOTARIZE` a `true`; no hay que editar el workflow. También se puede hacer
con GitHub CLI:

```sh
gh variable set MACOS_NOTARIZE --body true
```

El modo es cerrado ante errores: si `MACOS_NOTARIZE=true` y falta cualquier
secreto, la firma, el envío, la aceptación o el grapado fallan, el job falla y
no publica un paquete ad hoc como alternativa. No se deben solicitar ni enviar
estas credenciales por chat.

Ambos modos publican `SHA256SUMS-macos-arm64` separado del ZIP. Al cambiar el
modo y repetir una release, primero se suben el ZIP validado y su checksum;
después se retira el ZIP del modo anterior, para que quede un solo paquete de
macOS con su checksum correspondiente. El modo ad hoc
es provisional y no está notarizado. La notarización real, incluida la ruta de
certificado y Apple, está pendiente; estas instrucciones describen el flujo
previsto y no afirman que se haya validado con credenciales reales.
