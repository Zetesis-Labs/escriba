[CmdletBinding()]
param(
    [switch]$DebugBuild,
    [switch]$NoBundle,
    [switch]$SkipDependencies,
    [switch]$PrepareOnly,
    [switch]$Cuda
)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$app = Join-Path $project 'apps/tauri'
$rustBin = Join-Path $env:USERPROFILE '.cargo/bin'
if (Test-Path -LiteralPath $rustBin) { $env:PATH = "$rustBin;$env:PATH" }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (!(Get-Command cmake -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $vswhere)) {
    $visualStudio = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $cmakeBin = Join-Path $visualStudio 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin'
    if (Test-Path -LiteralPath $cmakeBin) { $env:PATH = "$cmakeBin;$env:PATH" }
}
foreach ($tool in @('cargo', 'rustc', 'node', 'npm.cmd', 'bun', 'cmake', 'nasm')) {
    if (!(Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Falta $tool. Consulta docs/windows.md para preparar el equipo de desarrollo." }
}
if (!$env:LIBCLANG_PATH) {
    $llvmBin = Join-Path $env:ProgramFiles 'LLVM/bin'
    if (Test-Path -LiteralPath (Join-Path $llvmBin 'libclang.dll')) { $env:LIBCLANG_PATH = $llvmBin }
}
if (!$env:LIBCLANG_PATH -or !(Test-Path -LiteralPath (Join-Path $env:LIBCLANG_PATH 'libclang.dll'))) {
    throw 'Falta libclang.dll. Instala LLVM o indica su carpeta con LIBCLANG_PATH.'
}
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); process.exit(major >= 24 ? 0 : 1)'
if ($LASTEXITCODE -ne 0) { throw 'La construcción de Windows necesita Node 24 o posterior.' }
$requiredBun = (Get-Content -LiteralPath (Join-Path $app 'runtime-host/bun-version') -Raw).Trim()
if ((& bun --version).Trim() -ne $requiredBun) { throw "Escriba necesita Bun $requiredBun." }
$triple = (& rustc -vV | Select-String '^host: ').ToString().Substring(6)
if ($triple -ne 'x86_64-pc-windows-msvc') { throw 'Esta distribución de Escriba admite Windows x64 con MSVC.' }
$env:CMAKE_POLICY_VERSION_MINIMUM = '3.5'
$env:CMAKE_PROJECT_INCLUDE = Join-Path $project 'scripts/native-cpu.cmake'
if (!$env:CMAKE_GENERATOR -and (Test-Path -LiteralPath $vswhere)) {
    $vs2022 = & $vswhere -latest -version '[17.0,18.0)' -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($vs2022) {
        $env:CMAKE_GENERATOR = 'Visual Studio 17 2022'
        $env:CMAKE_GENERATOR_INSTANCE = $vs2022
    }
}
$configuration = if ($DebugBuild) { 'debug' } else { 'release' }
$cargoArgs = if ($DebugBuild) { @() } else { @('--release') }
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program terminó con código $LASTEXITCODE." }
}
Push-Location $project
try {
    if (!$SkipDependencies) {
        Invoke-Checked npm.cmd @('ci', '--ignore-scripts', '--prefix', 'packages/conectores')
        Invoke-Checked npm.cmd @('ci', '--ignore-scripts', '--prefix', 'apps/tauri')
        Invoke-Checked npm.cmd @('ci', '--ignore-scripts', '--prefix', 'apps/tauri/runtime-host/toolchain')
    }
    Invoke-Checked npm.cmd @('run', 'build', '--prefix', 'packages/conectores')
    $sherpaCache = Join-Path $app 'native-host/target/sherpa-onnx-prebuilt'
    $sherpaImport = Get-ChildItem -LiteralPath $sherpaCache -Filter 'sherpa-onnx-c-api.lib' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    $sherpaRuntime = Join-Path $app "native-host/target/$configuration"
    if (!$sherpaImport -or !(Test-Path -LiteralPath (Join-Path $sherpaRuntime 'sherpa-onnx-c-api.dll')) -or !(Test-Path -LiteralPath (Join-Path $sherpaRuntime 'onnxruntime.dll'))) {
        Write-Output 'Restaurar las bibliotecas nativas de sherpa-onnx.'
        Invoke-Checked cargo (@('clean', '--manifest-path', 'apps/tauri/native-host/Cargo.toml', '-p', 'sherpa-onnx-sys') + $cargoArgs)
    }
    $features = if ($Cuda) { @('--features', 'cuda') } else { @() }
    Invoke-Checked cargo (@('build', '--locked', '--manifest-path', 'apps/tauri/native-host/Cargo.toml') + $cargoArgs + $features)
    Invoke-Checked cargo (@('build', '--locked', '--manifest-path', 'apps/tauri/sandbox/Cargo.toml', '--bin', 'escriba-sandbox') + $cargoArgs)
    $binaries = Join-Path $app 'src-tauri/binaries'
    $native = Join-Path $app 'src-tauri/native'
    $appTarget = Join-Path $app "src-tauri/target/$configuration"
    New-Item -ItemType Directory -Force $binaries, $native, $appTarget | Out-Null
    Copy-Item -LiteralPath (Join-Path $app "native-host/target/$configuration/EscribaNativeHost.exe") -Destination (Join-Path $binaries "EscribaNativeHost-$triple.exe") -Force
    Copy-Item -LiteralPath (Join-Path $app "sandbox/target/$configuration/escriba-sandbox.exe") -Destination (Join-Path $binaries "escriba-sandbox-$triple.exe") -Force
    $libraries = Get-ChildItem -LiteralPath (Join-Path $app "native-host/target/$configuration") -Filter '*.dll'
    foreach ($library in $libraries) {
        foreach ($destination in @($binaries, $native, $appTarget)) { Copy-Item -LiteralPath $library.FullName -Destination $destination -Force }
    }
    if (Test-Path -LiteralPath $vswhere) {
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        $redistRoot = Join-Path $vs 'VC/Redist/MSVC'
        $crt = Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object Name -Match '^\d' | Sort-Object Name -Descending | ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC*.CRT' } | Select-Object -First 1
        if (!$crt) { throw 'Faltan las bibliotecas redistribuibles x64 de Visual C++.' }
        if ($crt) {
            foreach ($library in (Get-ChildItem -LiteralPath $crt.FullName -Filter '*.dll')) {
                Copy-Item -LiteralPath $library.FullName -Destination $native -Force
                Copy-Item -LiteralPath $library.FullName -Destination $appTarget -Force
            }
        }
    }
    Invoke-Checked node @('apps/tauri/scripts/prepare.mjs')
    Invoke-Checked npm.cmd @('run', 'typecheck:runtime', '--prefix', 'apps/tauri')
    Invoke-Checked pwsh @('-NoProfile', '-File', (Join-Path $project 'scripts/test-windows-project.ps1'))
    if (!$PrepareOnly) {
        Push-Location $app
        try {
            $tauriArgs = @('node_modules/@tauri-apps/cli/tauri.js', 'build')
            if ($DebugBuild) { $tauriArgs += '--debug' }
            $tauriArgs += if ($NoBundle) { @('--no-bundle') } else { @('--bundles', 'nsis') }
            $tauriArgs += @('--', '--config', (Join-Path $project 'scripts/windows-cargo.toml'))
            Invoke-Checked node $tauriArgs
        } finally { Pop-Location }
        Write-Output "Construido: $appTarget/escriba-tauri.exe"
        if (!$NoBundle) { Get-ChildItem -LiteralPath (Join-Path $appTarget 'bundle/nsis') -Filter '*.exe' | Select-Object -ExpandProperty FullName }
    }
} finally { Pop-Location }
