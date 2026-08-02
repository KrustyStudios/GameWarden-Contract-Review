[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9-]{2,79}$')][string]$RunId,
    [Parameter(Mandatory = $true)][string]$GuidePath,
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][string]$SplitterPath,
    [string]$Approval,
    [switch]$ShowApproval,
    [switch]$AllCodex,
    [string]$ClaudeCommand = 'claude',
    [string]$CodexCommand = 'codex',
    [string]$ClaudeModel = 'opus',
    [string]$CodexModel = 'gpt-5.6-sol',
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max')][string]$CodexReasoningEffort = 'max',
    [ValidateRange(1, 86400)][int]$RoleTimeoutSeconds = 3600,
    [string]$RunsRoot = (Join-Path $PSScriptRoot 'runs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$activeProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()

function Resolve-LeafPath {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label not found: $Path" }
    (Resolve-Path -LiteralPath $Path).Path
}

function Resolve-CommandPath {
    param([string]$Command, [string]$Label)
    if (Test-Path -LiteralPath $Command -PathType Leaf) { return (Resolve-Path -LiteralPath $Command).Path }
    $found = Get-Command $Command -ErrorAction Stop | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($found.Source)) { throw "$Label CLI not found: $Command" }
    $found.Source
}

function Get-BytesHash {
    param([byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-FileHashValue {
    param([string]$Path)
    Get-BytesHash ([IO.File]::ReadAllBytes($Path))
}

function Write-AtomicText {
    param([string]$Path, [string]$Text)
    $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    }
}

function Get-ApprovalPhrase {
    param([hashtable]$State)
    $mode = if ($AllCodex) { 'all-codex' } else { 'claude-codex' }
    $lines = @(
        "run=$RunId"
        "guide=$($State.GuideHash)"
        "target=$($State.TargetHash)"
        "watcher=$($State.WatcherHash)"
        "splitter=$($State.SplitterHash)"
        "mode=$mode"
        "claude-model=$ClaudeModel"
        "codex-model=$CodexModel"
        "codex-effort=$CodexReasoningEffort"
        "timeout=$RoleTimeoutSeconds"
        "claude-command=$($State.ClaudeCommand)"
        "claude-command-hash=$($State.ClaudeCommandHash)"
        "codex-command=$($State.CodexCommand)"
        "codex-command-hash=$($State.CodexCommandHash)"
    )
    $hash = Get-BytesHash ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n"))
    "APPROVE CONTRACT REVIEW $RunId $hash"
}

function New-RoleDirectory {
    param([string]$Root, [string]$Name, [byte[]]$GuideBytes, [byte[]]$TargetBytes, [string]$Prompt)
    $directory = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $directory 'GUIDE.md'), $GuideBytes)
    [IO.File]::WriteAllBytes((Join-Path $directory 'TARGET.md'), $TargetBytes)
    [IO.File]::WriteAllText((Join-Path $directory 'PROMPT.md'), $Prompt, [Text.UTF8Encoding]::new($false))
    $directory
}

function New-Prompt {
    param([string]$Role, [string]$Guide, [string]$Target, [string]$Material = '')
    @"
ROLE: $Role

Follow the complete guide below. Use only the guide, target, and role material in this prompt.
Return only the Markdown report required for this role. Do not use tools or outside context.

===== GUIDE =====
$Guide
===== TARGET =====
$Target
===== ROLE MATERIAL =====
$Material
===== END INPUT =====
"@
}

function Start-RoleProcess {
    param(
        [string]$Provider,
        [string]$Slot,
        [string]$Directory,
        [string]$Prompt,
        [string]$ClaudeCli,
        [string]$CodexCli,
        [Collections.Generic.List[Diagnostics.Process]]$Processes
    )
    $cli = if ($Provider -eq 'claude') { $ClaudeCli } else { $CodexCli }
    $arguments = [Collections.Generic.List[string]]::new()
    if ($Provider -eq 'claude') {
        foreach ($argument in @('--model', $ClaudeModel, '--safe-mode', '--setting-sources', '', '--tools', '', '--disable-slash-commands', '--no-session-persistence', '--no-chrome', '--permission-mode', 'dontAsk', '--output-format', 'text', '--print')) {
            $arguments.Add($argument)
        }
    } else {
        foreach ($argument in @('exec', '--model', $CodexModel, '--config', "model_reasoning_effort=`"$CodexReasoningEffort`"", '--sandbox', 'read-only', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--strict-config', '--disable', 'shell_tool', '--disable', 'unified_exec', '--output-last-message', (Join-Path $Directory 'REPORT.md'), '-')) {
            $arguments.Add($argument)
        }
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    if ([IO.Path]::GetExtension($cli) -eq '.ps1') {
        $start.FileName = (Get-Process -Id $PID).Path
        foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $cli)) { $start.ArgumentList.Add($argument) }
    } else {
        $start.FileName = $cli
    }
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.Environment['CONTRACT_REVIEW_SLOT'] = $Slot

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw "Could not start $Slot." }
    $Processes.Add($process)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.StandardInput.Write($Prompt)
    $process.StandardInput.Close()
    [pscustomobject]@{
        Process = $process
        Provider = $Provider
        Slot = $Slot
        Directory = $Directory
        Started = [DateTime]::UtcNow
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Stop-RoleProcess {
    param([object]$Role)
    if ($null -eq $Role -or $Role.Process.HasExited) { return }
    $Role.Process.Kill($true)
    if (-not $Role.Process.WaitForExit(5000)) { throw "Could not terminate the $($Role.Slot) process tree." }
}

function Complete-RoleProcess {
    param([object]$Role, [string]$RunDirectory, [string[]]$AllowedStatus)
    $Role.Process.WaitForExit()
    $stdout = $Role.Stdout.GetAwaiter().GetResult()
    $stderr = $Role.Stderr.GetAwaiter().GetResult()
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-AtomicText (Join-Path $RunDirectory "$($Role.Slot).stderr.txt") ($stderr.TrimEnd() + "`n")
    }
    if ($Role.Process.ExitCode -ne 0) {
        throw "$($Role.Slot) CLI exited $($Role.Process.ExitCode).`n$($stderr.TrimEnd())"
    }
    $reportPath = Join-Path $Role.Directory 'REPORT.md'
    $report = if ($Role.Provider -eq 'codex' -and (Test-Path $reportPath -PathType Leaf)) {
        [IO.File]::ReadAllText($reportPath, $utf8)
    } else { $stdout }
    if ([string]::IsNullOrWhiteSpace($report)) { throw "$($Role.Slot) returned an empty report." }
    $firstLine = ($report -split "`r?`n", 2)[0].Trim()
    if ($firstLine -notmatch '^STATUS: (.+)$' -or $Matches[1] -notin $AllowedStatus) {
        throw "$($Role.Slot) returned invalid first-line status: $firstLine"
    }
    [pscustomobject]@{ Report = $report.TrimEnd() + "`n"; Status = $Matches[1] }
}

function Wait-ParallelRoles {
    param([object]$First, [object]$Second, [string]$RunDirectory, [string[]]$AllowedStatus)
    $deadline = [DateTime]::UtcNow.AddSeconds($RoleTimeoutSeconds)
    $results = @{}
    try {
        while ($results.Count -lt 2) {
            foreach ($role in @($First, $Second)) {
                if (-not $results.ContainsKey($role.Slot) -and $role.Process.HasExited) {
                    $result = Complete-RoleProcess $role $RunDirectory $AllowedStatus
                    if ($result.Status -eq 'BLOCKED') {
                        Write-AtomicText (Join-Path $RunDirectory "$($role.Slot).blocked.md") $result.Report
                        $peer = if ($role.Slot -eq $First.Slot) { $Second } else { $First }
                        Stop-RoleProcess $peer
                        throw "$($role.Slot) reported STATUS: BLOCKED."
                    }
                    $results[$role.Slot] = $result
                }
            }
            if ($results.Count -lt 2 -and [DateTime]::UtcNow -gt $deadline) {
                Stop-RoleProcess $First
                Stop-RoleProcess $Second
                throw "Role timeout after $RoleTimeoutSeconds seconds."
            }
            if ($results.Count -lt 2) { Start-Sleep -Milliseconds 100 }
        }
    } catch {
        Stop-RoleProcess $First
        Stop-RoleProcess $Second
        throw
    }
    @($results[$First.Slot], $results[$Second.Slot])
}

function Invoke-OneRole {
    param([string]$Provider, [string]$Slot, [string]$Directory, [string]$Prompt, [string]$ClaudeCli, [string]$CodexCli)
    $role = Start-RoleProcess $Provider $Slot $Directory $Prompt $ClaudeCli $CodexCli $activeProcesses
    $deadline = [DateTime]::UtcNow.AddSeconds($RoleTimeoutSeconds)
    while (-not $role.Process.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) { Stop-RoleProcess $role; throw "$Slot timed out after $RoleTimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 100
    }
    $result = Complete-RoleProcess $role $runDirectory @('OK', 'BLOCKED', 'COMPLETE', 'USER_DECISION_REQUIRED')
    if ($result.Status -eq 'BLOCKED') { Write-AtomicText (Join-Path $runDirectory "$Slot.blocked.md") $result.Report; throw "$Slot reported STATUS: BLOCKED." }
    $result
}

function Write-Receipt {
    param([string]$Status, [string]$RunDirectory, [hashtable]$State)
    $artifactLines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $RunDirectory -Recurse -File | Where-Object Name -ne 'receipt.md' | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($RunDirectory, $file.FullName).Replace('\', '/')
        $artifactLines += ('- `{0}` — `{1}`' -f $relative, (Get-FileHashValue $file.FullName))
    }
    $mode = if ($AllCodex) { 'all-codex' } else { 'claude-codex' }
    $text = @"
# Contract review receipt

- Run: $RunId
- Status: $Status
- Guide: $($State.GuidePath) — $($State.GuideHash)
- Source: $($State.TargetPath) — $($State.TargetHash)
- Watcher: $($State.WatcherHash)
- Splitter: $($State.SplitterPath) — $($State.SplitterHash)
- Mode: $mode
- Claude model: $ClaudeModel
- Codex model: $CodexModel ($CodexReasoningEffort)
- Claude CLI: $($State.ClaudeCommand) — $($State.ClaudeCommandHash)
- Codex CLI: $($State.CodexCommand) — $($State.CodexCommandHash)

## Retained artifacts

$($artifactLines -join "`n")
"@
    Write-AtomicText (Join-Path $RunDirectory 'receipt.md') ($text.TrimEnd() + "`n")
}

$guide = Resolve-LeafPath $GuidePath 'Guide'
$target = Resolve-LeafPath $TargetPath 'Target'
$splitter = Resolve-LeafPath $SplitterPath 'Splitter'
$watcher = (Resolve-Path -LiteralPath $PSCommandPath).Path
$codexCli = Resolve-CommandPath $CodexCommand 'Codex'
$claudeCli = if ($AllCodex) { $codexCli } else { Resolve-CommandPath $ClaudeCommand 'Claude' }
$guideBytes = [IO.File]::ReadAllBytes($guide)
$targetBytes = [IO.File]::ReadAllBytes($target)
$state = @{
    GuidePath = $guide
    TargetPath = $target
    SplitterPath = $splitter
    GuideHash = Get-BytesHash $guideBytes
    TargetHash = Get-BytesHash $targetBytes
    SplitterHash = Get-FileHashValue $splitter
    WatcherHash = Get-FileHashValue $watcher
    ClaudeCommand = if ($AllCodex) { 'not-used' } else { $claudeCli }
    ClaudeCommandHash = if ($AllCodex) { 'not-used' } else { Get-FileHashValue $claudeCli }
    CodexCommand = $codexCli
    CodexCommandHash = Get-FileHashValue $codexCli
}
$expectedApproval = Get-ApprovalPhrase $state
if ($ShowApproval) { Write-Output $expectedApproval; exit 0 }
if ($Approval -cne $expectedApproval) { throw "Approval mismatch. Run with -ShowApproval and use the exact printed phrase." }

$runDirectory = Join-Path ([IO.Path]::GetFullPath($RunsRoot)) $RunId
if (Test-Path -LiteralPath $runDirectory) { throw "Run directory already exists: $runDirectory" }
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$privateRoot = Join-Path $runDirectory 'private'
New-Item -ItemType Directory -Path $privateRoot | Out-Null
$status = 'FAILED'
$failure = $null

try {
    $guideText = $utf8.GetString($guideBytes)
    $targetText = $utf8.GetString($targetBytes)
    $blindPrompt = New-Prompt 'BLIND REVIEWER' $guideText $targetText
    $blindA = New-RoleDirectory $privateRoot 'blind-a' $guideBytes $targetBytes $blindPrompt
    $blindB = New-RoleDirectory $privateRoot 'blind-b' $guideBytes $targetBytes $blindPrompt
    $providerA = if ($AllCodex) { 'codex' } else { 'claude' }
    Write-Host "Starting blind reviewers concurrently ($providerA + codex)..."
    $roleA = Start-RoleProcess $providerA 'blind-A' $blindA $blindPrompt $claudeCli $codexCli $activeProcesses
    $roleB = Start-RoleProcess 'codex' 'blind-B' $blindB $blindPrompt $claudeCli $codexCli $activeProcesses
    $blindResults = Wait-ParallelRoles $roleA $roleB $runDirectory @('OK', 'BLOCKED')
    Write-AtomicText (Join-Path $runDirectory 'review-a.md') $blindResults[0].Report
    Write-AtomicText (Join-Path $runDirectory 'review-b.md') $blindResults[1].Report

    Write-Host 'Starting Codex comparator...'
    $comparisonMaterial = "===== REVIEW A =====`n$($blindResults[0].Report)===== REVIEW B =====`n$($blindResults[1].Report)"
    $comparisonPrompt = New-Prompt 'COMPARATOR' $guideText $targetText $comparisonMaterial
    $comparisonDir = New-RoleDirectory $privateRoot 'comparator' $guideBytes $targetBytes $comparisonPrompt
    $comparison = Invoke-OneRole 'codex' 'comparator' $comparisonDir $comparisonPrompt $claudeCli $codexCli
    if ($comparison.Status -ne 'OK') { throw "Comparator returned unexpected status: $($comparison.Status)" }
    Write-AtomicText (Join-Path $runDirectory 'comparison.md') $comparison.Report
    $proofMatch = [regex]::Match($comparison.Report, '(?s)BEGIN PROOF REQUESTS\s*(.*?)\s*END PROOF REQUESTS')
    if (-not $proofMatch.Success) { throw 'Comparator omitted the proof-request markers.' }
    $proofRequests = $proofMatch.Groups[1].Value.Trim()

    if ($proofRequests -eq 'NONE') {
        $proofAReport = "STATUS: OK`n# Proof response`nNONE`n"
        $proofBReport = $proofAReport
    } else {
        Write-Host 'Starting proof reviewers concurrently...'
        $proofPromptA = New-Prompt 'PROOF REVIEWER A' $guideText $targetText "===== OWN REVIEW (SIDE A) =====`n$($blindResults[0].Report)===== PROOF REQUESTS =====`n$proofRequests"
        $proofPromptB = New-Prompt 'PROOF REVIEWER B' $guideText $targetText "===== OWN REVIEW (SIDE B) =====`n$($blindResults[1].Report)===== PROOF REQUESTS =====`n$proofRequests"
        $proofDirA = New-RoleDirectory $privateRoot 'proof-a' $guideBytes $targetBytes $proofPromptA
        $proofDirB = New-RoleDirectory $privateRoot 'proof-b' $guideBytes $targetBytes $proofPromptB
        $proofRoleA = Start-RoleProcess $providerA 'proof-A' $proofDirA $proofPromptA $claudeCli $codexCli $activeProcesses
        $proofRoleB = Start-RoleProcess 'codex' 'proof-B' $proofDirB $proofPromptB $claudeCli $codexCli $activeProcesses
        $proofResults = Wait-ParallelRoles $proofRoleA $proofRoleB $runDirectory @('OK', 'BLOCKED')
        $proofAReport = $proofResults[0].Report
        $proofBReport = $proofResults[1].Report
    }
    Write-AtomicText (Join-Path $runDirectory 'proof-a.md') $proofAReport
    Write-AtomicText (Join-Path $runDirectory 'proof-b.md') $proofBReport

    Write-Host 'Starting Codex final validator...'
    $validationMaterial = "===== REVIEW A =====`n$($blindResults[0].Report)===== REVIEW B =====`n$($blindResults[1].Report)===== COMPARISON =====`n$($comparison.Report)===== PROOF A =====`n$proofAReport===== PROOF B =====`n$proofBReport"
    $validationPrompt = New-Prompt 'FINAL VALIDATOR' $guideText $targetText $validationMaterial
    $validationDir = New-RoleDirectory $privateRoot 'validator' $guideBytes $targetBytes $validationPrompt
    $validation = Invoke-OneRole 'codex' 'validator' $validationDir $validationPrompt $claudeCli $codexCli
    Write-AtomicText (Join-Path $runDirectory 'final-report.md') $validation.Report
    if ($validation.Status -eq 'USER_DECISION_REQUIRED') { $status = $validation.Status }
    elseif ($validation.Status -eq 'COMPLETE') {
        $manifestMatch = [regex]::Match($validation.Report, '(?s)BEGIN STAGE1 MANIFEST\s*(.*?)\s*END STAGE1 MANIFEST')
        if (-not $manifestMatch.Success -or [string]::IsNullOrWhiteSpace($manifestMatch.Groups[1].Value)) { throw 'Final validator omitted the Stage 1 manifest.' }
        $manifestPath = Join-Path $runDirectory 'stage1-manifest.tsv'
        Write-AtomicText $manifestPath ($manifestMatch.Groups[1].Value.Trim() + "`n")
        if ((Get-FileHashValue $guide) -ne $state.GuideHash -or (Get-FileHashValue $target) -ne $state.TargetHash) { throw 'Guide or source changed during review.' }
        $checkLog = @(& $splitter -Source $target -Manifest $manifestPath -OutDir (Join-Path $runDirectory 'staging') -CheckOnly 2>&1)
        Write-AtomicText (Join-Path $runDirectory 'splitter-check.txt') (($checkLog -join "`n").TrimEnd() + "`n")
        $stageLog = @(& $splitter -Source $target -Manifest $manifestPath -OutDir (Join-Path $runDirectory 'staging') 2>&1)
        Write-AtomicText (Join-Path $runDirectory 'splitter-stage.txt') (($stageLog -join "`n").TrimEnd() + "`n")
        $status = 'COMPLETE'
    } else { throw "Final validator returned unexpected status: $($validation.Status)" }
} catch {
    $failure = $_.Exception.Message
    Write-AtomicText (Join-Path $runDirectory 'failure.txt') ($failure.TrimEnd() + "`n")
} finally {
    foreach ($process in $activeProcesses) {
        if (-not $process.HasExited) {
            try { $process.Kill($true); [void]$process.WaitForExit(5000) }
            catch { $failure = (($failure, "Cleanup failed: $($_.Exception.Message)" | Where-Object { $_ }) -join "`n"); $status = 'FAILED' }
        }
        $process.Dispose()
    }
    try { Remove-Item -LiteralPath $privateRoot -Recurse -Force -ErrorAction Stop }
    catch { $failure = (($failure, "Cleanup failed: $($_.Exception.Message)" | Where-Object { $_ }) -join "`n"); $status = 'FAILED' }
    if ((Get-FileHashValue $guide) -ne $state.GuideHash -or (Get-FileHashValue $target) -ne $state.TargetHash) {
        $failure = (($failure, 'Guide or source changed during review.' | Where-Object { $_ }) -join "`n")
        $status = 'FAILED'
    }
}

if (-not [string]::IsNullOrWhiteSpace($failure)) {
    $status = 'FAILED'
    Write-AtomicText (Join-Path $runDirectory 'failure.txt') ($failure.TrimEnd() + "`n")
}
Write-Receipt $status $runDirectory $state
Write-Output $runDirectory
if ($status -eq 'COMPLETE') { exit 0 }
if ($status -eq 'USER_DECISION_REQUIRED') { exit 2 }
[Console]::Error.WriteLine($failure)
exit 1
