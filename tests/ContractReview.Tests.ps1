Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'Start-ContractReview.ps1'
$fakeCli = Join-Path $PSScriptRoot 'fixtures\Fake-ReviewCli.ps1'
$fakeSplitter = Join-Path $PSScriptRoot 'fixtures\Fake-Splitter.ps1'
$pwsh = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('contract-review-test-' + [guid]::NewGuid().ToString('N'))
$guidePath = Join-Path $tempRoot '.design\contract-epic.md'
$rulesPath = Join-Path $tempRoot 'AI_RULES.md'
$guardrailsPath = Join-Path $tempRoot 'AI_GUARDRAILS.md'
$targetPath = Join-Path $tempRoot 'contracts\lifecycle\EXAMPLE_CONTRACT.md'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Runner {
    param(
        [string[]]$Extra,
        [string]$RunId,
        [string]$RunsRoot,
        [string]$ClaudePath = $fakeCli,
        [string]$SourcePath = $targetPath
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner,
        '-RunId', $RunId,
        '-GuidePath', $guidePath,
        '-RulesPath', $rulesPath,
        '-GuardrailsPath', $guardrailsPath,
        '-TargetPath', $SourcePath,
        '-SplitterPath', $fakeSplitter,
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
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    New-Item -ItemType Directory -Path (Split-Path $guidePath), (Split-Path $targetPath) | Out-Null
    [IO.File]::WriteAllText($guidePath, "# Guide`nReview the complete source.`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($rulesPath, "# Rules`nKeep the review read-only.`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($guardrailsPath, "# Guardrails`nDo not assume required facts.`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($targetPath, "# Example`n[EXAMPLE-RULE]`nalpha`nbeta`n", [Text.UTF8Encoding]::new($false))

    $approvedInputHashes = @{}
    foreach ($inputPath in @($guidePath, $rulesPath, $guardrailsPath, $targetPath)) {
        $approvedInputHashes[$inputPath] = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
    }

    $runsRoot = Join-Path $tempRoot 'runs'
    $logRoot = Join-Path $tempRoot 'fake-log'
    New-Item -ItemType Directory -Path $logRoot | Out-Null
    $env:CONTRACT_REVIEW_FAKE_LOG_DIR = $logRoot
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'success'

    $approvalResult = Invoke-Runner -RunId 'test-success' -RunsRoot $runsRoot -Extra @('-ShowApproval')
    Assert-True ($approvalResult.ExitCode -eq 0) "Approval failed: $($approvalResult.Output)"
    $approval = [regex]::Match($approvalResult.Output, 'APPROVE CONTRACT REVIEW test-success [a-f0-9]{64}').Value
    Assert-True (-not [string]::IsNullOrWhiteSpace($approval)) 'Approval phrase was not printed.'
    Assert-True (@(Get-ChildItem -LiteralPath $logRoot -Force).Count -eq 0) 'ShowApproval launched a provider.'
    Assert-True (-not (Test-Path (Join-Path $runsRoot 'test-success'))) 'ShowApproval created a run directory.'
    $allCodexApproval = Invoke-Runner -RunId 'test-all-codex' -RunsRoot $runsRoot -ClaudePath 'missing-claude-cli' -Extra @('-AllCodex', '-ShowApproval')
    Assert-True ($allCodexApproval.ExitCode -eq 0) "All-Codex approval required Claude: $($allCodexApproval.Output)"
    Assert-True ($allCodexApproval.Output -notmatch [regex]::Escape($approval)) 'All-Codex mode was not bound into approval.'

    $alternateTarget = Join-Path $tempRoot 'contracts\alternate\EXAMPLE_CONTRACT.md'
    New-Item -ItemType Directory -Path (Split-Path $alternateTarget) | Out-Null
    [IO.File]::WriteAllBytes($alternateTarget, [IO.File]::ReadAllBytes($targetPath))
    $pathApprovalA = Invoke-Runner -RunId 'test-path-binding' -RunsRoot $runsRoot -SourcePath $targetPath -Extra @('-ShowApproval')
    $pathApprovalB = Invoke-Runner -RunId 'test-path-binding' -RunsRoot $runsRoot -SourcePath $alternateTarget -Extra @('-ShowApproval')
    Assert-True ($pathApprovalA.ExitCode -eq 0 -and $pathApprovalB.ExitCode -eq 0) 'Path-binding approvals failed.'
    Assert-True ($pathApprovalA.Output -cne $pathApprovalB.Output) 'Identical source bytes at different paths produced the same approval.'

    $wrong = Invoke-Runner -RunId 'test-wrong' -RunsRoot $runsRoot -Extra @('-Approval', 'APPROVE CONTRACT REVIEW test-wrong ' + ('0' * 64))
    Assert-True ($wrong.ExitCode -ne 0) 'A wrong approval was accepted.'
    Assert-True (-not (Test-Path (Join-Path $runsRoot 'test-wrong'))) 'Wrong approval created a run directory.'

    $success = Invoke-Runner -RunId 'test-success' -RunsRoot $runsRoot -Extra @('-Approval', $approval)
    Assert-True ($success.ExitCode -eq 0) "Successful run failed: $($success.Output)"
    $run = Join-Path $runsRoot 'test-success'
    foreach ($name in @('review-a.md', 'review-b.md', 'comparison.md', 'proof-a.md', 'proof-b.md', 'final-report.md', 'stage1-manifest.tsv', 'splitter-check.txt', 'splitter-stage.txt', 'receipt.md')) {
        Assert-True (Test-Path (Join-Path $run $name)) "Missing retained artifact: $name"
    }
    $stagedContract = Join-Path $run 'staging\contracts\lifecycle\EXAMPLE_CONTRACT.md'
    Assert-True (Test-Path $stagedContract) 'The source contract was not staged at its repository-relative path.'
    Assert-True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes($targetPath)) -eq
        [Convert]::ToHexString([IO.File]::ReadAllBytes($stagedContract))
    ) 'The splitter did not preserve the source bytes verbatim.'
    Assert-True ((Get-Content (Join-Path $run 'splitter-check.txt') -Raw) -match 'fake splitter: check passed') 'Splitter check output was not retained.'
    Assert-True ((Get-Content (Join-Path $run 'splitter-stage.txt') -Raw) -match 'fake splitter: staged') 'Splitter staging output was not retained.'
    Assert-True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-A.prompt.md'))) -eq
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-B.prompt.md')))
    ) 'Blind reviewers did not receive byte-identical prompts.'
    $blindPrompt = Get-Content (Join-Path $logRoot 'blind-A.prompt.md') -Raw
    foreach ($inputPath in @($guidePath, $rulesPath, $guardrailsPath, $targetPath)) {
        Assert-True ($blindPrompt.Contains($inputPath, [StringComparison]::Ordinal)) "Blind prompt omitted the exact input path: $inputPath"
        Assert-True ((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash -eq $approvedInputHashes[$inputPath]) "Shared input changed during review: $inputPath"
    }
    Assert-True ($blindPrompt -notmatch [regex]::Escape("# Example`n[EXAMPLE-RULE]")) 'Source contents were inlined instead of read from the shared path.'
    Assert-True ((Get-Content (Join-Path $logRoot 'blind-A.input-paths.txt') -Raw) -ceq (Get-Content (Join-Path $logRoot 'blind-B.input-paths.txt') -Raw)) 'Blind reviewers did not read the same input paths.'
    Assert-True ((Get-Content (Join-Path $logRoot 'blind-A.cwd.txt') -Raw) -cne (Get-Content (Join-Path $logRoot 'blind-B.cwd.txt') -Raw)) 'Blind reviewers shared an output directory.'
    Assert-True ($blindPrompt -notmatch 'test-success') 'Run metadata entered the blind prompt.'
    Assert-True (Test-Path (Join-Path $logRoot 'blind-A.concurrent')) 'Blind reviewer A did not observe reviewer B concurrently.'
    Assert-True (Test-Path (Join-Path $logRoot 'blind-B.concurrent')) 'Blind reviewer B did not observe reviewer A concurrently.'
    Assert-True ((Get-Content (Join-Path $run 'comparison.md') -Raw) -match 'different finding counts') 'Comparator did not report count/granularity differences.'
    Assert-True (-not (Test-Path (Join-Path $run 'private'))) 'Private review directory was retained.'

    $failureRuns = Join-Path $tempRoot 'failure-runs'
    $failureLog = Join-Path $tempRoot 'failure-log'
    New-Item -ItemType Directory -Path $failureLog | Out-Null
    $env:CONTRACT_REVIEW_FAKE_LOG_DIR = $failureLog
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'fail-a'
    $failureApprovalResult = Invoke-Runner -RunId 'test-failure' -RunsRoot $failureRuns -Extra @('-ShowApproval')
    $failureApproval = [regex]::Match($failureApprovalResult.Output, 'APPROVE CONTRACT REVIEW test-failure [a-f0-9]{64}').Value
    $failure = Invoke-Runner -RunId 'test-failure' -RunsRoot $failureRuns -Extra @('-Approval', $failureApproval)
    Assert-True ($failure.ExitCode -ne 0) 'Provider failure was reported as success.'
    Assert-True ($failure.Output -match 'deliberate reviewer failure') 'Original provider error was hidden.'
    Assert-True (-not (Test-Path (Join-Path $failureLog 'comparator.start'))) 'Comparator started after blind-review failure.'
    Assert-True (-not (Test-Path (Join-Path $failureRuns 'test-failure\private'))) 'Failure retained a private directory.'
    Assert-True (Test-Path (Join-Path $failureRuns 'test-failure\failure.txt')) 'Failure evidence was not retained.'
    $childPid = [int](Get-Content (Join-Path $failureLog 'blind-B.child-pid') -Raw)
    Start-Sleep -Milliseconds 250
    Assert-True (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Stopped peer left a child process running.'

    $global:LASTEXITCODE = 0
    Write-Host 'ContractReview.Tests.ps1: PASS' -ForegroundColor Green
} finally {
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_LOG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
