# Phase 2 exact-copy and verification mode for Start-ContractReview.ps1.
# This file is dot-sourced only when -Phase2 is selected. Phase 1 remains unchanged.

function Test-Phase2PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Child,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $parentPrefix = $Parent.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $Child.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-Phase2ApprovalPhrase {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$RunIdentifier,
        [Parameter(Mandatory = $true)][string]$CodexModelName,
        [Parameter(Mandatory = $true)][string]$CodexEffort,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in @(
        "run=$RunIdentifier"
        'mode=phase2-exact-copy'
        "guide-path=$($State.GuidePath)"
        "guide-hash=$($State.GuideHash)"
        "rules-path=$($State.RulesPath)"
        "rules-hash=$($State.RulesHash)"
        "guardrails-path=$($State.GuardrailsPath)"
        "guardrails-hash=$($State.GuardrailsHash)"
        "manifest-path=$($State.ManifestPath)"
        "manifest-hash=$($State.ManifestHash)"
        "output-root=$($State.OutputRoot)"
        'output-state=missing'
        "runs-root=$($State.RunsRoot)"
        "watcher-path=$($State.WatcherPath)"
        "watcher-hash=$($State.WatcherHash)"
        "module-path=$($State.ModulePath)"
        "module-hash=$($State.ModuleHash)"
        "copier-path=$($State.CopierPath)"
        "copier-hash=$($State.CopierHash)"
        "codex-model=$CodexModelName"
        "codex-effort=$CodexEffort"
        "timeout=$TimeoutSeconds"
        "codex-command=$($State.CodexCommand)"
        "codex-command-hash=$($State.CodexCommandHash)"
    )) { $lines.Add($line) }
    foreach ($row in $State.Plan.Rows) {
        $lines.Add("copy-$($row.Number)=$($row.StagingPath)`t$($row.Destination)`t$($row.Hash)")
    }
    $hash = Get-BytesHash ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n"))
    "APPROVE CONTRACT APPLY $RunIdentifier $hash"
}

function Assert-Phase2InputsUnchanged {
    param(
        [Parameter(Mandatory = $true)][hashtable]$State,
        [switch]$RequireMissingOutput
    )

    foreach ($input in @(
        @{ Label = 'Guide'; Path = $State.GuidePath; Hash = $State.GuideHash }
        @{ Label = 'Rules'; Path = $State.RulesPath; Hash = $State.RulesHash }
        @{ Label = 'Guardrails'; Path = $State.GuardrailsPath; Hash = $State.GuardrailsHash }
        @{ Label = 'Phase 2 manifest'; Path = $State.ManifestPath; Hash = $State.ManifestHash }
        @{ Label = 'Watcher'; Path = $State.WatcherPath; Hash = $State.WatcherHash }
        @{ Label = 'Phase 2 module'; Path = $State.ModulePath; Hash = $State.ModuleHash }
        @{ Label = 'Phase 2 copier'; Path = $State.CopierPath; Hash = $State.CopierHash }
        @{ Label = 'Codex CLI'; Path = $State.CodexCommand; Hash = $State.CodexCommandHash }
    )) {
        if (-not (Test-Path -LiteralPath $input.Path -PathType Leaf) -or
            (Get-FileHashValue $input.Path) -cne $input.Hash) {
            throw "$($input.Label) changed during Phase 2: $($input.Path)"
        }
    }
    foreach ($row in $State.Plan.Rows) {
        if (-not (Test-Path -LiteralPath $row.StagingPath -PathType Leaf) -or
            (Get-FileHashValue $row.StagingPath) -cne $row.Hash) {
            throw "Approved staging file changed during Phase 2: $($row.StagingPath)"
        }
    }
    if ($RequireMissingOutput -and (Test-Path -LiteralPath $State.OutputRoot)) {
        throw "Output root appeared before the approved copy: $($State.OutputRoot)"
    }
}

function New-Phase2VerifierPrompt {
    param([Parameter(Mandatory = $true)][hashtable]$State)

    $mappings = [Collections.Generic.List[string]]::new()
    foreach ($row in $State.Plan.Rows) {
        $destinationPath = Join-Path $State.OutputRoot ($row.Destination.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $mappings.Add("COPY ROW $($row.Number) STAGING PATH: $($row.StagingPath)")
        $mappings.Add("COPY ROW $($row.Number) OUTPUT PATH: $destinationPath")
    }
    @"
ROLE: PHASE 2 COPY VERIFIER

Read every exact path below in full. Use only these paths. Do not change any file, create
any file, repair any difference, or inspect anything else. Independently verify that the
new contract tree contains exactly the approved destinations and that every destination
is byte-for-byte identical to its approved Phase 1 staging file.

GUIDE PATH: $($State.GuidePath)
RULES PATH: $($State.RulesPath)
GUARDRAILS PATH: $($State.GuardrailsPath)
PHASE 2 MANIFEST PATH: $($State.ManifestPath)
OUTPUT ROOT PATH: $($State.OutputRoot)

$($mappings -join "`n")

Return exactly these eight lines and nothing else:
STATUS: VERIFIED | BLOCKED
# Phase 2 verification
Manifest rows: <count>
File list: VERIFIED | MISMATCH
Paths: VERIFIED | MISMATCH
Byte equality: VERIFIED | MISMATCH
Approved mapping: VERIFIED | MISMATCH
Evidence: <specific evidence>
"@
}

function Assert-Phase2VerifierReport {
    param(
        [Parameter(Mandatory = $true)][string]$Report,
        [Parameter(Mandatory = $true)][int]$ExpectedRows
    )

    $lines = @(($Report.TrimEnd("`r", "`n")) -split '\r?\n')
    if ($lines.Count -ne 8) { throw 'Phase 2 verifier report must contain exactly eight lines.' }
    if ($lines[0] -cnotmatch '^STATUS: (VERIFIED|BLOCKED)$') { throw 'Phase 2 verifier returned an invalid status.' }
    $status = $Matches[1]
    if ($lines[1] -cne '# Phase 2 verification') { throw 'Phase 2 verifier returned an invalid heading.' }
    if ($lines[2] -cne "Manifest rows: $ExpectedRows") { throw 'Phase 2 verifier returned the wrong manifest-row count.' }
    $checks = [Collections.Generic.List[string]]::new()
    foreach ($index in 3..6) {
        if ($lines[$index] -cnotmatch '^(File list|Paths|Byte equality|Approved mapping): (VERIFIED|MISMATCH)$') {
            throw "Phase 2 verifier returned an invalid check line: $($lines[$index])"
        }
        $checks.Add($Matches[2])
    }
    if ($lines[7] -cnotmatch '^Evidence: \S.+$') { throw 'Phase 2 verifier omitted specific evidence.' }
    if ($status -eq 'VERIFIED' -and @($checks | Where-Object { $_ -ne 'VERIFIED' }).Count -ne 0) {
        throw 'Phase 2 verifier claimed VERIFIED with a mismatched check.'
    }
    if ($status -eq 'BLOCKED' -and @($checks | Where-Object { $_ -eq 'MISMATCH' }).Count -eq 0) {
        throw 'Phase 2 verifier claimed BLOCKED without a mismatched check.'
    }
    $status
}

function Write-Phase2Receipt {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$RunDirectory,
        [Parameter(Mandatory = $true)][hashtable]$State,
        [Parameter(Mandatory = $true)][string]$RunIdentifier,
        [Parameter(Mandatory = $true)][string]$CodexModelName,
        [Parameter(Mandatory = $true)][string]$CodexEffort
    )

    $artifactLines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $RunDirectory -Recurse -File | Where-Object Name -ne 'receipt.md' | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($RunDirectory, $file.FullName).Replace('\', '/')
        $artifactLines += ('- `{0}` — `{1}`' -f $relative, (Get-FileHashValue $file.FullName))
    }
    $copyLines = @($State.Plan.Rows | ForEach-Object {
        '- `{0}` — `{1}` -> `{2}`' -f $_.Hash, $_.StagingPath, $_.Destination
    })
    $text = @"
# Contract Phase 2 receipt

- Run: $RunIdentifier
- Status: $Status
- Guide: $($State.GuidePath) — $($State.GuideHash)
- Rules: $($State.RulesPath) — $($State.RulesHash)
- Guardrails: $($State.GuardrailsPath) — $($State.GuardrailsHash)
- Manifest: $($State.ManifestPath) — $($State.ManifestHash)
- Output root: $($State.OutputRoot)
- Watcher: $($State.WatcherPath) — $($State.WatcherHash)
- Phase 2 module: $($State.ModulePath) — $($State.ModuleHash)
- Copier: $($State.CopierPath) — $($State.CopierHash)
- Codex model: $CodexModelName ($CodexEffort)
- Codex CLI: $($State.CodexCommand) — $($State.CodexCommandHash)

## Approved copies

$($copyLines -join "`n")

## Retained artifacts

$($artifactLines -join "`n")
"@
    Write-AtomicText (Join-Path $RunDirectory 'receipt.md') ($text.TrimEnd() + "`n")
}

function Invoke-ContractPhase2 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunIdentifier,
        [Parameter(Mandatory = $true)][string]$Guide,
        [Parameter(Mandatory = $true)][string]$Rules,
        [Parameter(Mandatory = $true)][string]$Guardrails,
        [Parameter(Mandatory = $true)][string]$Manifest,
        [Parameter(Mandatory = $true)][string]$FinalOutputRoot,
        [Parameter(Mandatory = $true)][string]$Copier,
        [string]$ApprovalPhrase,
        [switch]$PrintApproval,
        [Parameter(Mandatory = $true)][string]$CodexCliCommand,
        [Parameter(Mandatory = $true)][string]$RunsDirectory,
        [Parameter(Mandatory = $true)][string]$WatcherPath,
        [Parameter(Mandatory = $true)][string]$ModulePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[Diagnostics.Process]]$Processes
    )

    $guidePath = Resolve-LeafPath $Guide 'Guide'
    $rulesPath = Resolve-LeafPath $Rules 'Rules'
    $guardrailsPath = Resolve-LeafPath $Guardrails 'Guardrails'
    $manifestPath = Resolve-LeafPath $Manifest 'Phase 2 manifest'
    $copierPath = Resolve-LeafPath $Copier 'Phase 2 copier'
    $watcherFile = Resolve-LeafPath $WatcherPath 'Watcher'
    $moduleFile = Resolve-LeafPath $ModulePath 'Phase 2 module'
    $codexCli = Resolve-CommandPath $CodexCliCommand 'Codex'
    $runsRoot = [IO.Path]::GetFullPath($RunsDirectory)

    . $copierPath
    $outputRootPath = Resolve-ApprovedContractOutputRoot $FinalOutputRoot
    $plan = Read-ApprovedContractCopyPlan -ManifestPath $manifestPath
    $runDirectory = Join-Path $runsRoot $RunIdentifier
    if ($runDirectory.Equals($outputRootPath, [StringComparison]::OrdinalIgnoreCase) -or
        (Test-Phase2PathWithin $runDirectory $outputRootPath) -or
        (Test-Phase2PathWithin $outputRootPath $runDirectory)) {
        throw 'Runs directory and final output root must be separate trees.'
    }

    $state = @{
        GuidePath = $guidePath
        RulesPath = $rulesPath
        GuardrailsPath = $guardrailsPath
        ManifestPath = $manifestPath
        OutputRoot = $outputRootPath
        RunsRoot = $runsRoot
        CopierPath = $copierPath
        WatcherPath = $watcherFile
        ModulePath = $moduleFile
        CodexCommand = $codexCli
        GuideHash = Get-FileHashValue $guidePath
        RulesHash = Get-FileHashValue $rulesPath
        GuardrailsHash = Get-FileHashValue $guardrailsPath
        ManifestHash = Get-FileHashValue $manifestPath
        CopierHash = Get-FileHashValue $copierPath
        WatcherHash = Get-FileHashValue $watcherFile
        ModuleHash = Get-FileHashValue $moduleFile
        CodexCommandHash = Get-FileHashValue $codexCli
        Plan = $plan
    }
    $expectedApproval = Get-Phase2ApprovalPhrase $state $RunIdentifier $CodexModel $CodexReasoningEffort $RoleTimeoutSeconds
    if ($PrintApproval) {
        return [pscustomobject]@{ ExitCode = 0; Output = $expectedApproval }
    }
    if ($ApprovalPhrase -cne $expectedApproval) {
        throw 'Approval mismatch. Run with -ShowApproval and use the exact printed phrase.'
    }
    if (Test-Path -LiteralPath $runDirectory) { throw "Run directory already exists: $runDirectory" }
    Assert-Phase2InputsUnchanged $state -RequireMissingOutput

    New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $privateRoot = Join-Path $runDirectory 'private'
    New-Item -ItemType Directory -Path $privateRoot | Out-Null
    $status = 'FAILED'
    $failure = $null
    try {
        $checkResult = Invoke-ApprovedContractCopy -Plan $plan -FinalOutputRoot $outputRootPath -CheckOnly
        Write-AtomicText (Join-Path $runDirectory 'copier-check.txt') ($checkResult.Message.TrimEnd() + "`n")
        Assert-Phase2InputsUnchanged $state -RequireMissingOutput

        $copyResult = Invoke-ApprovedContractCopy -Plan $plan -FinalOutputRoot $outputRootPath
        Write-AtomicText (Join-Path $runDirectory 'copier-copy.txt') ($copyResult.Message.TrimEnd() + "`n")
        Assert-Phase2InputsUnchanged $state
        Assert-ApprovedContractCopyPlan $plan $outputRootPath -VerifyOutput

        $verifierDirectory = New-RoleDirectory $privateRoot 'verifier'
        $verifierPrompt = New-Phase2VerifierPrompt $state
        $inputDirectories = @(
            @($guidePath, $rulesPath, $guardrailsPath, $manifestPath) +
            @($plan.Rows | ForEach-Object StagingPath) +
            @($outputRootPath)
        ) | ForEach-Object {
            if (Test-Path -LiteralPath $_ -PathType Container) { $_ } else { Split-Path -Parent $_ }
        } | Sort-Object -Unique
        Write-Host 'Starting fresh Codex Phase 2 verifier...'
        $role = Start-RoleProcess 'codex' 'phase2-verifier' $verifierDirectory $verifierPrompt $codexCli $codexCli $inputDirectories $Processes
        $deadline = [DateTime]::UtcNow.AddSeconds($RoleTimeoutSeconds)
        while (-not $role.Process.HasExited) {
            if ([DateTime]::UtcNow -gt $deadline) {
                Stop-RoleProcess $role
                throw "Phase 2 verifier timed out after $RoleTimeoutSeconds seconds."
            }
            Start-Sleep -Milliseconds 100
        }
        $verification = Complete-RoleProcess $role $runDirectory @('VERIFIED', 'BLOCKED')
        $verifiedStatus = Assert-Phase2VerifierReport $verification.Report $plan.Rows.Count
        Write-AtomicText (Join-Path $runDirectory 'verification.md') $verification.Report
        Assert-Phase2InputsUnchanged $state
        Assert-ApprovedContractCopyPlan $plan $outputRootPath -VerifyOutput
        $status = if ($verifiedStatus -eq 'VERIFIED') { 'COMPLETE' } else { 'BLOCKED' }
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
        try { Assert-Phase2InputsUnchanged $state }
        catch {
            $failure = (($failure, $_.Exception.Message | Where-Object { $_ }) -join "`n")
            $status = 'FAILED'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($failure)) {
        $status = 'FAILED'
        Write-AtomicText (Join-Path $runDirectory 'failure.txt') ($failure.TrimEnd() + "`n")
    }
    Write-Phase2Receipt $status $runDirectory $state $RunIdentifier $CodexModel $CodexReasoningEffort
    if ($status -eq 'FAILED') { [Console]::Error.WriteLine($failure) }
    $exitCode = if ($status -eq 'COMPLETE') { 0 } elseif ($status -eq 'BLOCKED') { 2 } else { 1 }
    [pscustomobject]@{ ExitCode = $exitCode; Output = $runDirectory }
}
