[CmdletBinding()]
param([switch]$Inference)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$env:PATH = "$(Join-Path $env:USERPROFILE '.cargo/bin');$env:PATH"
$env:CMAKE_POLICY_VERSION_MINIMUM = '3.5'
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!$env:CMAKE_GENERATOR -and (Test-Path -LiteralPath $vswhere)) {
    $vs2022 = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs2022) {
        $env:CMAKE_GENERATOR = 'Visual Studio 17 2022'
        $env:CMAKE_GENERATOR_INSTANCE = $vs2022
    }
}
Push-Location $project
try {
    foreach ($crate in @('native-host', 'sandbox', 'src-tauri')) {
        $manifest = "apps/tauri/$crate/Cargo.toml"
        $cargoOptions = if ($crate -eq 'src-tauri') { @('--config', (Join-Path $project 'scripts/windows-cargo.toml')) } else { @() }
        & cargo fmt --manifest-path $manifest --check
        if ($LASTEXITCODE -ne 0) { throw "Formato incorrecto en $crate" }
        & cargo @cargoOptions clippy --release --locked --manifest-path $manifest --all-targets -- -D warnings
        if ($LASTEXITCODE -ne 0) { throw "Clippy falló en $crate" }
        $arguments = @('test', '--release', '--locked', '--manifest-path', $manifest)
        if ($crate -eq 'src-tauri') { $arguments += '--lib' }
        & cargo @cargoOptions @arguments
        if ($LASTEXITCODE -ne 0) { throw "Tests fallidos en $crate" }
    }
    & npm.cmd test --prefix apps/tauri
    if ($LASTEXITCODE -ne 0) { throw 'Falló la suite TypeScript' }
    & npm.cmd run typecheck:runtime --prefix apps/tauri
    if ($LASTEXITCODE -ne 0) { throw 'Fallaron los tipos del runtime' }
    if ($Inference) {
        & cargo test --release --manifest-path apps/tauri/native-host/Cargo.toml --test linux sintetica -- --ignored --test-threads=1
        if ($LASTEXITCODE -ne 0) { throw 'Falló la inferencia real' }
    }
} finally { Pop-Location }
