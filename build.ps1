<#
.SYNOPSIS
    Builds dist/GPSTagger-<version>.zip containing the GPSTagger.lrplugin folder.

.DESCRIPTION
    The version is read from GPSTagger.lrplugin/Info.lua. The unit tests (tests/) are not
    packaged. With -Test, the tests run first (needs `lua` on PATH) and the build stops
    if they fail.

.EXAMPLE
    ./build.ps1
    ./build.ps1 -Test
#>
param(
    [switch]$Test
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$pluginDir = Join-Path $root 'GPSTagger.lrplugin'
$distDir = Join-Path $root 'dist'

# Version from Info.lua: VERSION = { major = 1, minor = 0, revision = 0 }
$info = Get-Content -Raw -Path (Join-Path $pluginDir 'Info.lua')
$m = [regex]::Match($info, 'VERSION\s*=\s*\{\s*major\s*=\s*(\d+)\s*,\s*minor\s*=\s*(\d+)\s*,\s*revision\s*=\s*(\d+)')
if (-not $m.Success) { throw 'Cannot read VERSION from Info.lua' }
$version = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"

if ($Test) {
    $lua = Get-Command lua, lua5.1, luajit -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $lua) { throw 'lua was not found on PATH; install it (winget install DEVCOM.Lua) or build without -Test' }
    Push-Location $pluginDir
    try {
        & $lua.Source 'tests/run.lua'
        if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
    }
    finally { Pop-Location }
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$zipPath = Join-Path $distDir "GPSTagger-$version.zip"
if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Entries are written by hand so that paths use forward slashes (zip standard; macOS/Linux safe).
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $files = Get-ChildItem -Path $pluginDir -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $file.FullName, $relative, [System.IO.Compression.CompressionLevel]::Optimal)
    }
}
finally { $zip.Dispose() }

Write-Host "Built $zipPath"
Write-Host "Files: $($files.Count)"
