Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'Start-ContractReview.ps1'
$fakeCli = Join-Path $PSScriptRoot 'fixtures\Fake-ReviewCli.ps1'
$fakeSplitter = Join-Path $PSScriptRoot 'fixtures\Fake-Splitter.ps1'
$splitterUnderTest = if ([string]::IsNullOrWhiteSpace($env:CONTRACT_REVIEW_REAL_SPLITTER)) { $fakeSplitter } else { $env:CONTRACT_REVIEW_REAL_SPLITTER }
$pwsh = (Get-Process -Id $PID).Path
$utf8 = [Text.UTF8Encoding]::new($false)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('contract-review-test-' + [guid]::NewGuid().ToString('N'))
$guidePath = Join-Path $tempRoot '.design\contract-epic.md'
$rulesPath = Join-Path $tempRoot 'AI_RULES.md'
$guardrailsPath = Join-Path $tempRoot 'AI_GUARDRAILS.md'
$targetPath = Join-Path $tempRoot 'contracts\lifecycle\EXAMPLE_CONTRACT.md'
$stagingRoot = Join-Path $tempRoot 'staged-contracts'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-Runner {
    param(
        [string[]]$Extra,
        [string]$RunId,
        [string]$RunsRoot,
        [string]$ClaudePath = $fakeCli,
        [string]$SourcePath = $targetPath,
        [string]$StagePath = $stagingRoot
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner,
        '-RunId', $RunId,
        '-GuidePath', $guidePath,
        '-RulesPath', $rulesPath,
        '-GuardrailsPath', $guardrailsPath,
        '-TargetPath', $SourcePath,
        '-StagingRoot', $StagePath,
        '-SplitterPath', $splitterUnderTest,
        '-RunsRoot', $RunsRoot,
        '-ClaudeCommand', $ClaudePath,
        '-CodexCommand', $fakeCli,
        '-RoleTimeoutSeconds', '12'
    ) + $Extra
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $pwsh @arguments 2>&1)
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    } finally { $ErrorActionPreference = $oldPreference }
}

function Get-Approval([string]$RunId, [string]$RunsRoot, [string]$StagePath = $stagingRoot) {
    $result = Invoke-Runner -RunId $RunId -RunsRoot $RunsRoot -StagePath $StagePath -Extra @('-ShowApproval')
    Assert-True ($result.ExitCode -eq 0) "Approval failed: $($result.Output)"
    $phrase = [regex]::Match($result.Output, "APPROVE CONTRACT REVIEW $RunId [a-f0-9]{64}").Value
    Assert-True (-not [string]::IsNullOrWhiteSpace($phrase)) 'Approval phrase was not printed.'
    return $phrase
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    New-Item -ItemType Directory -Path (Split-Path $guidePath), (Split-Path $targetPath), $stagingRoot | Out-Null
    [IO.File]::WriteAllText($guidePath, "# Guide`nUse private placement coordinates and generated reviews.`n", $utf8)
    [IO.File]::WriteAllText($rulesPath, "# Rules`nKeep the original read-only.`n", $utf8)
    [IO.File]::WriteAllText($guardrailsPath, "# Guardrails`nCopy rules mechanically.`n", $utf8)
    [IO.File]::WriteAllText($targetPath, "# Example`n[EXAMPLE-RULE]`nalpha`nbeta`n", $utf8)
    $sourceHash = (Get-FileHash $targetPath).Hash

    $runsRoot = Join-Path $tempRoot 'runs'
    $logRoot = Join-Path $tempRoot 'fake-log'
    New-Item -ItemType Directory -Path $logRoot | Out-Null
    $env:CONTRACT_REVIEW_FAKE_LOG_DIR = $logRoot
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'success'

    $approval = Get-Approval 'test-success' $runsRoot
    Assert-True (@(Get-ChildItem -LiteralPath $logRoot -Force).Count -eq 0) 'ShowApproval launched a provider.'
    Assert-True (-not (Test-Path (Join-Path $runsRoot 'test-success'))) 'ShowApproval created a run directory.'
    $allCodex = Invoke-Runner -RunId 'test-all-codex' -RunsRoot $runsRoot -ClaudePath 'missing-claude-cli' -Extra @('-AllCodex', '-ShowApproval')
    Assert-True ($allCodex.ExitCode -eq 0) "All-Codex approval required Claude: $($allCodex.Output)"
    Assert-True ($allCodex.Output -cne $approval) 'Provider mode was not bound into approval.'

    $otherStaging = Join-Path $tempRoot 'other-staged-contracts'
    New-Item -ItemType Directory -Path $otherStaging | Out-Null
    $stageApprovalA = Invoke-Runner -RunId 'test-stage-binding' -RunsRoot $runsRoot -StagePath $stagingRoot -Extra @('-ShowApproval')
    $stageApprovalB = Invoke-Runner -RunId 'test-stage-binding' -RunsRoot $runsRoot -StagePath $otherStaging -Extra @('-ShowApproval')
    Assert-True ($stageApprovalA.Output -cne $stageApprovalB.Output) 'Different staging paths produced the same approval.'
    [IO.File]::WriteAllText((Join-Path $otherStaging 'existing.md'), 'existing', $utf8)
    $stageApprovalC = Invoke-Runner -RunId 'test-stage-binding' -RunsRoot $runsRoot -StagePath $otherStaging -Extra @('-ShowApproval')
    Assert-True ($stageApprovalB.Output -cne $stageApprovalC.Output) 'A changed staging snapshot produced the same approval.'

    $wrong = Invoke-Runner -RunId 'test-wrong' -RunsRoot $runsRoot -Extra @('-Approval', 'APPROVE CONTRACT REVIEW test-wrong ' + ('0' * 64))
    Assert-True ($wrong.ExitCode -ne 0) 'A wrong approval was accepted.'
    Assert-True (-not (Test-Path (Join-Path $runsRoot 'test-wrong'))) 'Wrong approval created a run directory.'

    $success = Invoke-Runner -RunId 'test-success' -RunsRoot $runsRoot -Extra @('-Approval', $approval)
    Assert-True ($success.ExitCode -eq 0) "Successful run failed: $($success.Output)"
    $run = Join-Path $runsRoot 'test-success'
    foreach ($name in @('review-a.md', 'review-b.md', 'comparison.md', 'proof-a.md', 'proof-b.md', 'final-review.md', 'staging-verification.md', 'splitter-check-a.txt', 'splitter-check-b.txt', 'splitter-check-final.txt', 'splitter-stage-final.txt', 'receipt.md')) {
        Assert-True (Test-Path (Join-Path $run $name)) "Missing retained artifact: $name"
    }
    foreach ($forbidden in @('stage1-manifest.tsv', 'stage1-INDEX.md', 'final-report.md', 'private')) {
        Assert-True (-not (Test-Path (Join-Path $run $forbidden))) "Private or obsolete artifact was retained: $forbidden"
    }
    $stagedContract = Join-Path $stagingRoot 'contracts\lifecycle\EXAMPLE_CONTRACT.md'
    Assert-True (Test-Path $stagedContract -PathType Leaf) 'The final grouped result was not added to the staging tree.'
    Assert-True ((Get-Content $stagedContract -Raw) -match '\[example\]') 'The script did not apply the final tag.'
    Assert-True ((Get-FileHash $targetPath).Hash -eq $sourceHash) 'The original contract changed.'
    Assert-True ((Get-Content (Join-Path $run 'receipt.md') -Raw) -match 'contracts/lifecycle/EXAMPLE_CONTRACT\.md.*[a-f0-9]{64}') 'Receipt omitted the staged contract hash.'
    foreach ($name in @('review-a.md', 'review-b.md', 'final-review.md')) {
        $visible = Get-Content (Join-Path $run $name) -Raw
        Assert-True ($visible -match '## contracts/lifecycle/EXAMPLE_CONTRACT\.md') "$name is not grouped by destination."
        Assert-True ($visible -notmatch '(?im)^Source:|source-sha|\blines?\s+\d|BEGIN PLACEMENT MANIFEST') "$name leaked private coordinates."
    }
    Assert-True ([regex]::Matches((Get-Content (Join-Path $run 'review-a.md') -Raw), '```text').Count -eq 1) 'Reviewer A grouping was not rendered.'
    Assert-True ([regex]::Matches((Get-Content (Join-Path $run 'review-b.md') -Raw), '```text').Count -eq 2) 'Reviewer B grouping was not rendered.'
    Assert-True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-A.prompt.md'))) -eq
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-B.prompt.md')))
    ) 'Blind reviewers did not receive byte-identical prompts.'
    $blindPrompt = Get-Content (Join-Path $logRoot 'blind-A.prompt.md') -Raw
    Assert-True ($blindPrompt -match 'first line must\s+begin with STATUS:') 'Blind prompt did not require a raw first-line status.'
    Assert-True ($blindPrompt -match 'Do not wrap the response in a Markdown code fence') 'Blind prompt allowed an outer Markdown fence.'
    foreach ($inputPath in @($guidePath, $rulesPath, $guardrailsPath, $targetPath, $stagingRoot)) {
        Assert-True ($blindPrompt.Contains($inputPath, [StringComparison]::Ordinal)) "Blind prompt omitted the exact input path: $inputPath"
    }
    Assert-True ($blindPrompt -notmatch [regex]::Escape("# Example`n[EXAMPLE-RULE]")) 'Source contents were inlined instead of read from the shared path.'
    Assert-True ((Get-Content (Join-Path $logRoot 'blind-A.input-paths.txt') -Raw) -ceq (Get-Content (Join-Path $logRoot 'blind-B.input-paths.txt') -Raw)) 'Blind reviewers did not read the same shared paths.'
    Assert-True ((Get-Content (Join-Path $logRoot 'blind-A.cwd.txt') -Raw) -cne (Get-Content (Join-Path $logRoot 'blind-B.cwd.txt') -Raw)) 'Blind reviewers shared a working directory.'
    Assert-True ($blindPrompt -notmatch 'test-success') 'Run metadata entered the blind prompt.'
    Assert-True (Test-Path (Join-Path $logRoot 'blind-A.concurrent')) 'Blind reviewer A did not run concurrently.'
    Assert-True (Test-Path (Join-Path $logRoot 'blind-B.concurrent')) 'Blind reviewer B did not run concurrently.'
    $comparatorPrompt = Get-Content (Join-Path $logRoot 'comparator.prompt.md') -Raw
    Assert-True ($comparatorPrompt -notmatch 'BEGIN PLACEMENT MANIFEST|\b1-\d+\t') 'Comparator received a private manifest.'
    $verifierPrompt = Get-Content (Join-Path $logRoot 'verifier.prompt.md') -Raw
    Assert-True ($verifierPrompt.Contains((Join-Path $run 'final-review.md'), [StringComparison]::Ordinal)) 'Verifier did not receive the final generated review path.'
    Assert-True ($verifierPrompt.Contains($stagingRoot, [StringComparison]::Ordinal)) 'Verifier did not receive the staging tree path.'

    $failureRuns = Join-Path $tempRoot 'failure-runs'
    $failureLog = Join-Path $tempRoot 'failure-log'
    New-Item -ItemType Directory -Path $failureLog | Out-Null
    $env:CONTRACT_REVIEW_FAKE_LOG_DIR = $failureLog
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'fail-a'
    $failureApproval = Get-Approval 'test-failure' $failureRuns
    $failure = Invoke-Runner -RunId 'test-failure' -RunsRoot $failureRuns -Extra @('-Approval', $failureApproval)
    Assert-True ($failure.ExitCode -ne 0 -and $failure.Output -match 'deliberate reviewer failure') 'Original reviewer failure was hidden.'
    Assert-True (-not (Test-Path (Join-Path $failureLog 'comparator.start'))) 'Comparator started after blind-review failure.'
    Assert-True (-not (Test-Path (Join-Path $failureRuns 'test-failure\private'))) 'Failure retained a private directory.'
    $childPid = [int](Get-Content (Join-Path $failureLog 'blind-B.child-pid') -Raw)
    Assert-True (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Stopped peer left a child process running.'

    $global:LASTEXITCODE = 0
    Write-Host 'ContractReview.Tests.ps1: PASS' -ForegroundColor Green
} finally {
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_LOG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

& (Join-Path $PSScriptRoot 'Phase2.Tests.ps1')
