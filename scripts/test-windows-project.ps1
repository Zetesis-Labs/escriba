[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repo = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $repo 'apps/tauri/src-tauri/binaries/escriba-runtime-x86_64-pc-windows-msvc.exe'
$sandbox = Join-Path $repo 'apps/tauri/src-tauri/binaries/escriba-sandbox-x86_64-pc-windows-msvc.exe'
$vendor = Join-Path $repo 'apps/tauri/src-tauri/vendor'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('escriba-project-check-' + [guid]::NewGuid().ToString('N'))
$project = Join-Path $temporary 'Proyecto ñ 100%'
$recipe = Join-Path $project 'src/prueba/receta.ts'
$previousBunMode = $env:BUN_BE_BUN
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $recipe) | Out-Null
    [IO.File]::WriteAllText($recipe, 'import { z } from "zod"; export const valor = z.string().parse("prueba");')
    $env:BUN_BE_BUN = $null
    & $sandbox tool --project $project --vendor $vendor --executable $runtime -- --project-build "\\?\$project" "\\?\$vendor"
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo construir el proyecto aislado con rutas canónicas de Windows' }
    $manifest = Get-Content -LiteralPath (Join-Path $project 'dist/escriba.json') -Raw | ConvertFrom-Json
    if ($manifest.recipes.Count -ne 1 -or $manifest.recipes[0].id -ne 'code:prueba') { throw 'El proyecto no generó su receta' }
    $artifact = Join-Path $project 'dist/receta-0.js'
    $before = (Get-FileHash -LiteralPath $artifact).Hash
    [IO.File]::WriteAllText($recipe, 'import "./ausente.ts";')
    $failedBuild = & $sandbox tool --project $project --vendor $vendor --executable $runtime -- --project-build "\\?\$project" "\\?\$vendor" 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'La construcción aceptó una fuente inválida' }
    if ("$failedBuild" -notmatch 'ausente.ts') { throw "La construcción falló por otro motivo: $failedBuild" }
    if ((Get-FileHash -LiteralPath $artifact).Hash -ne $before) { throw 'La construcción fallida sustituyó el último artefacto válido' }
    Write-Output 'Proyecto Windows: construcción aislada y conservación de dist correctas.'
} finally {
    $env:BUN_BE_BUN = $previousBunMode
    if (Test-Path -LiteralPath $temporary) {
        $resolved = (Resolve-Path -LiteralPath $temporary).ProviderPath
        if ([IO.Path]::GetFullPath($resolved) -ne [IO.Path]::GetFullPath($temporary) -or ![IO.Path]::GetFileName($resolved).StartsWith('escriba-project-check-')) { throw 'Directorio temporal inesperado' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
exit 0
