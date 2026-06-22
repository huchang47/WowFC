param(
    [string]$Version,
    [string]$OutputDir,
    [switch]$KeepStaging
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$addonName = "WowFC"
$addonDir = Join-Path $repoRoot $addonName
$tocPath = Join-Path $addonDir "$addonName.toc"

if (-not (Test-Path -LiteralPath $addonDir -PathType Container)) {
    throw "Addon folder not found: $addonDir"
}

if (-not (Test-Path -LiteralPath $tocPath -PathType Leaf)) {
    throw "TOC file not found: $tocPath"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $versionLine = Get-Content -LiteralPath $tocPath -Encoding UTF8 |
        Where-Object { $_ -match "^##\s*Version:\s*(.+?)\s*$" } |
        Select-Object -First 1

    if (-not $versionLine) {
        throw "Could not read version from $tocPath"
    }

    $Version = ($versionLine -replace "^##\s*Version:\s*", "").Trim()
}

$versionTag = if ($Version -match "^v") { $Version } else { "v$Version" }

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $releaseFolderName = -join ([char[]](0x53D1, 0x5E03, 0x7248, 0x672C))
    $OutputDir = Join-Path $repoRoot $releaseFolderName
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $repoRoot $OutputDir
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$stagingRoot = Join-Path $env:TEMP ("WowFC-package-" + [System.Guid]::NewGuid().ToString("N"))
$stagedAddon = Join-Path $stagingRoot $addonName
$fullZipName = "{0}-{1}.zip" -f $addonName, $versionTag
$noExeZipName = "{0}.zip" -f $versionTag
$fullZipPath = Join-Path $OutputDir $fullZipName
$noExeZipPath = Join-Path $OutputDir $noExeZipName

try {
    New-Item -ItemType Directory -Force -Path $stagedAddon | Out-Null

    Get-ChildItem -LiteralPath $addonDir -Force |
        Copy-Item -Destination $stagedAddon -Recurse -Force

    if (Test-Path -LiteralPath $fullZipPath) {
        Remove-Item -LiteralPath $fullZipPath -Force
    }
    if (Test-Path -LiteralPath $noExeZipPath) {
        Remove-Item -LiteralPath $noExeZipPath -Force
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingRoot,
        $fullZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    Get-ChildItem -LiteralPath $stagedAddon -Recurse -Force -Filter "*.exe" |
        Remove-Item -Force

    [System.IO.Compression.ZipFile]::CreateFromDirectory(
        $stagingRoot,
        $noExeZipPath,
        [System.IO.Compression.CompressionLevel]::Optimal,
        $false
    )

    Write-Host "Created packages:"
    Write-Host $fullZipPath
    Write-Host $noExeZipPath
} finally {
    if (-not $KeepStaging -and (Test-Path -LiteralPath $stagingRoot)) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
