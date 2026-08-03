[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$Manifest,
    [Parameter(Mandatory = $true)][string]$SplitText,
    [Parameter(Mandatory = $true)][string]$ReviewOutput,
    [string]$StagingRoot,
    [switch]$ApplyStaging,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lines = [IO.File]::ReadAllLines($Source)
$rows = @([IO.File]::ReadAllLines($Manifest) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$cursor = 1
$destination = $null
$entries = [Collections.Generic.List[string]]::new()
foreach ($row in $rows) {
    $fields = $row.Split([char]9)
    if ($fields.Count -ne 5 -or $fields[0] -notmatch '^(\d+)-(\d+)$') { throw 'fake splitter: invalid MOVE row' }
    $start = [int]$Matches[1]
    $end = [int]$Matches[2]
    if ($start -ne $cursor) { throw 'fake splitter: placements do not tile the source' }
    $cursor = $end + 1
    if ($fields[1] -notmatch '^contracts/.+_CONTRACT\.md$' -or $fields[1] -match '(^|/)\.\.(/|$)') { throw 'fake splitter: unsafe destination' }
    if ($null -eq $destination) { $destination = $fields[1] }
    elseif ($destination -ne $fields[1]) { throw 'fake splitter fixture supports one destination' }
    $entry = ($lines[($start - 1)..($end - 1)] -join "`n") + "`n"
    if ($fields[4] -ne '-' -and $fields[2] -match '^\[') { $entry = $entry.Replace($fields[2], $fields[4]) }
    $entries.Add($entry)
}
if ($cursor -ne $lines.Count + 1) { throw 'fake splitter: placements do not cover the complete source' }
if ((Get-Content $SplitText -Raw).Trim() -ne 'NONE') { throw 'fake splitter fixture supports MOVE only' }
if (Test-Path $ReviewOutput) { throw 'fake splitter: review output already exists' }
Write-Host "fake splitter: validated $($lines.Count) source lines"
if ($CheckOnly) { Write-Host 'fake splitter: check passed'; return }

$visible = "# Contract placement review`n`n## $destination`n`n"
foreach ($entry in $entries) { $visible += '```text' + "`n" + $entry + '```' + "`n`n" }
New-Item -ItemType Directory -Path (Split-Path -Parent $ReviewOutput) -Force | Out-Null
[IO.File]::WriteAllText($ReviewOutput, $visible, [Text.UTF8Encoding]::new($false))
if ($ApplyStaging) {
    if ([string]::IsNullOrWhiteSpace($StagingRoot)) { throw 'fake splitter: ApplyStaging requires StagingRoot' }
    $outputPath = Join-Path $StagingRoot $destination.Replace('/', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
    [IO.File]::WriteAllText($outputPath, ($entries -join "`n"), [Text.UTF8Encoding]::new($false))
}
Write-Host 'fake splitter: generated one grouped review'
