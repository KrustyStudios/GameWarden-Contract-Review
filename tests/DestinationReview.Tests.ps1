Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $repoRoot 'Start-ContractReview.ps1'
$materializer = Join-Path $repoRoot 'Materialize-Destination.ps1'
$fakeCli = Join-Path $PSScriptRoot 'fixtures\Fake-DestinationReviewCli.ps1'
$pwsh = (Get-Process -Id $PID).Path
$utf8 = [Text.UTF8Encoding]::new($false)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('destination-review-test-' + [guid]::NewGuid().ToString('N'))
$guidePath = Join-Path $tempRoot '.design\contract-epic.md'
$rulesPath = Join-Path $tempRoot 'AI_RULES.md'
$guardrailsPath = Join-Path $tempRoot 'AI_GUARDRAILS.md'
$originalSourcePath = Join-Path $tempRoot 'contracts\SOURCE_CONTRACT.md'
$incomingPath = Join-Path $tempRoot 'phase1\incoming.md'
$destinationPath = Join-Path $tempRoot 'contracts\EXAMPLE_CONTRACT.md'

function Assert-DestinationTrue {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-DestinationRunner {
    param(
        [Parameter(Mandatory = $true)][string[]]$Extra,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$RunsRoot,
        [string]$DestinationContract = $destinationPath
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $runner,
        '-DestinationReview',
        '-RunId', $RunId,
        '-GuidePath', $guidePath,
        '-RulesPath', $rulesPath,
        '-GuardrailsPath', $guardrailsPath,
        '-OriginalSourcePath', $originalSourcePath,
        '-IncomingPath', $incomingPath,
        '-DestinationPath', $DestinationContract,
        '-MaterializerPath', $materializer,
        '-RunsRoot', $RunsRoot,
        '-ClaudeCommand', $fakeCli,
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

function Invoke-DestinationMaterializer {
    param(
        [Parameter(Mandatory = $true)][string]$IncomingFile,
        [Parameter(Mandatory = $true)][string]$DestinationFile,
        [Parameter(Mandatory = $true)][string]$PacketFile,
        [Parameter(Mandatory = $true)][string]$OutputFile,
        [switch]$CheckOnly
    )
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $materializer,
        '-Incoming', $IncomingFile,
        '-Destination', $DestinationFile,
        '-Packet', $PacketFile,
        '-Output', $OutputFile
    )
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

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    New-Item -ItemType Directory -Path (Split-Path $guidePath), (Split-Path $incomingPath), (Split-Path $destinationPath) | Out-Null
    [IO.File]::WriteAllText($guidePath, "# Guide`nUse the destination manifest.`n", $utf8)
    [IO.File]::WriteAllText($rulesPath, "# Rules`nRead only shared inputs.`n", $utf8)
    [IO.File]::WriteAllText($guardrailsPath, "# Guardrails`nMaterialize mechanically.`n", $utf8)
    [IO.File]::WriteAllText($originalSourcePath, "# Original`n[ORIGINAL]`nsource evidence`n", $utf8)
    [IO.File]::WriteAllBytes($incomingPath, [Text.Encoding]::UTF8.GetBytes("[INCOMING]`r`nincoming body`n"))
    [IO.File]::WriteAllBytes($destinationPath, [Text.Encoding]::UTF8.GetBytes("# Existing`r`n[EXISTING]`r`nold body`n"))

    $originalHashes = @{}
    foreach ($path in @($guidePath, $rulesPath, $guardrailsPath, $originalSourcePath, $incomingPath, $destinationPath)) {
        $originalHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    $runsRoot = Join-Path $tempRoot 'runs'
    $logRoot = Join-Path $tempRoot 'fake-log'
    New-Item -ItemType Directory -Path $logRoot | Out-Null
    $env:CONTRACT_REVIEW_FAKE_LOG_DIR = $logRoot
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'success'

    $approvalResult = Invoke-DestinationRunner -RunId 'destination-success' -RunsRoot $runsRoot -Extra @('-ShowApproval')
    Assert-DestinationTrue ($approvalResult.ExitCode -eq 0) "Destination approval failed: $($approvalResult.Output)"
    $approval = [regex]::Match($approvalResult.Output, 'APPROVE CONTRACT REVIEW destination-success [a-f0-9]{64}').Value
    Assert-DestinationTrue (-not [string]::IsNullOrWhiteSpace($approval)) 'Destination approval phrase was not printed.'
    Assert-DestinationTrue (@(Get-ChildItem -LiteralPath $logRoot -Force).Count -eq 0) 'ShowApproval launched a destination reviewer.'
    Assert-DestinationTrue (-not (Test-Path (Join-Path $runsRoot 'destination-success'))) 'ShowApproval created a destination run directory.'

    $alternateDestination = Join-Path $tempRoot 'contracts\ALTERNATE_CONTRACT.md'
    [IO.File]::WriteAllBytes($alternateDestination, [IO.File]::ReadAllBytes($destinationPath))
    $approvalA = Invoke-DestinationRunner -RunId 'destination-path-binding' -RunsRoot $runsRoot -DestinationContract $destinationPath -Extra @('-ShowApproval')
    $approvalB = Invoke-DestinationRunner -RunId 'destination-path-binding' -RunsRoot $runsRoot -DestinationContract $alternateDestination -Extra @('-ShowApproval')
    Assert-DestinationTrue ($approvalA.ExitCode -eq 0 -and $approvalB.ExitCode -eq 0) 'Destination path-binding approvals failed.'
    Assert-DestinationTrue ($approvalA.Output -cne $approvalB.Output) 'Different destination paths produced the same approval.'

    $wrong = Invoke-DestinationRunner -RunId 'destination-wrong' -RunsRoot $runsRoot -Extra @('-Approval', 'APPROVE CONTRACT REVIEW destination-wrong ' + ('0' * 64))
    Assert-DestinationTrue ($wrong.ExitCode -ne 0) 'A wrong destination approval was accepted.'
    Assert-DestinationTrue (-not (Test-Path (Join-Path $runsRoot 'destination-wrong'))) 'Wrong destination approval created a run directory.'

    $success = Invoke-DestinationRunner -RunId 'destination-success' -RunsRoot $runsRoot -Extra @('-Approval', $approval)
    Assert-DestinationTrue ($success.ExitCode -eq 0) "Destination review failed: $($success.Output)"
    $run = Join-Path $runsRoot 'destination-success'
    foreach ($name in @('review-a.md', 'review-b.md', 'comparison.md', 'proof-a.md', 'proof-b.md', 'final-report.md', 'materializer-check.txt', 'materializer-stage.txt', 'receipt.md', 'staging\destination.md')) {
        Assert-DestinationTrue (Test-Path (Join-Path $run $name)) "Missing destination artifact: $name"
    }
    $expectedBytes = [IO.MemoryStream]::new()
    try {
        foreach ($path in @($destinationPath, $incomingPath)) {
            $bytes = [IO.File]::ReadAllBytes($path)
            $expectedBytes.Write($bytes, 0, $bytes.Length)
        }
        $expectedHex = [Convert]::ToHexString($expectedBytes.ToArray())
    } finally {
        $expectedBytes.Dispose()
    }
    $actualHex = [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $run 'staging\destination.md')))
    Assert-DestinationTrue ($actualHex -ceq $expectedHex) 'Destination staging was not an exact script copy of the approved ranges.'
    Assert-DestinationTrue ((Get-Content (Join-Path $run 'materializer-check.txt') -Raw) -match 'check-only') 'Destination check-only log was not retained.'
    Assert-DestinationTrue ((Get-Content (Join-Path $run 'materializer-stage.txt') -Raw) -match 'written') 'Destination materialization log was not retained.'
    Assert-DestinationTrue (
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-A.prompt.md'))) -eq
        [Convert]::ToHexString([IO.File]::ReadAllBytes((Join-Path $logRoot 'blind-B.prompt.md')))
    ) 'Blind destination reviewers did not receive byte-identical prompts.'
    $blindPrompt = Get-Content (Join-Path $logRoot 'blind-A.prompt.md') -Raw
    foreach ($path in @($guidePath, $rulesPath, $guardrailsPath, $originalSourcePath, $incomingPath, $destinationPath)) {
        Assert-DestinationTrue ($blindPrompt.Contains($path, [StringComparison]::Ordinal)) "Blind destination prompt omitted exact path: $path"
        Assert-DestinationTrue ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $originalHashes[$path]) "Destination input changed during review: $path"
    }
    Assert-DestinationTrue ($blindPrompt -notmatch [regex]::Escape('[INCOMING]')) 'Incoming contents were inlined instead of read from the shared path.'
    Assert-DestinationTrue ((Get-Content (Join-Path $logRoot 'blind-A.cwd.txt') -Raw) -cne (Get-Content (Join-Path $logRoot 'blind-B.cwd.txt') -Raw)) 'Blind destination reviewers shared an output directory.'
    Assert-DestinationTrue (Test-Path (Join-Path $logRoot 'blind-A.concurrent')) 'Blind destination reviewer A was not concurrent.'
    Assert-DestinationTrue (Test-Path (Join-Path $logRoot 'blind-B.concurrent')) 'Blind destination reviewer B was not concurrent.'
    Assert-DestinationTrue (-not (Test-Path (Join-Path $run 'private'))) 'Destination private directory was retained.'

    $failureRuns = Join-Path $tempRoot 'failure-runs'
    $failureLog = Join-Path $tempRoot 'failure-log'
    New-Item -ItemType Directory -Path $failureLog | Out-Null
    $env:CONTRACT_REVIEW_FAKE_LOG_DIR = $failureLog
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'fail-a'
    $failureApprovalResult = Invoke-DestinationRunner -RunId 'destination-failure' -RunsRoot $failureRuns -Extra @('-ShowApproval')
    $failureApproval = [regex]::Match($failureApprovalResult.Output, 'APPROVE CONTRACT REVIEW destination-failure [a-f0-9]{64}').Value
    $failure = Invoke-DestinationRunner -RunId 'destination-failure' -RunsRoot $failureRuns -Extra @('-Approval', $failureApproval)
    Assert-DestinationTrue ($failure.ExitCode -ne 0) 'Destination provider failure was reported as success.'
    Assert-DestinationTrue ($failure.Output -match 'deliberate destination reviewer failure') 'Original destination provider error was hidden.'
    Assert-DestinationTrue (-not (Test-Path (Join-Path $failureLog 'comparator.start'))) 'Destination comparator started after blind-review failure.'
    Assert-DestinationTrue (-not (Test-Path (Join-Path $failureRuns 'destination-failure\private'))) 'Destination failure retained a private directory.'
    $childPid = [int](Get-Content (Join-Path $failureLog 'blind-B.child-pid') -Raw)
    Assert-DestinationTrue (-not (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) 'Destination failure left a child process running.'
    $env:CONTRACT_REVIEW_FAKE_SCENARIO = 'success'

    $directRoot = Join-Path $tempRoot 'direct'
    New-Item -ItemType Directory -Path $directRoot | Out-Null
    $directIncoming = Join-Path $directRoot 'incoming.md'
    $directDestination = Join-Path $directRoot 'destination.md'
    $directPacket = Join-Path $directRoot 'packet.md'
    $directOutput = Join-Path $directRoot 'output.md'
    [IO.File]::WriteAllBytes($directIncoming, [Text.Encoding]::UTF8.GetBytes("[OLD]`r`ncopy-in`nsplit-source`r`ndelete-in`n"))
    [IO.File]::WriteAllBytes($directDestination, [Text.Encoding]::UTF8.GetBytes("dest-copy`r`ndest-delete`n"))
    $directPacketText = (@(
        'STATUS: COMPLETE'
        'BEGIN DESTINATION MANIFEST'
        "NEW`t-`t-`theader"
        "COPY`t$directDestination`t1-1"
        "DELETE`t$directDestination`t2-2`tcontracts/shared/SURVIVOR_CONTRACT.md`t[SURVIVOR]"
        "RENAME`t$directIncoming`t1-1`t[OLD]`t[NEW]"
        "COPY`t$directIncoming`t2-2"
        "SPLIT`t$directIncoming`t3-3`tsplit-body"
        "DELETE`t$directIncoming`t4-4`tcontracts/shared/SURVIVOR_CONTRACT.md`t[SURVIVOR]"
        'END DESTINATION MANIFEST'
        'BEGIN DESTINATION TEXT header'
        '# Combined'
        'END DESTINATION TEXT header'
        'BEGIN DESTINATION TEXT split-body'
        "split-a`r"
        'split-b'
        'END DESTINATION TEXT split-body'
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($directPacket, $directPacketText, $utf8)
    $check = Invoke-DestinationMaterializer -IncomingFile $directIncoming -DestinationFile $directDestination -PacketFile $directPacket -OutputFile $directOutput -CheckOnly
    Assert-DestinationTrue ($check.ExitCode -eq 0) "Direct materializer check failed: $($check.Output)"
    Assert-DestinationTrue (-not (Test-Path $directOutput)) 'Check-only materializer wrote an output file.'
    $write = Invoke-DestinationMaterializer -IncomingFile $directIncoming -DestinationFile $directDestination -PacketFile $directPacket -OutputFile $directOutput
    Assert-DestinationTrue ($write.ExitCode -eq 0) "Direct materializer write failed: $($write.Output)"
    $expectedDirect = [Text.Encoding]::UTF8.GetBytes("# Combined`ndest-copy`r`n[NEW]`r`ncopy-in`nsplit-a`r`nsplit-b`n")
    Assert-DestinationTrue (
        [Convert]::ToHexString([IO.File]::ReadAllBytes($directOutput)) -ceq [Convert]::ToHexString($expectedDirect)
    ) 'COPY/RENAME/SPLIT/DELETE/NEW did not produce the exact approved bytes.'

    $gapPacket = Join-Path $directRoot 'gap-packet.md'
    $gapOutput = Join-Path $directRoot 'gap-output.md'
    $gapText = "BEGIN DESTINATION MANIFEST`nCOPY`t$directDestination`t1-2`nCOPY`t$directIncoming`t" + "1-3`nEND DESTINATION MANIFEST`n"
    [IO.File]::WriteAllText($gapPacket, $gapText, $utf8)
    $gap = Invoke-DestinationMaterializer -IncomingFile $directIncoming -DestinationFile $directDestination -PacketFile $gapPacket -OutputFile $gapOutput -CheckOnly
    Assert-DestinationTrue ($gap.ExitCode -ne 0 -and $gap.Output -match 'not covered') 'Materializer accepted an uncovered input line.'
    Assert-DestinationTrue (-not (Test-Path $gapOutput)) 'Rejected materializer packet wrote output.'

    $badRenamePacket = Join-Path $directRoot 'bad-rename-packet.md'
    $badRenameOutput = Join-Path $directRoot 'bad-rename-output.md'
    $badRenameText = (@(
        'BEGIN DESTINATION MANIFEST'
        "COPY`t$directDestination`t1-2"
        "RENAME`t$directIncoming`t1-1`t[MISSING]`t[NEW]"
        "COPY`t$directIncoming`t2-4"
        'END DESTINATION MANIFEST'
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($badRenamePacket, $badRenameText, $utf8)
    $badRename = Invoke-DestinationMaterializer -IncomingFile $directIncoming -DestinationFile $directDestination -PacketFile $badRenamePacket -OutputFile $badRenameOutput -CheckOnly
    Assert-DestinationTrue ($badRename.ExitCode -ne 0 -and $badRename.Output -match 'exactly once') 'Materializer accepted a RENAME whose old tag was absent.'

    $unnamedDeletePacket = Join-Path $directRoot 'unnamed-delete-packet.md'
    $unnamedDeleteOutput = Join-Path $directRoot 'unnamed-delete-output.md'
    $unnamedDeleteText = (@(
        'BEGIN DESTINATION MANIFEST'
        "COPY`t$directDestination`t1-2"
        "COPY`t$directIncoming`t1-3"
        "DELETE`t$directIncoming`t4-4`tcontracts/shared/SURVIVOR_CONTRACT.md"
        'END DESTINATION MANIFEST'
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($unnamedDeletePacket, $unnamedDeleteText, $utf8)
    $unnamedDelete = Invoke-DestinationMaterializer -IncomingFile $directIncoming -DestinationFile $directDestination -PacketFile $unnamedDeletePacket -OutputFile $unnamedDeleteOutput -CheckOnly
    Assert-DestinationTrue ($unnamedDelete.ExitCode -ne 0 -and $unnamedDelete.Output -match 'requires exactly 5') 'Materializer accepted DELETE without a complete named survivor.'

    $extraBlockPacket = Join-Path $directRoot 'extra-block-packet.md'
    $extraBlockOutput = Join-Path $directRoot 'extra-block-output.md'
    $extraBlockText = (@(
        'BEGIN DESTINATION MANIFEST'
        "COPY`t$directDestination`t1-2"
        "COPY`t$directIncoming`t1-4"
        'END DESTINATION MANIFEST'
        'BEGIN DESTINATION TEXT unused'
        'unused'
        'END DESTINATION TEXT unused'
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($extraBlockPacket, $extraBlockText, $utf8)
    $extraBlock = Invoke-DestinationMaterializer -IncomingFile $directIncoming -DestinationFile $directDestination -PacketFile $extraBlockPacket -OutputFile $extraBlockOutput -CheckOnly
    Assert-DestinationTrue ($extraBlock.ExitCode -ne 0 -and $extraBlock.Output -match 'unreferenced') 'Materializer accepted an unreferenced text block.'

    $newDestination = Join-Path $directRoot 'new-contract.md'
    $newPacket = Join-Path $directRoot 'new-packet.md'
    $newOutput = Join-Path $directRoot 'new-output.md'
    $newText = (@(
        'BEGIN DESTINATION MANIFEST'
        "NEW`t-`t-`theader"
        "COPY`t$directIncoming`t1-4"
        'END DESTINATION MANIFEST'
        'BEGIN DESTINATION TEXT header'
        '# New contract'
        'END DESTINATION TEXT header'
    ) -join "`n") + "`n"
    [IO.File]::WriteAllText($newPacket, $newText, $utf8)
    $newResult = Invoke-DestinationMaterializer -IncomingFile $directIncoming -DestinationFile $newDestination -PacketFile $newPacket -OutputFile $newOutput
    Assert-DestinationTrue ($newResult.ExitCode -eq 0) "New-destination materialization failed: $($newResult.Output)"
    Assert-DestinationTrue (-not (Test-Path $newDestination)) 'Materializer created or edited the final destination.'
    $expectedNew = [Text.Encoding]::UTF8.GetBytes("# New contract`n[OLD]`r`ncopy-in`nsplit-source`r`ndelete-in`n")
    Assert-DestinationTrue (
        [Convert]::ToHexString([IO.File]::ReadAllBytes($newOutput)) -ceq [Convert]::ToHexString($expectedNew)
    ) 'New destination staging did not preserve exact approved bytes.'

    $global:LASTEXITCODE = 0
    Write-Host 'DestinationReview.Tests.ps1: PASS' -ForegroundColor Green
} finally {
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_LOG_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\CONTRACT_REVIEW_FAKE_SCENARIO -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
