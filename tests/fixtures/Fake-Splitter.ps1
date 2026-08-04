[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$Manifest,
    [string]$SplitText,
    [string]$ReviewOutput,
    [string]$StagingRoot,
    [switch]$ApplyStaging,
    [switch]$CheckOnly,
    [switch]$PrintSourceMap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false)
$lines = [IO.File]::ReadAllLines($Source)
$blocks = [Collections.Generic.List[object]]::new()
$occurrences = @{}
for ($index = 0; $index -lt $lines.Count; $index++) {
    if ([string]::IsNullOrWhiteSpace($lines[$index])) { continue }
    $hash = [Security.Cryptography.SHA256]::HashData($utf8.GetBytes($lines[$index]))
    $baseId = 'B-' + ([Convert]::ToHexString($hash)).Substring(0, 16).ToLowerInvariant()
    $occurrence = if ($occurrences.ContainsKey($baseId)) { [int]$occurrences[$baseId] + 1 } else { 1 }
    $occurrences[$baseId] = $occurrence
    $id = if ($occurrence -eq 1) { $baseId } else { "$baseId-$occurrence" }
    $blocks.Add([pscustomobject]@{ Id = $id; Line = $index; Index = $blocks.Count; Preview = $lines[$index].Trim() })
}
if ($blocks.Count -eq 0) { throw 'fake splitter: source contains no text blocks' }
if ($PrintSourceMap) {
    Write-Output 'BEGIN SOURCE BLOCK MAP'
    foreach ($block in $blocks) { Write-Output "$($block.Id)`t$($block.Preview)" }
    Write-Output 'END SOURCE BLOCK MAP'
    return
}

$blockById = @{}
foreach ($block in $blocks) { $blockById[$block.Id] = $block }
$rows = @([IO.File]::ReadAllLines($Manifest) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
$cursor = 0
$destination = $null
$entries = [Collections.Generic.List[string]]::new()
foreach ($row in $rows) {
    $fields = $row.Split([char]9)
    if ($fields.Count -ne 4 -or $fields[0] -ne 'MOVE' -or $fields[1] -notmatch '^(B-[a-f0-9]{16}(?:-[2-9][0-9]*)?)\.\.(B-[a-f0-9]{16}(?:-[2-9][0-9]*)?)$') { throw 'fake splitter: invalid MOVE row' }
    if (-not $blockById.ContainsKey($Matches[1]) -or -not $blockById.ContainsKey($Matches[2])) { throw 'fake splitter: unknown source block ID' }
    $start = $blockById[$Matches[1]]
    $end = $blockById[$Matches[2]]
    if ($start.Index -ne $cursor -or $end.Index -lt $start.Index) { throw 'fake splitter: placements do not tile the source' }
    $cursor = $end.Index + 1
    if ($fields[2] -notmatch '^contracts/.+_CONTRACT\.md$' -or $fields[2] -match '(^|/)\.\.(/|$)') { throw 'fake splitter: unsafe destination' }
    if ($null -eq $destination) { $destination = $fields[2] }
    elseif ($destination -ne $fields[2]) { throw 'fake splitter fixture supports one destination' }
    $entry = ($lines[$start.Line..$end.Line] -join "`n") + "`n"
    $sourceTags = @($lines[$start.Line..$end.Line] | Where-Object { $_ -match '^\[[^\]\r\n\t]+\]$' })
    if ($sourceTags.Count -gt 1) { throw 'fake splitter: source selection has multiple tags' }
    if ($fields[3] -ne '-') {
        if ($sourceTags.Count -eq 1) { $entry = $entry.Replace($sourceTags[0], $fields[3]) }
        else { $entry = $fields[3] + "`n" + $entry }
    }
    $entries.Add($entry)
}
if ($cursor -ne $blocks.Count) { throw 'fake splitter: placements do not cover the complete source' }
if ((Get-Content $SplitText -Raw).Trim() -ne 'NONE') { throw 'fake splitter fixture supports MOVE only' }
if (Test-Path $ReviewOutput) { throw 'fake splitter: review output already exists' }
Write-Host "fake splitter: validated $($blocks.Count) source blocks"
if ($CheckOnly) { Write-Host 'fake splitter: check passed'; return }

$visible = "# Contract placement review`n`n## $destination`n`n"
foreach ($entry in $entries) { $visible += '```text' + "`n" + $entry + '```' + "`n`n" }
New-Item -ItemType Directory -Path (Split-Path -Parent $ReviewOutput) -Force | Out-Null
[IO.File]::WriteAllText($ReviewOutput, $visible, $utf8)
if ($ApplyStaging) {
    if ([string]::IsNullOrWhiteSpace($StagingRoot)) { throw 'fake splitter: ApplyStaging requires StagingRoot' }
    $outputPath = Join-Path $StagingRoot $destination.Replace('/', [IO.Path]::DirectorySeparatorChar)
    New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
    [IO.File]::WriteAllText($outputPath, ($entries -join "`n"), $utf8)
}
Write-Host 'fake splitter: generated one grouped review'
