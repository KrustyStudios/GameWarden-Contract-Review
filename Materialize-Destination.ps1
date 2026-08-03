# Materialize one approved Phase 1 destination without AI-authored whole-file output.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Incoming,
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][string]$Packet,
    [Parameter(Mandatory = $true)][string]$Output,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Utf8NoBom = [Text.UTF8Encoding]::new($false, $true)

function Get-DestinationMaterializerHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-DestinationLineStarts {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $starts = [Collections.Generic.List[int]]::new()
    if ($Bytes.Length -eq 0) { return ,$starts }
    $starts.Add(0)
    for ($index = 0; $index -lt $Bytes.Length; $index++) {
        if ($Bytes[$index] -eq 13) {
            if (($index + 1) -lt $Bytes.Length -and $Bytes[$index + 1] -eq 10) { $index++ }
            if (($index + 1) -lt $Bytes.Length) { $starts.Add($index + 1) }
        } elseif ($Bytes[$index] -eq 10 -and ($index + 1) -lt $Bytes.Length) {
            $starts.Add($index + 1)
        }
    }
    return ,$starts
}

function Get-DestinationSourceSlice {
    param(
        [Parameter(Mandatory = $true)][object]$InputRecord,
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End
    )
    $offset = $InputRecord.LineStarts[$Start - 1]
    $exclusiveEnd = if ($End -lt $InputRecord.LineStarts.Count) {
        $InputRecord.LineStarts[$End]
    } else {
        $InputRecord.Bytes.Length
    }
    $slice = [byte[]]::new($exclusiveEnd - $offset)
    [Array]::Copy($InputRecord.Bytes, $offset, $slice, 0, $slice.Length)
    return ,$slice
}

function Assert-DestinationTag {
    param([Parameter(Mandatory = $true)][string]$Tag, [Parameter(Mandatory = $true)][string]$Label)
    if ($Tag -notmatch '^\[[^\]\r\n\t]+\]$') {
        throw "$Label must be one bracketed tag without tabs or newlines: '$Tag'"
    }
}

function Assert-DestinationBlockId {
    param([Parameter(Mandatory = $true)][string]$BlockId, [Parameter(Mandatory = $true)][string]$Label)
    if ($BlockId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
        throw "$Label has an invalid block id: '$BlockId'"
    }
}

function Get-ExactInputRecord {
    param(
        [Parameter(Mandatory = $true)][object[]]$InputRecords,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$ManifestLine
    )
    $matches = @($InputRecords | Where-Object { $_.Path -ceq $Path })
    if ($matches.Count -ne 1) {
        throw "manifest line ${ManifestLine}: path is not one exact supplied input path: '$Path'"
    }
    $matches[0]
}

function Assert-DestinationInputsStillMatch {
    param(
        [Parameter(Mandatory = $true)][object[]]$InputRecords,
        [Parameter(Mandatory = $true)][string]$PacketPath,
        [Parameter(Mandatory = $true)][string]$PacketHash,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][bool]$DestinationExisted
    )
    foreach ($inputRecord in $InputRecords) {
        if (-not (Test-Path -LiteralPath $inputRecord.Path -PathType Leaf) -or
            (Get-DestinationMaterializerHash ([IO.File]::ReadAllBytes($inputRecord.Path))) -ne $inputRecord.Hash) {
            throw "input changed during materialization: $($inputRecord.Path)"
        }
    }
    if ((Get-DestinationMaterializerHash ([IO.File]::ReadAllBytes($PacketPath))) -ne $PacketHash) {
        throw "packet changed during materialization: $PacketPath"
    }
    if (-not $DestinationExisted -and (Test-Path -LiteralPath $DestinationPath)) {
        throw "new destination appeared during materialization: $DestinationPath"
    }
}

if (-not (Test-Path -LiteralPath $Incoming -PathType Leaf)) { throw "incoming file not found: $Incoming" }
if (-not (Test-Path -LiteralPath $Packet -PathType Leaf)) { throw "packet not found: $Packet" }
$incomingPath = (Resolve-Path -LiteralPath $Incoming).Path
$packetPath = (Resolve-Path -LiteralPath $Packet).Path
$destinationPath = [IO.Path]::GetFullPath($Destination)
$destinationExisted = Test-Path -LiteralPath $destinationPath -PathType Leaf
if ((Test-Path -LiteralPath $destinationPath) -and -not $destinationExisted) {
    throw "destination is not a file: $destinationPath"
}
if ($destinationExisted) { $destinationPath = (Resolve-Path -LiteralPath $destinationPath).Path }
if ($incomingPath.Equals($destinationPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'incoming file and destination must be different paths'
}

$outputPath = [IO.Path]::GetFullPath($Output)
foreach ($protectedPath in @($incomingPath, $destinationPath, $packetPath)) {
    if ($outputPath.Equals($protectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "output cannot replace an input: $outputPath"
    }
}
if (Test-Path -LiteralPath $outputPath) { throw "output already exists; refusing to overwrite: $outputPath" }

$inputRecords = [Collections.Generic.List[object]]::new()
foreach ($inputPath in @($incomingPath) + $(if ($destinationExisted) { @($destinationPath) } else { @() })) {
    $bytes = [IO.File]::ReadAllBytes($inputPath)
    $lineStarts = Get-DestinationLineStarts $bytes
    $inputRecords.Add([pscustomobject]@{
        Path = $inputPath
        Bytes = $bytes
        Hash = Get-DestinationMaterializerHash $bytes
        LineStarts = $lineStarts
        Covered = [bool[]]::new($lineStarts.Count)
    })
}

$packetBytes = [IO.File]::ReadAllBytes($packetPath)
$packetHash = Get-DestinationMaterializerHash $packetBytes
$packetText = $Utf8NoBom.GetString($packetBytes)
$manifestMatches = [regex]::Matches(
    $packetText,
    '(?ms)^BEGIN DESTINATION MANIFEST[ \t]*\r?\n(?<body>.*?)^END DESTINATION MANIFEST[ \t]*\r?$'
)
if ($manifestMatches.Count -ne 1) { throw "packet must contain exactly one destination manifest; found $($manifestMatches.Count)" }

$textBlockMatches = [regex]::Matches(
    $packetText,
    '(?ms)^BEGIN DESTINATION TEXT (?<id>[A-Za-z0-9][A-Za-z0-9._-]{0,79})[ \t]*\r?\n(?<body>.*?)^END DESTINATION TEXT \k<id>[ \t]*\r?$'
)
$beginBlockCount = [regex]::Matches($packetText, '(?m)^BEGIN DESTINATION TEXT ').Count
$endBlockCount = [regex]::Matches($packetText, '(?m)^END DESTINATION TEXT ').Count
if ($beginBlockCount -ne $textBlockMatches.Count -or $endBlockCount -ne $textBlockMatches.Count) {
    throw 'packet contains a malformed or mismatched destination text block'
}
$textBlocks = @{}
foreach ($match in $textBlockMatches) {
    $blockId = $match.Groups['id'].Value
    if ($textBlocks.ContainsKey($blockId)) { throw "duplicate destination text block: $blockId" }
    $textBlocks[$blockId] = $match.Groups['body'].Value
}

$rows = [Collections.Generic.List[object]]::new()
$manifestLine = 0
foreach ($rawLine in [regex]::Split($manifestMatches[0].Groups['body'].Value, '\r?\n')) {
    $manifestLine++
    if ([string]::IsNullOrWhiteSpace($rawLine)) { continue }
    $parts = @($rawLine.Split([char]9))
    $operation = $parts[0]
    $expectedFields = switch ($operation) {
        'COPY' { 3 }
        'RENAME' { 5 }
        'SPLIT' { 4 }
        'DELETE' { 5 }
        'NEW' { 4 }
        default { throw "manifest line ${manifestLine}: unsupported operation '$operation'" }
    }
    if ($parts.Count -ne $expectedFields) {
        throw "manifest line ${manifestLine}: $operation requires exactly $expectedFields tab-separated fields"
    }

    if ($operation -eq 'NEW') {
        if ($parts[1] -ne '-' -or $parts[2] -ne '-') {
            throw "manifest line ${manifestLine}: NEW path and range must both be '-'"
        }
        Assert-DestinationBlockId $parts[3] "manifest line ${manifestLine}"
        $rows.Add([pscustomobject]@{ Operation = $operation; BlockId = $parts[3]; ManifestLine = $manifestLine })
        continue
    }

    $inputRecord = Get-ExactInputRecord $inputRecords.ToArray() $parts[1] $manifestLine
    if ($parts[2] -notmatch '^(\d+)-(\d+)$') {
        throw "manifest line ${manifestLine}: invalid range '$($parts[2])'"
    }
    $start = [int]$Matches[1]
    $end = [int]$Matches[2]
    if ($start -lt 1 -or $start -gt $end -or $end -gt $inputRecord.LineStarts.Count) {
        throw "manifest line ${manifestLine}: range $start-$end is outside 1-$($inputRecord.LineStarts.Count) or inverted"
    }
    foreach ($lineNumber in $start..$end) {
        if ($inputRecord.Covered[$lineNumber - 1]) {
            throw "manifest line ${manifestLine}: input line is covered more than once: $($inputRecord.Path):$lineNumber"
        }
        $inputRecord.Covered[$lineNumber - 1] = $true
    }

    $row = [ordered]@{
        Operation = $operation
        Input = $inputRecord
        Start = $start
        End = $end
        ManifestLine = $manifestLine
    }
    switch ($operation) {
        'RENAME' {
            Assert-DestinationTag $parts[3] "manifest line ${manifestLine} old tag"
            Assert-DestinationTag $parts[4] "manifest line ${manifestLine} new tag"
            if ($parts[3] -ceq $parts[4]) { throw "manifest line ${manifestLine}: RENAME tags are identical" }
            $row.OldTag = $parts[3]
            $row.NewTag = $parts[4]
        }
        'SPLIT' {
            Assert-DestinationBlockId $parts[3] "manifest line ${manifestLine}"
            $row.BlockId = $parts[3]
        }
        'DELETE' {
            $survivorPath = $parts[3].Replace('\', '/')
            if ($survivorPath -notmatch '^contracts/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+_CONTRACT\.md$') {
                throw "manifest line ${manifestLine}: invalid surviving contract path '$($parts[3])'"
            }
            Assert-DestinationTag $parts[4] "manifest line ${manifestLine} surviving tag"
            $row.SurvivorPath = $survivorPath
            $row.SurvivorTag = $parts[4]
        }
    }
    $rows.Add([pscustomobject]$row)
}
if ($rows.Count -eq 0) { throw 'destination manifest contains no operations' }

foreach ($inputRecord in $inputRecords) {
    for ($index = 0; $index -lt $inputRecord.Covered.Count; $index++) {
        if (-not $inputRecord.Covered[$index]) {
            throw "input line is not covered: $($inputRecord.Path):$($index + 1)"
        }
    }
}

$blockReferences = @{}
foreach ($row in $rows) {
    if ($row.Operation -notin @('SPLIT', 'NEW')) { continue }
    if (-not $textBlocks.ContainsKey($row.BlockId)) {
        throw "manifest line $($row.ManifestLine): missing destination text block '$($row.BlockId)'"
    }
    if ($blockReferences.ContainsKey($row.BlockId)) {
        throw "destination text block is referenced more than once: $($row.BlockId)"
    }
    $blockReferences[$row.BlockId] = $true
}
foreach ($blockId in $textBlocks.Keys) {
    if (-not $blockReferences.ContainsKey($blockId)) {
        throw "unreferenced destination text block: $blockId"
    }
}

$outputStream = [IO.MemoryStream]::new()
try {
    foreach ($row in $rows) {
        $operationBytes = switch ($row.Operation) {
            'COPY' {
                Get-DestinationSourceSlice $row.Input $row.Start $row.End
            }
            'RENAME' {
                $sourceBytes = Get-DestinationSourceSlice $row.Input $row.Start $row.End
                $sourceText = $Utf8NoBom.GetString($sourceBytes)
                $occurrences = 0
                $searchAt = 0
                while ($searchAt -le $sourceText.Length - $row.OldTag.Length) {
                    $foundAt = $sourceText.IndexOf($row.OldTag, $searchAt, [StringComparison]::Ordinal)
                    if ($foundAt -lt 0) { break }
                    $occurrences++
                    $searchAt = $foundAt + $row.OldTag.Length
                }
                if ($occurrences -ne 1) {
                    throw "manifest line $($row.ManifestLine): old tag must occur exactly once in RENAME range; found $occurrences"
                }
                $Utf8NoBom.GetBytes($sourceText.Replace($row.OldTag, $row.NewTag, [StringComparison]::Ordinal))
            }
            'SPLIT' { $Utf8NoBom.GetBytes([string]$textBlocks[$row.BlockId]) }
            'DELETE' { [byte[]]::new(0) }
            'NEW' { $Utf8NoBom.GetBytes([string]$textBlocks[$row.BlockId]) }
        }
        [byte[]]$bytesToWrite = @()
        if ($null -ne $operationBytes) { $bytesToWrite = [byte[]]@($operationBytes) }
        if ($bytesToWrite.Length -gt 0) { $outputStream.Write($bytesToWrite, 0, $bytesToWrite.Length) }
    }
    $outputBytes = $outputStream.ToArray()
} finally {
    $outputStream.Dispose()
}

Assert-DestinationInputsStillMatch $inputRecords.ToArray() $packetPath $packetHash $destinationPath $destinationExisted
$outputHash = Get-DestinationMaterializerHash $outputBytes
Write-Host "incoming    : $incomingPath"
Write-Host "destination : $destinationPath ($(if ($destinationExisted) { 'existing' } else { 'new' }))"
Write-Host "operations  : $($rows.Count)"
Write-Host 'coverage    : OK - every input line is covered exactly once' -ForegroundColor Green
Write-Host "output      : $($outputBytes.Length) bytes, sha256 $outputHash"
if ($CheckOnly) { Write-Host 'check-only  : no file written'; return }

$outputParent = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
$temporary = Join-Path $outputParent ('.{0}.tmp-{1}' -f (Split-Path -Leaf $outputPath), [guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllBytes($temporary, $outputBytes)
    Assert-DestinationInputsStillMatch $inputRecords.ToArray() $packetPath $packetHash $destinationPath $destinationExisted
    [IO.File]::Move($temporary, $outputPath)
} finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
if ((Get-DestinationMaterializerHash ([IO.File]::ReadAllBytes($outputPath))) -ne $outputHash) {
    throw "written output hash mismatch: $outputPath"
}
Write-Host "written     : $outputPath" -ForegroundColor Green
