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
$fields = $rows[0] -split "`t"
$destination = $fields[1]
if ($destination -notmatch '^contracts/.+_CONTRACT\.md$' -or [IO.Path]::IsPathRooted($destination) -or $destination -match '(^|/)\.\.(/|$)') {
    throw "fake splitter: unsafe destination: $destination"
}
Write-Host "fake splitter: validated $lineCount source lines for $destination"
if ($CheckOnly) { Write-Host 'fake splitter: check passed'; return }
if (Test-Path $OutDir) { throw 'fake splitter: output already exists' }
$outputPath = Join-Path $OutDir $destination.Replace('/', [IO.Path]::DirectorySeparatorChar)
New-Item -ItemType Directory -Path (Split-Path $outputPath) -Force | Out-Null
[IO.File]::WriteAllBytes($outputPath, [IO.File]::ReadAllBytes($Source))
Write-Host "fake splitter: staged $destination verbatim"
