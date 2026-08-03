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
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.prompt.md"), $prompt, $utf8)
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.cwd.txt"), (Get-Location).Path, $utf8)
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.start"), [DateTime]::UtcNow.ToString('o'), $utf8)

$inputPaths = [ordered]@{}
foreach ($label in @('GUIDE', 'RULES', 'GUARDRAILS', 'ORIGINAL SOURCE CONTRACT', 'INCOMING WORKING FILE', 'DESTINATION CONTRACT')) {
    $match = [regex]::Match($prompt, "(?m)^$([regex]::Escape($label)) PATH: (.+)$")
    if (-not $match.Success) { throw "Prompt omitted $label PATH." }
    $inputPaths[$label] = $match.Groups[1].Value.TrimEnd("`r")
}
foreach ($label in @('GUIDE', 'RULES', 'GUARDRAILS', 'ORIGINAL SOURCE CONTRACT', 'INCOMING WORKING FILE')) {
    $inputPath = $inputPaths[$label]
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw "$label input does not exist: $inputPath" }
    [void][IO.File]::ReadAllBytes($inputPath)
}
$destinationStateMatch = [regex]::Match($prompt, '(?m)^DESTINATION STATE: (EXISTING|NEW)\s*$')
if (-not $destinationStateMatch.Success) { throw 'Prompt omitted a valid destination state.' }
$destinationPath = $inputPaths['DESTINATION CONTRACT']
if ($destinationStateMatch.Groups[1].Value -eq 'EXISTING') {
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) { throw "Destination does not exist: $destinationPath" }
    [void][IO.File]::ReadAllBytes($destinationPath)
}
[IO.File]::WriteAllText((Join-Path $logRoot "$slot.input-paths.txt"), (($inputPaths.Values -join "`n") + "`n"), $utf8)

if ($slot -like 'blind-*') {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not ((Test-Path (Join-Path $logRoot 'blind-A.start')) -and (Test-Path (Join-Path $logRoot 'blind-B.start')))) {
        if ([DateTime]::UtcNow -gt $deadline) { [Console]::Error.WriteLine('blind reviewers were not concurrent'); exit 21 }
        Start-Sleep -Milliseconds 50
    }
    [IO.File]::WriteAllText((Join-Path $logRoot "$slot.concurrent"), 'yes', $utf8)
    if ($scenario -eq 'fail-a' -and $slot -eq 'blind-A') {
        Start-Sleep -Milliseconds 500
        [Console]::Error.WriteLine('deliberate destination reviewer failure')
        exit 17
    }
    if ($scenario -eq 'fail-a' -and $slot -eq 'blind-B') {
        $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 30') -PassThru
        [IO.File]::WriteAllText((Join-Path $logRoot 'blind-B.child-pid'), [string]$child.Id, $utf8)
        $child.WaitForExit()
    }
}

$incomingPath = $inputPaths['INCOMING WORKING FILE']
$incomingLines = [IO.File]::ReadAllLines($incomingPath).Count
$destinationLines = if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
    [IO.File]::ReadAllLines($destinationPath).Count
} else {
    0
}
$manifestRows = [Collections.Generic.List[string]]::new()
if ($destinationLines -gt 0) { $manifestRows.Add("COPY`t$destinationPath`t" + "1-$destinationLines") }
$manifestRows.Add("COPY`t$incomingPath`t" + "1-$incomingLines")
$manifest = $manifestRows -join "`n"

$report = switch -Wildcard ($slot) {
    'blind-A' {
        "STATUS: OK`n# Destination review`nThe existing and incoming rules are compatible.`n`nBEGIN DESTINATION MANIFEST`n$manifest`nEND DESTINATION MANIFEST`n"
    }
    'blind-B' {
        "STATUS: OK`n# Destination review`nBoth inputs are retained in destination order.`n`nBEGIN DESTINATION MANIFEST`n$manifest`nEND DESTINATION MANIFEST`n"
    }
    'comparator' {
        "STATUS: OK`n# Comparison`nBoth reviewers cover every input line and agree on the same operations.`nBEGIN PROOF REQUESTS`nNONE`nEND PROOF REQUESTS`n"
    }
    'validator' {
        "STATUS: COMPLETE`n# Final destination validation`nThe manifest is complete and ready for mechanical materialization.`nBEGIN DESTINATION MANIFEST`n$manifest`nEND DESTINATION MANIFEST`n"
    }
    default { throw "Unexpected test slot: $slot" }
}

$outputIndex = [Array]::IndexOf($Arguments, '--output-last-message')
if ($outputIndex -ge 0) {
    [IO.File]::WriteAllText($Arguments[$outputIndex + 1], $report, $utf8)
} else {
    [Console]::Out.Write($report)
}
