param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$prompt = [Console]::In.ReadToEnd()
$slot = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_SLOT')
$logRoot = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_FAKE_LOG_DIR')
$scenario = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_FAKE_SCENARIO')
if ([string]::IsNullOrWhiteSpace($logRoot)) { throw 'CONTRACT_REVIEW_FAKE_LOG_DIR is required.' }
if ([string]::IsNullOrWhiteSpace($slot)) { $slot = 'unknown' }

New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.prompt.md"), $prompt, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllBytes((Join-Path $logRoot "$slot.GUIDE.md"), [IO.File]::ReadAllBytes((Join-Path (Get-Location) 'GUIDE.md')))
[IO.File]::WriteAllBytes((Join-Path $logRoot "$slot.TARGET.md"), [IO.File]::ReadAllBytes((Join-Path (Get-Location) 'TARGET.md')))
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.start"), [DateTime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))

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

$lineCount = [IO.File]::ReadAllLines((Join-Path (Get-Location) 'TARGET.md')).Count
$report = switch -Wildcard ($slot) {
    'blind-A' {
        "STATUS: OK`n# Blind review`nFinding count: 1`n`n## A1`nSource lines: 1-$lineCount`nSource tag: NONE`nDisposition: MOVE`nDestination: contracts/example_CONTRACT.md`nProposed tag: [example]`nReason: complete source`nEvidence: # Example`n`n# Candidate Stage 1 manifest`n1-$lineCount`tcontracts/example_CONTRACT.md`texample`tMOVE`t[example]`n"
    }
    'blind-B' {
        "STATUS: OK`n# Blind review`nFinding count: 2`n`n## B1`nSource lines: 1-1`nSource tag: NONE`nDisposition: MOVE`nDestination: contracts/example_CONTRACT.md`nProposed tag: [example heading]`nReason: heading`nEvidence: # Example`n`n## B2`nSource lines: 2-$lineCount`nSource tag: NONE`nDisposition: MOVE`nDestination: contracts/example_CONTRACT.md`nProposed tag: [example body]`nReason: body`nEvidence: alpha`n`n# Candidate Stage 1 manifest`n1-1`tcontracts/example_CONTRACT.md`texample heading`tMOVE`t[example heading]`n2-$lineCount`tcontracts/example_CONTRACT.md`texample body`tMOVE`t[example body]`n"
    }
    'comparator' {
        "STATUS: OK`n# Comparison`n## Inventory and granularity`nA has 1 finding; B has 2. They have different finding counts and split the same source differently.`n## Agreements`nThe whole source moves to the same destination.`n## Differences and resolutions`nGranularity needs source proof.`nBEGIN PROOF REQUESTS`nA:A1 and B:B1/B2 must prove their source boundaries.`nEND PROOF REQUESTS`n"
    }
    'proof-*' {
        "STATUS: OK`n# Proof response`n## boundary`nResult: PROVED`nEvidence: # Example and the complete source.`n"
    }
    'validator' {
        "STATUS: COMPLETE`n# Final validation`n## Resolutions`nUse one complete-source move.`n## User decisions`nNONE`nBEGIN STAGE1 MANIFEST`n1-$lineCount`tcontracts/example_CONTRACT.md`texample`tMOVE`t[example]`nEND STAGE1 MANIFEST`n"
    }
    default { throw "Unexpected test slot: $slot" }
}

$outputIndex = [Array]::IndexOf($Arguments, '--output-last-message')
if ($outputIndex -ge 0) {
    [IO.File]::WriteAllText($Arguments[$outputIndex + 1], $report, [Text.UTF8Encoding]::new($false))
} else {
    [Console]::Out.Write($report)
}
