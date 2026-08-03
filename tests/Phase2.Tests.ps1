Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'Start-ContractReview.ps1'
$copier = Join-Path $repoRoot 'Copy-ApprovedContracts.ps1'
$fakeCli = Join-Path $PSScriptRoot 'fixtures\Fake-Phase2VerifierCli.ps1'
$pwsh = (Get-Process -Id $PID).Path
$utf8 = [Text.UTF8Encoding]::new($false)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('contract-phase2-test-' + [guid]::NewGuid().ToString('N'))
$guidePath = Join-Path $tempRoot '.design\contract-epic.md'
$rulesPath = Join-Path $tempRoot 'AI_RULES.md'
$guardrailsPath = Join-Path $tempRoot 'AI_GUARDRAILS.md'
$stagingA = Join-Path $tempRoot 'phase1\alpha.md'
$stagingB = Join-Path $tempRoot 'phase1\beta.md'
$manifestPath = Join-Path $tempRoot 'approved-phase2.md'
$runsRoot = Join-Path $tempRoot 'runs'
$logRoot = Join-Path $tempRoot 'fake-log'

function Assert-Phase2True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-Phase2TestHash {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-Phase2TestManifestText {
    param(
        [string]$FirstPath = $stagingA,
        [string]$FirstDestination = 'contracts/shared/ALPHA_CONTRACT.md',
        [string]$FirstHash = (Get-Phase2TestHash $stagingA),
        [string]$SecondPath = $stagingB,
        [string]$SecondDestination = 'contracts/games/ark/BETA_CONTRACT.md',
        [string]$SecondHash = (Get-Phase2TestHash $stagingB)
    )
    (@(
        '# User-approved Phase 2 copy manifest'
        'BEGIN PHASE2 COPY MANIFEST'
        "COPY`t$FirstPath`t$FirstDestination`t$FirstHash"
        "COPY`t$SecondPath`t$SecondDestination`t$SecondHash"
        'END PHASE2 COPY MANIFEST'
    ) -join "`n") + "`n"
}

function Invoke-Phase2Runner {
    param(
        [string[]]$Extra,
        [string]$RunId,
        [string]$FinalRoot,
        [string]$ManifestFile = $manifestPath,
        [string]$Model = 'gpt-5.6-sol'
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner,
        '-Phase2',
        '-RunId', $RunId,
        '-GuidePath', $guidePath,
        '-RulesPath', $rulesPath,
        '-GuardrailsPath', $guardrailsPath,
        '-Phase2ManifestPath', $ManifestFile,
        '-OutputRoot', $FinalRoot,
        '-CopierPath', $copier,
        '-RunsRoot', $runsRoot,
        '-CodexCommand', $fakeCli,
        '-CodexModel', $Model,
        '-RoleTimeoutSeconds', '12'
    ) + $Extra
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $pwsh @arguments 2>&1)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Invoke-Phase2Copier {
    param([string]$ManifestFile, [string]$FinalRoot, [switch]$CheckOnly)
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $copier, '-Manifest', $ManifestFile, '-OutputRoot', $FinalRoot)
    if ($CheckOnly) { $arguments += '-CheckOnly' }
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $pwsh @arguments 2>&1)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

function Write-Phase2TestManifest {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    New-Item -ItemType Directory -Path (Split-Path $guidePath), (Split-Path $stagingA), $logRoot | Out-Null
    [IO.File]::WriteAllBytes($guidePath, [Text.Encoding]::UTF8.GetBytes("# Guide`nUse the approved Phase 2 process.`n"))
    [IO.File]::WriteAllBytes($rulesPath, [Text.Encoding]::UTF8.GetBytes("# Rules`r`nCopy approved rules exactly.`r`n"))
    [IO.File]::WriteAllBytes($guardrailsPath, [Text.Encoding]::UTF8.GetBytes("# Guardrails`nDo not edit originals.`n"))
    $alphaBytes = [Text.Encoding]::UTF8.GetBytes("# Alpha`n[ALPHA-RULE]`nalpha-one`nalpha-two`n")
    $betaBytes = [Text.Encoding]::UTF8.GetBytes("# Beta`r`n[BETA-RULE]`r`nbeta-one`r`nbeta-two`r`n")
    [IO.File]::WriteAllBytes($stagingA, $alphaBytes)
    [IO.File]::WriteAllBytes($stagingB, $betaBytes)
    Write-Phase2TestManifest $manifestPath (New-Phase2TestManifestText)
    $approvedHashes = @{
        $guidePath = Get-Phase2TestHash $guidePath
        $rulesPath = Get-Phase2TestHash $rulesPath
        $guardrailsPath = Get-Phase2TestHash $guardrailsPath
        $stagingA = Get-Phase2TestHash $stagingA
        $stagingB = Get-Phase2TestHash $stagingB
    }
    $env:CONTRACT_REVIEW_FAKE_LOG_DIR = $logRoot
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'success'

    $outputRoot = Join-Path $tempRoot 'final-contracts-success'
    $approvalResult = Invoke-Phase2Runner -RunId 'phase2-success' -FinalRoot $outputRoot -Extra @('-ShowApproval')
    Assert-Phase2True ($approvalResult.ExitCode -eq 0) "Phase 2 approval failed: $($approvalResult.Output)"
    $approval = [regex]::Match($approvalResult.Output, 'APPROVE CONTRACT APPLY phase2-success [a-f0-9]{64}').Value
    Assert-Phase2True (-not [string]::IsNullOrWhiteSpace($approval)) 'Phase 2 approval phrase was not printed.'
    Assert-Phase2True (@(Get-ChildItem -LiteralPath $logRoot -Force).Count -eq 0) 'Phase 2 ShowApproval launched the verifier.'
    Assert-Phase2True (-not (Test-Path -LiteralPath $outputRoot)) 'Phase 2 ShowApproval created the output root.'
    Assert-Phase2True (-not (Test-Path -LiteralPath (Join-Path $runsRoot 'phase2-success'))) 'Phase 2 ShowApproval created a run directory.'

    $alternateOutput = Join-Path $tempRoot 'final-contracts-alternate'
    $outputApproval = Invoke-Phase2Runner -RunId 'phase2-binding' -FinalRoot $outputRoot -Extra @('-ShowApproval')
    $alternateOutputApproval = Invoke-Phase2Runner -RunId 'phase2-binding' -FinalRoot $alternateOutput -Extra @('-ShowApproval')
    Assert-Phase2True ($outputApproval.Output -cne $alternateOutputApproval.Output) 'Phase 2 approval did not bind the exact output root.'
    $modelApproval = Invoke-Phase2Runner -RunId 'phase2-binding' -FinalRoot $outputRoot -Model 'gpt-test-alternate' -Extra @('-ShowApproval')
    Assert-Phase2True ($outputApproval.Output -cne $modelApproval.Output) 'Phase 2 approval did not bind the verifier model.'
    $alternateManifest = Join-Path $tempRoot 'approved-phase2-copy.md'
    [IO.File]::WriteAllBytes($alternateManifest, [IO.File]::ReadAllBytes($manifestPath))
    $manifestApproval = Invoke-Phase2Runner -RunId 'phase2-binding' -FinalRoot $outputRoot -ManifestFile $alternateManifest -Extra @('-ShowApproval')
    Assert-Phase2True ($outputApproval.Output -cne $manifestApproval.Output) 'Phase 2 approval did not bind the exact manifest path.'

    $originalManifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    [IO.File]::WriteAllBytes($stagingA, [Text.Encoding]::UTF8.GetBytes("# Alpha changed`n"))
    Write-Phase2TestManifest $manifestPath (New-Phase2TestManifestText)
    $byteApproval = Invoke-Phase2Runner -RunId 'phase2-binding' -FinalRoot $outputRoot -Extra @('-ShowApproval')
    Assert-Phase2True ($outputApproval.Output -cne $byteApproval.Output) 'Phase 2 approval did not bind approved staging bytes.'
    [IO.File]::WriteAllBytes($stagingA, $alphaBytes)
    [IO.File]::WriteAllBytes($manifestPath, $originalManifestBytes)

    $wrongOutput = Join-Path $tempRoot 'final-contracts-wrong'
    $wrong = Invoke-Phase2Runner -RunId 'phase2-wrong' -FinalRoot $wrongOutput -Extra @('-Approval', "APPROVE CONTRACT APPLY phase2-wrong $('0' * 64)")
    Assert-Phase2True ($wrong.ExitCode -ne 0) 'Phase 2 accepted a wrong approval.'
    Assert-Phase2True (-not (Test-Path -LiteralPath $wrongOutput)) 'Wrong Phase 2 approval created the output root.'
    Assert-Phase2True (-not (Test-Path -LiteralPath (Join-Path $runsRoot 'phase2-wrong'))) 'Wrong Phase 2 approval created a run directory.'

    $success = Invoke-Phase2Runner -RunId 'phase2-success' -FinalRoot $outputRoot -Extra @('-Approval', $approval)
    Assert-Phase2True ($success.ExitCode -eq 0) "Phase 2 success run failed: $($success.Output)"
    $runDirectory = Join-Path $runsRoot 'phase2-success'
    foreach ($artifact in @('copier-check.txt', 'copier-copy.txt', 'verification.md', 'receipt.md')) {
        Assert-Phase2True (Test-Path -LiteralPath (Join-Path $runDirectory $artifact) -PathType Leaf) "Phase 2 omitted retained artifact: $artifact"
    }
    Assert-Phase2True (-not (Test-Path -LiteralPath (Join-Path $runDirectory 'private'))) 'Phase 2 retained the verifier private directory.'
    $finalA = Join-Path $outputRoot 'contracts\shared\ALPHA_CONTRACT.md'
    $finalB = Join-Path $outputRoot 'contracts\games\ark\BETA_CONTRACT.md'
    Assert-Phase2True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes($stagingA)) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($finalA))
    ) 'Phase 2 changed LF staging bytes.'
    Assert-Phase2True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes($stagingB)) -ceq [Convert]::ToHexString([IO.File]::ReadAllBytes($finalB))
    ) 'Phase 2 changed CRLF staging bytes.'
    $finalFiles = @(Get-ChildItem -LiteralPath $outputRoot -Recurse -File)
    Assert-Phase2True ($finalFiles.Count -eq 2) 'Final contract tree contains files other than the two approved contracts.'
    Assert-Phase2True (-not (Test-Path -LiteralPath (Join-Path $outputRoot 'receipt.md'))) 'Receipt was written inside the final contract tree.'
    foreach ($inputPath in $approvedHashes.Keys) {
        Assert-Phase2True ((Get-Phase2TestHash $inputPath) -ceq $approvedHashes[$inputPath]) "Phase 2 changed an approved input: $inputPath"
    }
    $prompt = [IO.File]::ReadAllText((Join-Path $logRoot 'phase2-verifier.prompt.md'))
    foreach ($inputPath in @($guidePath, $rulesPath, $guardrailsPath, $manifestPath, $stagingA, $stagingB, $outputRoot)) {
        Assert-Phase2True ($prompt.Contains($inputPath, [StringComparison]::Ordinal)) "Phase 2 verifier prompt omitted exact path: $inputPath"
    }
    Assert-Phase2True (-not $prompt.Contains('[ALPHA-RULE]', [StringComparison]::Ordinal)) 'Phase 2 prompt inlined contract contents.'
    Assert-Phase2True (-not $prompt.Contains('phase2-success', [StringComparison]::Ordinal)) 'Phase 2 prompt included run metadata.'
    Assert-Phase2True ($prompt.Contains('Evidence: <exact paths and SHA-256 hashes, or the exact mismatch>', [StringComparison]::Ordinal)) 'Phase 2 prompt weakened the epic evidence requirement.'
    $verificationReport = [IO.File]::ReadAllText((Join-Path $runDirectory 'verification.md'))
    foreach ($evidenceValue in @($stagingA, $finalA, (Get-Phase2TestHash $stagingA), $stagingB, $finalB, (Get-Phase2TestHash $stagingB))) {
        Assert-Phase2True ($verificationReport.Contains($evidenceValue, [StringComparison]::Ordinal)) "Phase 2 verification omitted exact path/hash evidence: $evidenceValue"
    }

    $checkOnlyRoot = Join-Path $tempRoot 'check-only-output'
    $checkOnly = Invoke-Phase2Copier -ManifestFile $manifestPath -FinalRoot $checkOnlyRoot -CheckOnly
    Assert-Phase2True ($checkOnly.ExitCode -eq 0 -and $checkOnly.Output -match 'check passed') "Copier check-only failed: $($checkOnly.Output)"
    Assert-Phase2True (-not (Test-Path -LiteralPath $checkOnlyRoot)) 'Copier check-only created an output root.'

    $existingRoot = Join-Path $tempRoot 'existing-output'
    New-Item -ItemType Directory -Path $existingRoot | Out-Null
    $existingResult = Invoke-Phase2Copier -ManifestFile $manifestPath -FinalRoot $existingRoot -CheckOnly
    Assert-Phase2True ($existingResult.ExitCode -ne 0 -and $existingResult.Output -match 'already exists') 'Copier accepted an existing output root.'

    $invalidCases = @(
        [pscustomobject]@{
            Name = 'duplicate-destination'
            Text = New-Phase2TestManifestText -SecondDestination 'contracts/shared/ALPHA_CONTRACT.md'
            Expected = 'Duplicate Phase 2 destination'
        }
        [pscustomobject]@{
            Name = 'duplicate-staging'
            Text = New-Phase2TestManifestText -SecondPath $stagingA -SecondHash (Get-Phase2TestHash $stagingA)
            Expected = 'Duplicate staging path'
        }
        [pscustomobject]@{
            Name = 'unsafe-destination'
            Text = New-Phase2TestManifestText -FirstDestination '../escape_CONTRACT.md'
            Expected = 'Unsafe Phase 2 destination'
        }
        [pscustomobject]@{
            Name = 'wrong-hash'
            Text = New-Phase2TestManifestText -FirstHash ('0' * 64)
            Expected = 'Staging hash mismatch'
        }
        [pscustomobject]@{
            Name = 'missing-staging'
            Text = New-Phase2TestManifestText -FirstPath (Join-Path $tempRoot 'phase1\missing.md') -FirstHash ('0' * 64)
            Expected = 'Staging file not found'
        }
    )
    foreach ($case in $invalidCases) {
        $badManifest = Join-Path $tempRoot "$($case.Name).md"
        $badOutput = Join-Path $tempRoot "$($case.Name)-output"
        Write-Phase2TestManifest $badManifest $case.Text
        $badResult = Invoke-Phase2Copier -ManifestFile $badManifest -FinalRoot $badOutput -CheckOnly
        Assert-Phase2True ($badResult.ExitCode -ne 0 -and $badResult.Output -match [regex]::Escape($case.Expected)) "Copier accepted $($case.Name): $($badResult.Output)"
        Assert-Phase2True (-not (Test-Path -LiteralPath $badOutput)) "Rejected $($case.Name) created an output root."
    }

    $blockedRoot = Join-Path $tempRoot 'final-contracts-blocked'
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'blocked'
    $blockedApprovalResult = Invoke-Phase2Runner -RunId 'phase2-blocked' -FinalRoot $blockedRoot -Extra @('-ShowApproval')
    $blockedApproval = [regex]::Match($blockedApprovalResult.Output, 'APPROVE CONTRACT APPLY phase2-blocked [a-f0-9]{64}').Value
    $blocked = Invoke-Phase2Runner -RunId 'phase2-blocked' -FinalRoot $blockedRoot -Extra @('-Approval', $blockedApproval)
    Assert-Phase2True ($blocked.ExitCode -eq 2) "Phase 2 BLOCKED did not return exit code 2: $($blocked.Output)"
    Assert-Phase2True (Test-Path -LiteralPath $blockedRoot -PathType Container) 'Phase 2 BLOCKED removed the copied output tree.'
    $blockedRun = Join-Path $runsRoot 'phase2-blocked'
    Assert-Phase2True ((Get-Content -LiteralPath (Join-Path $blockedRun 'verification.md') -Raw) -match '^STATUS: BLOCKED') 'Phase 2 BLOCKED report was not retained.'
    Assert-Phase2True ((Get-Content -LiteralPath (Join-Path $blockedRun 'verification.md') -Raw) -match 'exact mismatch=deliberate blocked test scenario') 'Phase 2 BLOCKED report omitted the exact mismatch.'
    Assert-Phase2True ((Get-Content -LiteralPath (Join-Path $blockedRun 'receipt.md') -Raw) -match 'Status: BLOCKED') 'Phase 2 BLOCKED receipt was not retained.'
    Assert-Phase2True (-not (Test-Path -LiteralPath (Join-Path $blockedRun 'private'))) 'Phase 2 BLOCKED retained the private verifier directory.'
    Assert-Phase2True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes($stagingA)) -ceq
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $blockedRoot 'contracts\shared\ALPHA_CONTRACT.md')))
    ) 'Phase 2 verifier repaired or changed a blocked output.'

    $failureRoot = Join-Path $tempRoot 'final-contracts-verifier-failure'
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'fail'
    $failureApprovalResult = Invoke-Phase2Runner -RunId 'phase2-verifier-failure' -FinalRoot $failureRoot -Extra @('-ShowApproval')
    $failureApproval = [regex]::Match($failureApprovalResult.Output, 'APPROVE CONTRACT APPLY phase2-verifier-failure [a-f0-9]{64}').Value
    $failure = Invoke-Phase2Runner -RunId 'phase2-verifier-failure' -FinalRoot $failureRoot -Extra @('-Approval', $failureApproval)
    Assert-Phase2True ($failure.ExitCode -eq 1 -and $failure.Output -match 'deliberate Phase 2 verifier failure') 'Phase 2 hid or misreported a verifier failure.'
    $failureRun = Join-Path $runsRoot 'phase2-verifier-failure'
    Assert-Phase2True (Test-Path -LiteralPath $failureRoot -PathType Container) 'Verifier failure removed an already copied output tree.'
    Assert-Phase2True (Test-Path -LiteralPath (Join-Path $failureRun 'phase2-verifier.stderr.txt') -PathType Leaf) 'Verifier stderr was not retained.'
    Assert-Phase2True (Test-Path -LiteralPath (Join-Path $failureRun 'failure.txt') -PathType Leaf) 'Verifier failure evidence was not retained.'
    Assert-Phase2True (-not (Test-Path -LiteralPath (Join-Path $failureRun 'private'))) 'Verifier failure retained the private verifier directory.'

    $global:LASTEXITCODE = 0
    Write-Host 'Phase2.Tests.ps1: PASS' -ForegroundColor Green
} finally {
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_LOG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
