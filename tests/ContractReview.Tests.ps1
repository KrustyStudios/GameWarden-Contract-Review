Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'Start-ContractReview.ps1'
$fakeCli = Join-Path $PSScriptRoot 'fixtures\Fake-ReviewCli.ps1'
$fakeSplitter = Join-Path $PSScriptRoot 'fixtures\Fake-Splitter.ps1'
$pwsh = (Get-Process -Id $PID).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('contract-review-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Runner {
    param([string[]]$Extra, [string]$RunId, [string]$RunsRoot, [string]$ClaudePath = $fakeCli)
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner,
        '-RunId', $RunId,
        '-GuidePath', (Join-Path $tempRoot 'GUIDE.md'),
        '-TargetPath', (Join-Path $tempRoot 'TARGET.md'),
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
    [IO.File]::WriteAllText((Join-Path $tempRoot 'GUIDE.md'), "# Guide`nReview the complete source.`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $tempRoot 'TARGET.md'), "# Example`nalpha`nbeta`ngamma`n", [Text.UTF8Encoding]::new($false))

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

    $wrong = Invoke-Runner -RunId 'test-wrong' -RunsRoot $runsRoot -Extra @('-Approval', 'APPROVE CONTRACT REVIEW test-wrong ' + ('0' * 64))
    Assert-True ($wrong.ExitCode -ne 0) 'A wrong approval was accepted.'
    Assert-True (-not (Test-Path (Join-Path $runsRoot 'test-wrong'))) 'Wrong approval created a run directory.'

    $success = Invoke-Runner -RunId 'test-success' -RunsRoot $runsRoot -Extra @('-Approval', $approval)
    Assert-True ($success.ExitCode -eq 0) "Successful run failed: $($success.Output)"
    $run = Join-Path $runsRoot 'test-success'
    foreach ($name in @('review-a.md', 'review-b.md', 'comparison.md', 'proof-a.md', 'proof-b.md', 'final-report.md', 'stage1-manifest.tsv', 'receipt.md')) {
        Assert-True (Test-Path (Join-Path $run $name)) "Missing retained artifact: $name"
    }
    Assert-True (Test-Path (Join-Path $run 'staging\copied-source.md')) 'Staging was not materialized.'
    Assert-True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $tempRoot 'TARGET.md'))) -eq
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $run 'staging\copied-source.md')))
    ) 'Staged source bytes changed.'
    Assert-True (
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-A.prompt.md'))) -eq
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-B.prompt.md')))
    ) 'Blind reviewers did not receive byte-identical prompts.'
    foreach ($inputName in @('GUIDE.md', 'TARGET.md')) {
        Assert-True (
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot "blind-A.$inputName"))) -eq
            [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot "blind-B.$inputName")))
        ) "Blind reviewers did not receive byte-identical $inputName files."
    }
    Assert-True ((Get-Content (Join-Path $logRoot 'blind-A.prompt.md') -Raw) -notmatch 'test-success') 'Run metadata entered the blind prompt.'
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
