param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$prompt = [Console]::In.ReadToEnd()
$slot = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_SLOT')
$logRoot = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_FAKE_LOG_DIR')
$scenario = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_FAKE_SCENARIO')
if ([string]::IsNullOrWhiteSpace($logRoot)) { throw 'CONTRACT_REVIEW_FAKE_LOG_DIR is required.' }
if ([string]::IsNullOrWhiteSpace($slot)) { $slot = 'unknown' }
if (@(Get-ChildItem -LiteralPath (Get-Location).Path -File -Force).Count -ne 0) {
    throw 'Private output directory contained copied input files.'
}

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.prompt.md"), $prompt, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.cwd.txt"), (Get-Location).Path, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.start"), [DateTime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))

$inputPaths = [ordered]@{}
foreach ($label in @('GUIDE', 'RULES', 'GUARDRAILS', 'SOURCE CONTRACT')) {
    $match = [regex]::Match($prompt, "(?m)^$([regex]::Escape($label)) PATH: (.+)$")
    if (-not $match.Success) { throw "Prompt omitted $label PATH." }
    $path = $match.Groups[1].Value.TrimEnd("`r")
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$label input does not exist: $path" }
    [void][IO.File]::ReadAllBytes($path)
    $inputPaths[$label] = $path
}
$stagingMatch = [regex]::Match($prompt, '(?m)^STAGING CONTRACT TREE PATH: (.+)$')
if (-not $stagingMatch.Success) { throw 'Prompt omitted STAGING CONTRACT TREE PATH.' }
$stagingPath = $stagingMatch.Groups[1].Value.TrimEnd("`r")
if (-not (Test-Path -LiteralPath $stagingPath -PathType Container)) { throw "Staging tree does not exist: $stagingPath" }
$inputPaths['STAGING CONTRACT TREE'] = $stagingPath
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.input-paths.txt"), (($inputPaths.Values -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

if ($slot -like 'blind-*') {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not ((Test-Path (Join-Path $logRoot 'blind-A.start')) -and (Test-Path (Join-Path $logRoot 'blind-B.start')))) {
        if ([DateTime]::UtcNow -gt $deadline) { [Console]::Error.WriteLine('blind reviewers were not concurrent'); exit 21 }
        Start-Sleep -Milliseconds 50
    }
    [IO.File]::WriteAllText((Join-Path $logRoot "$slot.concurrent"), 'yes', [Text.UTF8Encoding]::new($false))
    if ($scenario -eq 'fail-a' -and $slot -eq 'blind-A') {
        Start-Sleep -Milliseconds 500
        [Console]::Error.WriteLine('deliberate reviewer failure')
        exit 17
    }
    if ($scenario -eq 'fail-a' -and $slot -eq 'blind-B') {
        $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -PassThru
        [IO.File]::WriteAllText((Join-Path $logRoot 'blind-B.child-pid'), [string]$child.Id, [Text.UTF8Encoding]::new($false))
        $child.WaitForExit()
    }
}

$sourcePath = $inputPaths['SOURCE CONTRACT']
$sourceMapMatch = [regex]::Match($prompt, '(?ms)^BEGIN SOURCE BLOCK MAP\r?\n(.*?)^END SOURCE BLOCK MAP$')
$sourceBlockIds = @(
    if ($sourceMapMatch.Success) {
        foreach ($match in [regex]::Matches($sourceMapMatch.Groups[1].Value, '(?m)^(B-[a-f0-9]{16}(?:-[2-9][0-9]*)?)\t')) {
            $match.Groups[1].Value
        }
    }
)
$needsPlacement = $slot -in @('blind-A', 'blind-B', 'validator')
if ($needsPlacement -and $sourceBlockIds.Count -eq 0) { throw 'Prompt omitted the source block map.' }
$wholeSource = if ($sourceBlockIds.Count -gt 0) { "$($sourceBlockIds[0])..$($sourceBlockIds[-1])" } else { '' }
$contractsMarker = "$([IO.Path]::DirectorySeparatorChar)contracts$([IO.Path]::DirectorySeparatorChar)"
$contractsIndex = $sourcePath.IndexOf($contractsMarker, [StringComparison]::OrdinalIgnoreCase)
if ($contractsIndex -lt 0) { throw "Source path is not under contracts/: $sourcePath" }
$destination = $sourcePath.Substring($contractsIndex + 1).Replace('\', '/')

$report = switch -Wildcard ($slot) {
    'blind-A' {
        "STATUS: OK`nBEGIN PLACEMENT MANIFEST`nMOVE`t$wholeSource`t$destination`t[example]`nEND PLACEMENT MANIFEST`nBEGIN SPLIT TEXT`nNONE`nEND SPLIT TEXT`n"
    }
    'blind-B' {
        "STATUS: OK`nBEGIN PLACEMENT MANIFEST`nMOVE`t$($sourceBlockIds[0])..$($sourceBlockIds[0])`t$destination`t-`nMOVE`t$($sourceBlockIds[1])..$($sourceBlockIds[-1])`t$destination`t[example]`nEND PLACEMENT MANIFEST`nBEGIN SPLIT TEXT`nNONE`nEND SPLIT TEXT`n"
    }
    'comparator' {
        "STATUS: OK`n# Comparison`n## Inventory and granularity`nA has one rule block; B has two. They group the same source differently.`n## Agreements`nBoth use $destination and [example].`n## Differences and resolutions`nThe framing boundary needs proof.`nBEGIN PROOF REQUESTS`nA and B must prove whether '# Example' is framing or part of [EXAMPLE-RULE].`nEND PROOF REQUESTS`n"
    }
    'proof-*' {
        "STATUS: OK`n# Proof response`n## $destination / [example] / '# Example'`nResult: PROVED`nEvidence: '# Example' is separate framing above [EXAMPLE-RULE].`n"
    }
    'validator' {
        "STATUS: COMPLETE`n# Final validation`n## Resolutions`nKeep framing and the tagged rule together in one placement.`n## User decisions`nNONE`nBEGIN PLACEMENT MANIFEST`nMOVE`t$wholeSource`t$destination`t[example]`nEND PLACEMENT MANIFEST`nBEGIN SPLIT TEXT`nNONE`nEND SPLIT TEXT`n"
    }
    'verifier' {
        if ($scenario -eq 'block-verifier') {
            "STATUS: BLOCKED`n# Staging verification`nThe staged tree deliberately failed verification.`n"
        } else {
            "STATUS: VERIFIED`n# Staging verification`nThe source, final generated review, and staged contract agree.`n"
        }
    }
    default { throw "Unexpected test slot: $slot" }
}

$outputIndex = [Array]::IndexOf($Arguments, '--output-last-message')
if ($outputIndex -ge 0) {
    [IO.File]::WriteAllText($Arguments[$outputIndex + 1], $report, [Text.UTF8Encoding]::new($false))
} else {
    [Console]::Out.Write($report)
}
