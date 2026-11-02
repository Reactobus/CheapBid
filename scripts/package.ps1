# Builds dist/CheapBids-<Version>.zip for a manual CurseForge upload, with the same
# layout the packager produces from .pkgmeta on CI.
param([Parameter(Mandatory)][string]$Version)

$ErrorActionPreference = 'Stop'
$root  = Split-Path $PSScriptRoot
$stage = Join-Path ([IO.Path]::GetTempPath()) "CheapBids-package-$PID"
$zip   = Join-Path $root "dist/CheapBids-$Version.zip"

New-Item -ItemType Directory -Force $stage, (Split-Path $zip) | Out-Null
foreach ($name in 'CheapBids', 'CheapBids_CompactBrowse', 'CheapBids_Disenchant', 'CheapBids_Prospect') {
    Copy-Item (Join-Path $root $name) (Join-Path $stage $name) -Recurse
    Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage $name)
    $toc = Join-Path $stage "$name/$name.toc"
    (Get-Content $toc -Raw).Replace('@project-version@', $Version) | Set-Content $toc -NoNewline
}

if (Test-Path $zip) { Remove-Item $zip }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Remove-Item $stage -Recurse -Force
Write-Output $zip
