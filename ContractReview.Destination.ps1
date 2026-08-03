# Destination-review mode for Start-ContractReview.ps1.
# This file is dot-sourced only when -DestinationReview is selected. It reuses
# the watcher's proven process lifecycle helpers without changing source review.

function Resolve-DestinationContractPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $fullPath) {
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw "Destination is not a file: $fullPath"
        }
        return [pscustomobject]@{
            Path = (Resolve-Path -LiteralPath $fullPath).Path
            Exists = $true
        }
    }
    [pscustomobject]@{ Path = $fullPath; Exists = $false }
}

function Get-DestinationReviewApprovalPhrase {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$RunIdentifier,
        [Parameter(Mandatory = $true)][bool]$UseAllCodex,
        [Parameter(Mandatory = $true)][string]$ClaudeModelName,
        [Parameter(Mandatory = $true)][string]$CodexModelName,
        [Parameter(Mandatory = $true)][string]$CodexEffort,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $mode = if ($UseAllCodex) { 'all-codex' } else { 'claude-codex' }
    $lines = @(
        "run=$RunIdentifier"
        'review=destination'
        "guide-path=$($State.GuidePath)"
        "guide-hash=$($State.GuideHash)"
        "rules-path=$($State.RulesPath)"
        "rules-hash=$($State.RulesHash)"
        "guardrails-path=$($State.GuardrailsPath)"
        "guardrails-hash=$($State.GuardrailsHash)"
        "original-source-path=$($State.OriginalSourcePath)"
        "original-source-hash=$($State.OriginalSourceHash)"
        "incoming-path=$($State.IncomingPath)"
        "incoming-hash=$($State.IncomingHash)"
        "destination-path=$($State.DestinationPath)"
        "destination-state=$($State.DestinationState)"
        "destination-hash=$($State.DestinationHash)"
        "watcher-path=$($State.WatcherPath)"
        "watcher-hash=$($State.WatcherHash)"
        "module-path=$($State.ModulePath)"
        "module-hash=$($State.ModuleHash)"
        "materializer-path=$($State.MaterializerPath)"
        "materializer-hash=$($State.MaterializerHash)"
        "mode=$mode"
        "claude-model=$ClaudeModelName"
        "codex-model=$CodexModelName"
        "codex-effort=$CodexEffort"
        "timeout=$TimeoutSeconds"
        "claude-command=$($State.ClaudeCommand)"
        "claude-command-hash=$($State.ClaudeCommandHash)"
        "codex-command=$($State.CodexCommand)"
        "codex-command-hash=$($State.CodexCommandHash)"
    )
    $hash = Get-BytesHash ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n"))
    "APPROVE CONTRACT REVIEW $RunIdentifier $hash"
}

function New-DestinationReviewPrompt {
    param(
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [string]$Material = ''
    )

    $destinationInstruction = if ($State.DestinationState -eq 'EXISTING') {
        'The destination exists. Read it in full.'
    } else {
        'The destination does not exist yet. Treat its exact path as the proposed new contract; do not try to read it.'
    }
    @"
ROLE: $Role

Read each existing exact input path below in full. Use only those files and the role
material in this prompt. Use tools only to read the listed existing files. Do not change
an input or inspect other files. Return only the Markdown report required for this role.

GUIDE PATH: $($State.GuidePath)
RULES PATH: $($State.RulesPath)
GUARDRAILS PATH: $($State.GuardrailsPath)
ORIGINAL SOURCE CONTRACT PATH: $($State.OriginalSourcePath)
INCOMING WORKING FILE PATH: $($State.IncomingPath)
DESTINATION CONTRACT PATH: $($State.DestinationPath)
DESTINATION STATE: $($State.DestinationState)

$destinationInstruction

===== ROLE MATERIAL =====
$Material
===== END INPUT =====
"@
}

function Assert-DestinationReviewInputsUnchanged {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    foreach ($input in @(
        @{ Label = 'Guide'; Path = $State.GuidePath; Hash = $State.GuideHash }
        @{ Label = 'Rules'; Path = $State.RulesPath; Hash = $State.RulesHash }
        @{ Label = 'Guardrails'; Path = $State.GuardrailsPath; Hash = $State.GuardrailsHash }
        @{ Label = 'Original source'; Path = $State.OriginalSourcePath; Hash = $State.OriginalSourceHash }
        @{ Label = 'Incoming'; Path = $State.IncomingPath; Hash = $State.IncomingHash }
        @{ Label = 'Watcher'; Path = $State.WatcherPath; Hash = $State.WatcherHash }
        @{ Label = 'Destination module'; Path = $State.ModulePath; Hash = $State.ModuleHash }
        @{ Label = 'Materializer'; Path = $State.MaterializerPath; Hash = $State.MaterializerHash }
    )) {
        if ((Get-FileHashValue $input.Path) -ne $input.Hash) {
            throw "$($input.Label) changed during review: $($input.Path)"
        }
    }
    if ((Get-FileHashValue $State.CodexCommand) -ne $State.CodexCommandHash) {
        throw "Codex CLI changed during review: $($State.CodexCommand)"
    }
    if ($State.ClaudeCommand -ne 'not-used' -and
        (Get-FileHashValue $State.ClaudeCommand) -ne $State.ClaudeCommandHash) {
        throw "Claude CLI changed during review: $($State.ClaudeCommand)"
    }

    if ($State.DestinationState -eq 'EXISTING') {
        if (-not (Test-Path -LiteralPath $State.DestinationPath -PathType Leaf) -or
            (Get-FileHashValue $State.DestinationPath) -ne $State.DestinationHash) {
            throw "Destination changed during review: $($State.DestinationPath)"
        }
    } elseif (Test-Path -LiteralPath $State.DestinationPath) {
        throw "New destination appeared during review: $($State.DestinationPath)"
    }
}

function Invoke-DestinationReviewOneRole {
    param(
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $true)][string]$Slot,
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string]$ClaudeCli,
        [Parameter(Mandatory = $true)][string]$CodexCli,
        [Parameter(Mandatory = $true)][string[]]$InputDirectories,
        [Parameter(Mandatory = $true)][Collections.Generic.List[Diagnostics.Process]]$Processes,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $role = Start-RoleProcess $Provider $Slot $Directory $Prompt $ClaudeCli $CodexCli $InputDirectories $Processes
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $role.Process.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) {
            Stop-RoleProcess $role
            throw "$Slot timed out after $TimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds 100
    }
    $result = Complete-RoleProcess $role $RunDirectory @('OK', 'BLOCKED', 'COMPLETE', 'USER_DECISION_REQUIRED')
    if ($result.Status -eq 'BLOCKED') {
        Write-AtomicText (Join-Path $RunDirectory "$Slot.blocked.md") $result.Report
        throw "$Slot reported STATUS: BLOCKED."
    }
    $result
}

function Write-DestinationReviewReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$RunIdentifier,
        [Parameter(Mandatory = $true)][bool]$UseAllCodex,
        [Parameter(Mandatory = $true)][string]$ClaudeModelName,
        [Parameter(Mandatory = $true)][string]$CodexModelName,
        [Parameter(Mandatory = $true)][string]$CodexEffort
    )

    $artifactLines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $RunDirectory -Recurse -File | Where-Object Name -ne 'receipt.md' | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($RunDirectory, $file.FullName).Replace('\', '/')
        $artifactLines += ('- `{0}` — `{1}`' -f $relative, (Get-FileHashValue $file.FullName))
    }
    $mode = if ($UseAllCodex) { 'all-codex' } else { 'claude-codex' }
    $text = @"
# Contract destination-review receipt

- Run: $RunIdentifier
- Status: $Status
- Guide: $($State.GuidePath) — $($State.GuideHash)
- Rules: $($State.RulesPath) — $($State.RulesHash)
- Guardrails: $($State.GuardrailsPath) — $($State.GuardrailsHash)
- Original source: $($State.OriginalSourcePath) — $($State.OriginalSourceHash)
- Incoming: $($State.IncomingPath) — $($State.IncomingHash)
- Destination: $($State.DestinationPath) — $($State.DestinationState) — $($State.DestinationHash)
- Watcher: $($State.WatcherPath) — $($State.WatcherHash)
- Destination module: $($State.ModulePath) — $($State.ModuleHash)
- Materializer: $($State.MaterializerPath) — $($State.MaterializerHash)
- Mode: $mode
- Claude model: $ClaudeModelName
- Codex model: $CodexModelName ($CodexEffort)
- Claude CLI: $($State.ClaudeCommand) — $($State.ClaudeCommandHash)
- Codex CLI: $($State.CodexCommand) — $($State.CodexCommandHash)

## Retained artifacts

$($artifactLines -join "`n")
"@
    Write-AtomicText (Join-Path $RunDirectory 'receipt.md') ($text.TrimEnd() + "`n")
}

function Invoke-ContractDestinationReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunIdentifier,
        [Parameter(Mandatory = $true)][string]$Guide,
        [Parameter(Mandatory = $true)][string]$Rules,
        [Parameter(Mandatory = $true)][string]$Guardrails,
        [Parameter(Mandatory = $true)][string]$OriginalSource,
        [Parameter(Mandatory = $true)][string]$Incoming,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Materializer,
        [string]$ApprovalPhrase,
        [switch]$PrintApproval,
        [switch]$UseAllCodex,
        [Parameter(Mandatory = $true)][string]$ClaudeCliCommand,
        [Parameter(Mandatory = $true)][string]$CodexCliCommand,
        [Parameter(Mandatory = $true)][string]$RunsDirectory,
        [Parameter(Mandatory = $true)][string]$WatcherPath,
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[Diagnostics.Process]]$Processes
    )

    $guidePath = Resolve-LeafPath $Guide 'Guide'
    $rulesPath = Resolve-LeafPath $Rules 'Rules'
    $guardrailsPath = Resolve-LeafPath $Guardrails 'Guardrails'
    $originalSourcePath = Resolve-LeafPath $OriginalSource 'Original source contract'
    $incomingPath = Resolve-LeafPath $Incoming 'Incoming working file'
    $destinationInfo = Resolve-DestinationContractPath $Destination
    $materializerFile = Resolve-LeafPath $Materializer 'Destination materializer'
    $watcherFile = Resolve-LeafPath $WatcherPath 'Watcher'
    $moduleFile = Resolve-LeafPath $ModulePath 'Destination module'
    if ($incomingPath.Equals($destinationInfo.Path, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Incoming working file and destination must be different paths.'
    }

    $codexCli = Resolve-CommandPath $CodexCliCommand 'Codex'
    $claudeCli = if ($UseAllCodex) { $codexCli } else { Resolve-CommandPath $ClaudeCliCommand 'Claude' }
    $state = @{
        GuidePath = $guidePath
        RulesPath = $rulesPath
        GuardrailsPath = $guardrailsPath
        OriginalSourcePath = $originalSourcePath
        IncomingPath = $incomingPath
        DestinationPath = $destinationInfo.Path
        DestinationState = if ($destinationInfo.Exists) { 'EXISTING' } else { 'NEW' }
        MaterializerPath = $materializerFile
        WatcherPath = $watcherFile
        ModulePath = $moduleFile
        GuideHash = Get-FileHashValue $guidePath
        RulesHash = Get-FileHashValue $rulesPath
        GuardrailsHash = Get-FileHashValue $guardrailsPath
        OriginalSourceHash = Get-FileHashValue $originalSourcePath
        IncomingHash = Get-FileHashValue $incomingPath
        DestinationHash = if ($destinationInfo.Exists) { Get-FileHashValue $destinationInfo.Path } else { 'missing' }
        MaterializerHash = Get-FileHashValue $materializerFile
        WatcherHash = Get-FileHashValue $watcherFile
        ModuleHash = Get-FileHashValue $moduleFile
        ClaudeCommand = if ($UseAllCodex) { 'not-used' } else { $claudeCli }
        ClaudeCommandHash = if ($UseAllCodex) { 'not-used' } else { Get-FileHashValue $claudeCli }
        CodexCommand = $codexCli
        CodexCommandHash = Get-FileHashValue $codexCli
    }
    $expectedApproval = Get-DestinationReviewApprovalPhrase `
        -State $state `
        -RunIdentifier $RunIdentifier `
        -UseAllCodex $UseAllCodex.IsPresent `
        -ClaudeModelName $ClaudeModel `
        -CodexModelName $CodexModel `
        -CodexEffort $CodexReasoningEffort `
        -TimeoutSeconds $RoleTimeoutSeconds
    if ($PrintApproval) {
        return [pscustomobject]@{ ExitCode = 0; Output = $expectedApproval }
    }
    if ($ApprovalPhrase -cne $expectedApproval) {
        throw 'Approval mismatch. Run with -ShowApproval and use the exact printed phrase.'
    }

    $runDirectory = Join-Path ([IO.Path]::GetFullPath($RunsDirectory)) $RunIdentifier
    if (Test-Path -LiteralPath $runDirectory) { throw "Run directory already exists: $runDirectory" }
    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $privateRoot = Join-Path $runDirectory 'private'
    New-Item -ItemType Directory -Path $privateRoot | Out-Null
    $status = 'FAILED'
    $failure = $null

    $inputPaths = @($guidePath, $rulesPath, $guardrailsPath, $originalSourcePath, $incomingPath)
    if ($destinationInfo.Exists) { $inputPaths += $destinationInfo.Path }
    $inputDirectories = @($inputPaths | ForEach-Object { Split-Path -Parent $_ } | Sort-Object -Unique)
    try {
        $blindPrompt = New-DestinationReviewPrompt 'BLIND DESTINATION REVIEWER' $state
        $blindA = New-RoleDirectory $privateRoot 'blind-a'
        $blindB = New-RoleDirectory $privateRoot 'blind-b'
        $providerA = if ($UseAllCodex) { 'codex' } else { 'claude' }
        Write-Host "Starting blind destination reviewers concurrently ($providerA + codex)..."
        $roleA = Start-RoleProcess $providerA 'blind-A' $blindA $blindPrompt $claudeCli $codexCli $inputDirectories $Processes
        $roleB = Start-RoleProcess 'codex' 'blind-B' $blindB $blindPrompt $claudeCli $codexCli $inputDirectories $Processes
        $blindResults = Wait-ParallelRoles $roleA $roleB $runDirectory @('OK', 'BLOCKED')
        Assert-DestinationReviewInputsUnchanged $state
        Write-AtomicText (Join-Path $runDirectory 'review-a.md') $blindResults[0].Report
        Write-AtomicText (Join-Path $runDirectory 'review-b.md') $blindResults[1].Report

        Write-Host 'Starting Codex destination comparator...'
        $comparisonMaterial = "===== REVIEW A =====`n$($blindResults[0].Report)===== REVIEW B =====`n$($blindResults[1].Report)"
        $comparisonPrompt = New-DestinationReviewPrompt 'DESTINATION COMPARATOR' $state $comparisonMaterial
        $comparisonDir = New-RoleDirectory $privateRoot 'comparator'
        $comparison = Invoke-DestinationReviewOneRole 'codex' 'comparator' $comparisonDir $comparisonPrompt $claudeCli $codexCli $inputDirectories $Processes $runDirectory $RoleTimeoutSeconds
        Assert-DestinationReviewInputsUnchanged $state
        if ($comparison.Status -ne 'OK') { throw "Comparator returned unexpected status: $($comparison.Status)" }
        Write-AtomicText (Join-Path $runDirectory 'comparison.md') $comparison.Report
        $proofMatch = [regex]::Match($comparison.Report, '(?s)BEGIN PROOF REQUESTS\s*(.*?)\s*END PROOF REQUESTS')
        if (-not $proofMatch.Success) { throw 'Comparator omitted the proof-request markers.' }
        $proofRequests = $proofMatch.Groups[1].Value.Trim()

        if ($proofRequests -eq 'NONE') {
            $proofAReport = "STATUS: OK`n# Proof response`nNONE`n"
            $proofBReport = $proofAReport
        } else {
            Write-Host 'Starting destination proof reviewers concurrently...'
            $proofPromptA = New-DestinationReviewPrompt 'DESTINATION PROOF REVIEWER A' $state "===== OWN REVIEW (SIDE A) =====`n$($blindResults[0].Report)===== PROOF REQUESTS =====`n$proofRequests"
            $proofPromptB = New-DestinationReviewPrompt 'DESTINATION PROOF REVIEWER B' $state "===== OWN REVIEW (SIDE B) =====`n$($blindResults[1].Report)===== PROOF REQUESTS =====`n$proofRequests"
            $proofDirA = New-RoleDirectory $privateRoot 'proof-a'
            $proofDirB = New-RoleDirectory $privateRoot 'proof-b'
            $proofRoleA = Start-RoleProcess $providerA 'proof-A' $proofDirA $proofPromptA $claudeCli $codexCli $inputDirectories $Processes
            $proofRoleB = Start-RoleProcess 'codex' 'proof-B' $proofDirB $proofPromptB $claudeCli $codexCli $inputDirectories $Processes
            $proofResults = Wait-ParallelRoles $proofRoleA $proofRoleB $runDirectory @('OK', 'BLOCKED')
            Assert-DestinationReviewInputsUnchanged $state
            $proofAReport = $proofResults[0].Report
            $proofBReport = $proofResults[1].Report
        }
        Write-AtomicText (Join-Path $runDirectory 'proof-a.md') $proofAReport
        Write-AtomicText (Join-Path $runDirectory 'proof-b.md') $proofBReport

        Write-Host 'Starting Codex destination validator...'
        $validationMaterial = "===== REVIEW A =====`n$($blindResults[0].Report)===== REVIEW B =====`n$($blindResults[1].Report)===== COMPARISON =====`n$($comparison.Report)===== PROOF A =====`n$proofAReport===== PROOF B =====`n$proofBReport"
        $validationPrompt = New-DestinationReviewPrompt 'FINAL DESTINATION VALIDATOR' $state $validationMaterial
        $validationDir = New-RoleDirectory $privateRoot 'validator'
        $validation = Invoke-DestinationReviewOneRole 'codex' 'validator' $validationDir $validationPrompt $claudeCli $codexCli $inputDirectories $Processes $runDirectory $RoleTimeoutSeconds
        Assert-DestinationReviewInputsUnchanged $state
        $finalReportPath = Join-Path $runDirectory 'final-report.md'
        Write-AtomicText $finalReportPath $validation.Report
        if ($validation.Status -eq 'USER_DECISION_REQUIRED') {
            $status = $validation.Status
        } elseif ($validation.Status -eq 'COMPLETE') {
            if (-not [regex]::IsMatch($validation.Report, '(?m)^BEGIN DESTINATION MANIFEST\s*$') -or
                -not [regex]::IsMatch($validation.Report, '(?m)^END DESTINATION MANIFEST\s*$')) {
                throw 'Final validator omitted the destination manifest.'
            }
            $stagedPath = Join-Path $runDirectory 'staging\destination.md'
            Assert-DestinationReviewInputsUnchanged $state
            $checkLog = @(& $materializerFile -Incoming $incomingPath -Destination $destinationInfo.Path -Packet $finalReportPath -Output $stagedPath -CheckOnly 6>&1 2>&1)
            Write-AtomicText (Join-Path $runDirectory 'materializer-check.txt') (($checkLog -join "`n").TrimEnd() + "`n")
            Assert-DestinationReviewInputsUnchanged $state
            $stageLog = @(& $materializerFile -Incoming $incomingPath -Destination $destinationInfo.Path -Packet $finalReportPath -Output $stagedPath 6>&1 2>&1)
            Write-AtomicText (Join-Path $runDirectory 'materializer-stage.txt') (($stageLog -join "`n").TrimEnd() + "`n")
            $status = 'COMPLETE'
        } else {
            throw "Final validator returned unexpected status: $($validation.Status)"
        }
    } catch {
        $failure = $_.Exception.Message
        Write-AtomicText (Join-Path $runDirectory 'failure.txt') ($failure.TrimEnd() + "`n")
    } finally {
        foreach ($process in $Processes) {
            if (-not $process.HasExited) {
                try {
                    $process.Kill($true)
                    [void]$process.WaitForExit(5000)
                } catch {
                    $failure = (($failure, "Cleanup failed: $($_.Exception.Message)" | Where-Object { $_ }) -join "`n")
                    $status = 'FAILED'
                }
            }
            $process.Dispose()
        }
        try { Remove-PrivateDirectory $privateRoot }
        catch {
            $failure = (($failure, "Cleanup failed: $($_.Exception.Message)" | Where-Object { $_ }) -join "`n")
            $status = 'FAILED'
        }
        try { Assert-DestinationReviewInputsUnchanged $state }
        catch {
            $failure = (($failure, $_.Exception.Message | Where-Object { $_ }) -join "`n")
            $status = 'FAILED'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($failure)) {
        $status = 'FAILED'
        Write-AtomicText (Join-Path $runDirectory 'failure.txt') ($failure.TrimEnd() + "`n")
    }
    Write-DestinationReviewReceipt $status $runDirectory $state $RunIdentifier $UseAllCodex.IsPresent $ClaudeModel $CodexModel $CodexReasoningEffort
    if ($status -eq 'FAILED') { [Console]::Error.WriteLine($failure) }
    $exitCode = if ($status -eq 'COMPLETE') { 0 } elseif ($status -eq 'USER_DECISION_REQUIRED') { 2 } else { 1 }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $runDirectory }
}
