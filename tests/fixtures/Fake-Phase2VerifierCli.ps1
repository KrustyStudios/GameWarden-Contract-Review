param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$prompt = [Console]::In.ReadToEnd()
$slot = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_SLOT')
$logRoot = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_FAKE_LOG_DIR')
$scenario = [Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_FAKE_SCENARIO')
if ([string]::IsNullOrWhiteSpace($logRoot)) { throw 'CONTRACT_REVIEW_FAKE_LOG_DIR is required.' }
if ($slot -cne 'phase2-verifier') { throw "Unexpected Phase 2 verifier slot: $slot" }
if (@(Get-ChildItem -LiteralPath (Get-Location).Path -Force).Count -ne 0) {
    throw 'Phase 2 verifier private directory was not empty.'
}

$utf8 = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $logRoot 'phase2-verifier.prompt.md'), $prompt, $utf8)
[IO.File]::WriteAllText((Join-Path $logRoot 'phase2-verifier.cwd.txt'), (Get-Location).Path, $utf8)
[IO.File]::WriteAllText((Join-Path $logRoot 'phase2-verifier.start'), [DateTime]::UtcNow.ToString('o'), $utf8)
if ($scenario -eq 'fail') {
    [Console]::Error.WriteLine('deliberate Phase 2 verifier failure')
    exit 17
}

$paths = [ordered]@{}
foreach ($label in @('GUIDE', 'RULES', 'GUARDRAILS', 'PHASE 2 MANIFEST')) {
    $match = [regex]::Match($prompt, "(?m)^$([regex]::Escape($label)) PATH: (.+)$")
    if (-not $match.Success) { throw "Prompt omitted $label PATH." }
    $paths[$label] = $match.Groups[1].Value.TrimEnd("`r")
    if (-not (Test-Path -LiteralPath $paths[$label] -PathType Leaf)) {
        throw "$label input does not exist: $($paths[$label])"
    }
    [void][IO.File]::ReadAllBytes($paths[$label])
}
$outputMatch = [regex]::Match($prompt, '(?m)^OUTPUT ROOT PATH: (.+)$')
if (-not $outputMatch.Success) { throw 'Prompt omitted OUTPUT ROOT PATH.' }
$outputRoot = $outputMatch.Groups[1].Value.TrimEnd("`r")
if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) { throw "Output root does not exist: $outputRoot" }

$stagingMatches = [regex]::Matches($prompt, '(?m)^COPY ROW (\d+) STAGING PATH: (.+)$')
$outputMatches = [regex]::Matches($prompt, '(?m)^COPY ROW (\d+) OUTPUT PATH: (.+)$')
if ($stagingMatches.Count -eq 0 -or $stagingMatches.Count -ne $outputMatches.Count) {
    throw 'Prompt contains an invalid Phase 2 mapping list.'
}

function Test-FakePhase2BytesEqual {
    param([byte[]]$First, [byte[]]$Second)
    if ($First.Length -ne $Second.Length) { return $false }
    for ($index = 0; $index -lt $First.Length; $index++) {
        if ($First[$index] -ne $Second[$index]) { return $false }
    }
    $true
}

function Get-FakePhase2Hash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

$mismatch = $false
$expectedOutputs = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$evidenceParts = [Collections.Generic.List[string]]::new()
for ($index = 0; $index -lt $stagingMatches.Count; $index++) {
    if ($stagingMatches[$index].Groups[1].Value -cne $outputMatches[$index].Groups[1].Value) {
        throw 'Prompt mapping row numbers do not match.'
    }
    $stagingPath = $stagingMatches[$index].Groups[2].Value.TrimEnd("`r")
    $outputPath = $outputMatches[$index].Groups[2].Value.TrimEnd("`r")
    if (-not (Test-Path -LiteralPath $stagingPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        $mismatch = $true
        $evidenceParts.Add("missing staging=$stagingPath or output=$outputPath")
        continue
    }
    $stagingBytes = [IO.File]::ReadAllBytes($stagingPath)
    $outputBytes = [IO.File]::ReadAllBytes($outputPath)
    $stagingHash = Get-FakePhase2Hash $stagingBytes
    $outputHash = Get-FakePhase2Hash $outputBytes
    $evidenceParts.Add("staging=$stagingPath sha256=$stagingHash output=$outputPath sha256=$outputHash")
    if (-not (Test-FakePhase2BytesEqual $stagingBytes $outputBytes)) {
        $mismatch = $true
    }
    [void]$expectedOutputs.Add((Resolve-Path -LiteralPath $outputPath).Path)
}
$actualOutputs = @(Get-ChildItem -LiteralPath $outputRoot -Recurse -File | ForEach-Object FullName)
if ($actualOutputs.Count -ne $expectedOutputs.Count) { $mismatch = $true }
foreach ($actualOutput in $actualOutputs) {
    if (-not $expectedOutputs.Contains($actualOutput)) {
        $mismatch = $true
        $evidenceParts.Add("unexpected output=$actualOutput")
    }
}

if ($scenario -eq 'blocked') {
    $mismatch = $true
    $evidenceParts.Add('exact mismatch=deliberate blocked test scenario')
}
$status = if ($mismatch) { 'BLOCKED' } else { 'VERIFIED' }
$check = if ($mismatch) { 'MISMATCH' } else { 'VERIFIED' }
$evidence = $evidenceParts -join '; '
$report = @(
    "STATUS: $status"
    '# Phase 2 verification'
    "Manifest rows: $($stagingMatches.Count)"
    "File list: $check"
    "Paths: $check"
    "Byte equality: $check"
    "Approved mapping: $check"
    "Evidence: $evidence"
) -join "`n"
$report += "`n"

$outputIndex = [Array]::IndexOf($Arguments, '--output-last-message')
if ($outputIndex -ge 0) {
    [IO.File]::WriteAllText($Arguments[$outputIndex + 1], $report, $utf8)
} else {
    [Console]::Out.Write($report)
}
