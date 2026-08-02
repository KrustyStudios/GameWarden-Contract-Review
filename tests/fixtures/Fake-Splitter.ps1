[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lineCount = [IO.File]::ReadAllLines($Source).Count
$rows = @([IO.File]::ReadAllLines($Manifest) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($rows.Count -ne 1 -or $rows[0] -notmatch "^1-$lineCount`t") { throw 'fake splitter: manifest does not cover the complete source' }
if ($CheckOnly) { return }
if (Test-Path $OutDir) { throw 'fake splitter: output already exists' }
New-Item -ItemType Directory -Path $OutDir | Out-Null
[IO.File]::WriteAllBytes((Join-Path $OutDir 'copied-source.md'), [IO.File]::ReadAllBytes($Source))
