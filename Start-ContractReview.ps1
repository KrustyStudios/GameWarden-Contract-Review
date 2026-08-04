[CmdletBinding(DefaultParameterSetName = 'SourceReview')]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9][a-z0-9-]{2,79}$')][string]$RunId,
    [Parameter(Mandatory = $true)][string]$GuidePath,
    [Parameter(Mandatory = $true)][string]$RulesPath,
    [Parameter(Mandatory = $true)][string]$GuardrailsPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'SourceReview')][string]$TargetPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'SourceReview')][string]$StagingRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'SourceReview')][string]$SplitterPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Phase2')][switch]$Phase2,
    [Parameter(Mandatory = $true, ParameterSetName = 'Phase2')][string]$Phase2ManifestPath,
    [Parameter(Mandatory = $true, ParameterSetName = 'Phase2')][string]$OutputRoot,
    [Parameter(Mandatory = $true, ParameterSetName = 'Phase2')][string]$CopierPath,
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

function Get-TreeHashValue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Staging tree not found: $Path" }
    $root = (Resolve-Path -LiteralPath $Path).Path
    $lines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\', '/')
        $lines += "$relative`t$(Get-FileHashValue $file.FullName)"
    }
    Get-BytesHash ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n") + "`n"))
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
        "guide-path=$($State.GuidePath)"
        "guide-hash=$($State.GuideHash)"
        "rules-path=$($State.RulesPath)"
        "rules-hash=$($State.RulesHash)"
        "guardrails-path=$($State.GuardrailsPath)"
        "guardrails-hash=$($State.GuardrailsHash)"
        "source-path=$($State.TargetPath)"
        "source-hash=$($State.TargetHash)"
        "source-map-hash=$($State.SourceMapHash)"
        "staging-root=$($State.StagingRootPath)"
        "staging-hash=$($State.InitialStagingHash)"
        "watcher-path=$($State.WatcherPath)"
        "watcher-hash=$($State.WatcherHash)"
        "splitter-path=$($State.SplitterPath)"
        "splitter-hash=$($State.SplitterHash)"
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
    param([string]$Root, [string]$Name)
    $directory = Join-Path $Root $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    $directory
}

function New-Prompt {
    param(
        [string]$Role,
        [string]$Guide,
        [string]$Rules,
        [string]$Guardrails,
        [string]$Target,
        [string]$Staging,
        [string]$SourceMap = '',
        [string]$Material = ''
    )
    $sourceMapSection = if ([string]::IsNullOrWhiteSpace($SourceMap)) { '' } else {
@"
The script generated the source block map below from the exact source bytes. When this
role returns a placement manifest, copy its block IDs exactly. The first field is
START_BLOCK_ID..END_BLOCK_ID. Do not calculate or return source line numbers.

$SourceMap
"@
    }
    @"
ROLE: $Role

Read each exact input path below in full. Use only those files and the role material in
this prompt. Use tools only to read the listed files. Do not change an input or inspect
other files. Return only the exact role output required by the guide. The first line must
begin with STATUS:. Do not wrap the response in a Markdown code fence.

GUIDE PATH: $Guide
RULES PATH: $Rules
GUARDRAILS PATH: $Guardrails
SOURCE CONTRACT PATH: $Target
STAGING CONTRACT TREE PATH: $Staging

$sourceMapSection
===== ROLE MATERIAL =====
$Material
===== END INPUT =====
"@
}

function Get-SourceMap {
    param([string]$Splitter, [string]$Target)
    $output = @(& $Splitter -Source $Target -PrintSourceMap 6>&1 2>&1)
    $text = (($output | ForEach-Object { [string]$_ }) -join "`n").TrimEnd() + "`n"
    if ($text -notmatch '(?ms)^BEGIN SOURCE BLOCK MAP\r?\n(?:B-[a-f0-9]{16}(?:-[2-9][0-9]*)?\t[^\r\n]*\r?\n)+END SOURCE BLOCK MAP\r?\n$') {
        throw "Splitter returned an invalid source block map.`n$text"
    }
    return $text
}

function Assert-InputsUnchanged {
    param([hashtable]$State)
    foreach ($input in @(
        @{ Label = 'Guide'; Path = $State.GuidePath; Hash = $State.GuideHash }
        @{ Label = 'Rules'; Path = $State.RulesPath; Hash = $State.RulesHash }
        @{ Label = 'Guardrails'; Path = $State.GuardrailsPath; Hash = $State.GuardrailsHash }
        @{ Label = 'Source'; Path = $State.TargetPath; Hash = $State.TargetHash }
        @{ Label = 'Watcher'; Path = $State.WatcherPath; Hash = $State.WatcherHash }
        @{ Label = 'Splitter'; Path = $State.SplitterPath; Hash = $State.SplitterHash }
    )) {
        if ((Get-FileHashValue $input.Path) -ne $input.Hash) {
            throw "$($input.Label) changed during review: $($input.Path)"
        }
    }
    $currentSourceMapHash = Get-BytesHash ([Text.Encoding]::UTF8.GetBytes((Get-SourceMap $State.SplitterPath $State.TargetPath)))
    if ($currentSourceMapHash -ne $State.SourceMapHash) {
        throw "Source block map changed during review: $($State.TargetPath)"
    }
}

function Assert-StagingUnchanged {
    param([hashtable]$State)
    if ((Get-TreeHashValue $State.StagingRootPath) -ne $State.InitialStagingHash) {
        throw "Staging tree changed before approved materialization: $($State.StagingRootPath)"
    }
}

function Get-PrivatePlacement {
    param([string]$Report, [string]$Directory)
    $manifestMatch = [regex]::Match($Report, '(?ms)^BEGIN PLACEMENT MANIFEST[ \t]*\r?\n(.*?)^END PLACEMENT MANIFEST[ \t]*\r?$')
    $splitMatch = [regex]::Match($Report, '(?ms)^BEGIN SPLIT TEXT[ \t]*\r?\n(.*?)^END SPLIT TEXT[ \t]*\r?$')
    if (-not $manifestMatch.Success -or [string]::IsNullOrWhiteSpace($manifestMatch.Groups[1].Value)) {
        throw 'Private reviewer response omitted the placement manifest.'
    }
    if (-not $splitMatch.Success -or [string]::IsNullOrWhiteSpace($splitMatch.Groups[1].Value)) {
        throw 'Private reviewer response omitted split text.'
    }
    $manifestPath = Join-Path $Directory 'placement.tsv'
    $splitPath = Join-Path $Directory 'split.txt'
    Write-AtomicText $manifestPath ($manifestMatch.Groups[1].Value.Trim() + "`n")
    Write-AtomicText $splitPath ($splitMatch.Groups[1].Value.Trim() + "`n")
    [pscustomobject]@{ Manifest = $manifestPath; SplitText = $splitPath }
}

function Invoke-Splitter {
    param(
        [string]$Label,
        [string]$Manifest,
        [string]$SplitText,
        [string]$ReviewOutput,
        [string]$RunDirectory,
        [string]$StageRoot,
        [switch]$ApplyStaging,
        [switch]$CheckOnly
    )
    if ([string]::IsNullOrWhiteSpace($StageRoot)) {
        if ($CheckOnly) { $log = @(& $splitter -Source $target -Manifest $Manifest -SplitText $SplitText -ReviewOutput $ReviewOutput -CheckOnly 6>&1 2>&1) }
        else { $log = @(& $splitter -Source $target -Manifest $Manifest -SplitText $SplitText -ReviewOutput $ReviewOutput 6>&1 2>&1) }
    } else {
        if ($CheckOnly) { $log = @(& $splitter -Source $target -Manifest $Manifest -SplitText $SplitText -ReviewOutput $ReviewOutput -StagingRoot $StageRoot -CheckOnly 6>&1 2>&1) }
        elseif ($ApplyStaging) { $log = @(& $splitter -Source $target -Manifest $Manifest -SplitText $SplitText -ReviewOutput $ReviewOutput -StagingRoot $StageRoot -ApplyStaging 6>&1 2>&1) }
        else { $log = @(& $splitter -Source $target -Manifest $Manifest -SplitText $SplitText -ReviewOutput $ReviewOutput -StagingRoot $StageRoot 6>&1 2>&1) }
    }
    Write-AtomicText (Join-Path $RunDirectory "$Label.txt") (($log -join "`n").TrimEnd() + "`n")
}

function Start-RoleProcess {
    param(
        [string]$Provider,
        [string]$Slot,
        [string]$Directory,
        [string]$Prompt,
        [string]$ClaudeCli,
        [string]$CodexCli,
        [string[]]$InputDirectories,
        [Collections.Generic.List[Diagnostics.Process]]$Processes
    )
    $cli = if ($Provider -eq 'claude') { $ClaudeCli } else { $CodexCli }
    $arguments = [Collections.Generic.List[string]]::new()
    if ($Provider -eq 'claude') {
        foreach ($argument in @('--model', $ClaudeModel, '--safe-mode', '--setting-sources', '', '--tools', 'Read', '--disable-slash-commands', '--no-session-persistence', '--no-chrome', '--permission-mode', 'dontAsk', '--output-format', 'text', '--print')) {
            $arguments.Add($argument)
        }
        foreach ($inputDirectory in $InputDirectories) {
            $arguments.Add('--add-dir')
            $arguments.Add($inputDirectory)
        }
    } else {
        foreach ($argument in @('exec', '--model', $CodexModel, '--config', "model_reasoning_effort=`"$CodexReasoningEffort`"", '--sandbox', 'read-only', '--skip-git-repo-check', '--ephemeral', '--ignore-user-config', '--ignore-rules', '--strict-config', '--output-last-message', (Join-Path $Directory 'REPORT.md'), '-')) {
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

function Get-DescendantProcesses {
    param([int]$RootProcessId)
    $rows = @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId)
    $treeIds = [Collections.Generic.HashSet[int]]::new()
    [void]$treeIds.Add($RootProcessId)
    do {
        $added = 0
        foreach ($row in $rows) {
            $processId = [int]$row.ProcessId
            if ($processId -ne $RootProcessId -and $treeIds.Contains([int]$row.ParentProcessId) -and $treeIds.Add($processId)) {
                $added++
            }
        }
    } while ($added -gt 0)

    $descendants = [Collections.Generic.List[Diagnostics.Process]]::new()
    foreach ($processId in $treeIds) {
        if ($processId -eq $RootProcessId) { continue }
        try { $descendants.Add([Diagnostics.Process]::GetProcessById($processId)) }
        catch [ArgumentException] { }
    }
    $descendants.ToArray()
}

function Wait-ForProcessExit {
    param([Diagnostics.Process]$Process, [DateTime]$Deadline, [string]$Label)
    if ($Process.HasExited) { return }
    $remaining = [int][Math]::Ceiling(($Deadline - [DateTime]::UtcNow).TotalMilliseconds)
    if ($remaining -le 0 -or -not $Process.WaitForExit($remaining)) {
        throw "Could not terminate the $Label process tree."
    }
}

function Remove-PrivateDirectory {
    param([string]$Path)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($true) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ([DateTime]::UtcNow -ge $deadline) { throw }
            # Windows can release a terminated process's working-directory handle just after WaitForExit returns.
            Start-Sleep -Milliseconds 25
        }
    }
}

function Stop-RoleProcess {
    param([object]$Role)
    if ($null -eq $Role) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    # WaitForExit on Kill(true) covers the root only, so retain descendant handles and wait on them explicitly.
    $descendants = @(Get-DescendantProcesses $Role.Process.Id)
    try {
        if (-not $Role.Process.HasExited) { $Role.Process.Kill($true) }
        foreach ($descendant in $descendants) {
            if (-not $descendant.HasExited) { $descendant.Kill($true) }
        }
        Wait-ForProcessExit $Role.Process $deadline $Role.Slot
        foreach ($descendant in $descendants) {
            Wait-ForProcessExit $descendant $deadline $Role.Slot
        }
        [void]$Role.Stdout.GetAwaiter().GetResult()
        [void]$Role.Stderr.GetAwaiter().GetResult()
    } finally {
        foreach ($descendant in $descendants) { $descendant.Dispose() }
    }
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
        $primaryError = $_.Exception
        $cleanupErrors = [Collections.Generic.List[string]]::new()
        foreach ($role in @($First, $Second)) {
            try { Stop-RoleProcess $role }
            catch { $cleanupErrors.Add("$($role.Slot): $($_.Exception.Message)") }
        }
        if ($cleanupErrors.Count -gt 0) {
            throw [InvalidOperationException]::new(
                "$($primaryError.Message)`nCleanup failed: $($cleanupErrors -join '; ')",
                $primaryError
            )
        }
        throw $primaryError
    }
    @($results[$First.Slot], $results[$Second.Slot])
}

function Invoke-OneRole {
    param([string]$Provider, [string]$Slot, [string]$Directory, [string]$Prompt, [string]$ClaudeCli, [string]$CodexCli, [string[]]$InputDirectories)
    $role = Start-RoleProcess $Provider $Slot $Directory $Prompt $ClaudeCli $CodexCli $InputDirectories $activeProcesses
    $deadline = [DateTime]::UtcNow.AddSeconds($RoleTimeoutSeconds)
    while (-not $role.Process.HasExited) {
        if ([DateTime]::UtcNow -gt $deadline) { Stop-RoleProcess $role; throw "$Slot timed out after $RoleTimeoutSeconds seconds." }
        Start-Sleep -Milliseconds 100
    }
    $result = Complete-RoleProcess $role $runDirectory @('OK', 'BLOCKED', 'COMPLETE', 'VERIFIED', 'USER_DECISION_REQUIRED')
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
    $stagingLines = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $State.StagingRootPath -Recurse -File | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($State.StagingRootPath, $file.FullName).Replace('\', '/')
        $stagingLines += ('- `{0}` — `{1}`' -f $relative, (Get-FileHashValue $file.FullName))
    }
    $mode = if ($AllCodex) { 'all-codex' } else { 'claude-codex' }
    $text = @"
# Contract review receipt

- Run: $RunId
- Status: $Status
- Guide: $($State.GuidePath) — $($State.GuideHash)
- Rules: $($State.RulesPath) — $($State.RulesHash)
- Guardrails: $($State.GuardrailsPath) — $($State.GuardrailsHash)
- Source: $($State.TargetPath) — $($State.TargetHash)
- Source block map: $($State.SourceMapHash)
- Staging tree before: $($State.StagingRootPath) — $($State.InitialStagingHash)
- Staging tree after: $($State.StagingRootPath) — $(Get-TreeHashValue $State.StagingRootPath)
- Watcher: $($State.WatcherPath) — $($State.WatcherHash)
- Splitter: $($State.SplitterPath) — $($State.SplitterHash)
- Mode: $mode
- Claude model: $ClaudeModel
- Codex model: $CodexModel ($CodexReasoningEffort)
- Claude CLI: $($State.ClaudeCommand) — $($State.ClaudeCommandHash)
- Codex CLI: $($State.CodexCommand) — $($State.CodexCommandHash)

## Retained artifacts

$($artifactLines -join "`n")

## Staged contracts

$($stagingLines -join "`n")
"@
    Write-AtomicText (Join-Path $RunDirectory 'receipt.md') ($text.TrimEnd() + "`n")
}

if ($PSCmdlet.ParameterSetName -eq 'Phase2') {
    $phase2ModulePath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'ContractReview.Phase2.ps1')).Path
    . $phase2ModulePath
    $phase2Result = Invoke-ContractPhase2 `
        -RunIdentifier $RunId `
        -Guide $GuidePath `
        -Rules $RulesPath `
        -Guardrails $GuardrailsPath `
        -Manifest $Phase2ManifestPath `
        -FinalOutputRoot $OutputRoot `
        -Copier $CopierPath `
        -ApprovalPhrase $Approval `
        -PrintApproval:$ShowApproval `
        -CodexCliCommand $CodexCommand `
        -RunsDirectory $RunsRoot `
        -WatcherPath $PSCommandPath `
        -ModulePath $phase2ModulePath `
        -Processes $activeProcesses
    Write-Output $phase2Result.Output
    exit $phase2Result.ExitCode
}

$guide = Resolve-LeafPath $GuidePath 'Guide'
$rules = Resolve-LeafPath $RulesPath 'Rules'
$guardrails = Resolve-LeafPath $GuardrailsPath 'Guardrails'
$target = Resolve-LeafPath $TargetPath 'Target'
$staging = (Resolve-Path -LiteralPath $StagingRoot -ErrorAction Stop).Path
if (-not (Test-Path -LiteralPath $staging -PathType Container)) { throw "Staging tree not found: $StagingRoot" }
if ((Get-Item -LiteralPath $staging -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Staging tree cannot be a reparse point: $staging" }
$splitter = Resolve-LeafPath $SplitterPath 'Splitter'
$sourceMap = Get-SourceMap $splitter $target
$watcher = (Resolve-Path -LiteralPath $PSCommandPath).Path
$codexCli = Resolve-CommandPath $CodexCommand 'Codex'
$claudeCli = if ($AllCodex) { $codexCli } else { Resolve-CommandPath $ClaudeCommand 'Claude' }
$state = @{
    GuidePath = $guide
    RulesPath = $rules
    GuardrailsPath = $guardrails
    TargetPath = $target
    StagingRootPath = $staging
    SplitterPath = $splitter
    WatcherPath = $watcher
    GuideHash = Get-FileHashValue $guide
    RulesHash = Get-FileHashValue $rules
    GuardrailsHash = Get-FileHashValue $guardrails
    TargetHash = Get-FileHashValue $target
    SourceMapHash = Get-BytesHash ([Text.Encoding]::UTF8.GetBytes($sourceMap))
    InitialStagingHash = Get-TreeHashValue $staging
    SplitterHash = Get-FileHashValue $splitter
    WatcherHash = Get-FileHashValue $watcher
    ClaudeCommand = if ($AllCodex) { 'not-used' } else { $claudeCli }
    ClaudeCommandHash = if ($AllCodex) { 'not-used' } else { Get-FileHashValue $claudeCli }
    CodexCommand = $codexCli
    CodexCommandHash = Get-FileHashValue $codexCli
}
$inputDirectories = @((@($guide, $rules, $guardrails, $target) | ForEach-Object { Split-Path -Parent $_ }) + $staging | Sort-Object -Unique)
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
    $blindPrompt = New-Prompt 'BLIND REVIEWER' $guide $rules $guardrails $target $staging $sourceMap
    $blindA = New-RoleDirectory $privateRoot 'blind-a'
    $blindB = New-RoleDirectory $privateRoot 'blind-b'
    $providerA = if ($AllCodex) { 'codex' } else { 'claude' }
    Write-Host "Starting blind reviewers concurrently ($providerA + codex)..."
    $roleA = Start-RoleProcess $providerA 'blind-A' $blindA $blindPrompt $claudeCli $codexCli $inputDirectories $activeProcesses
    $roleB = Start-RoleProcess 'codex' 'blind-B' $blindB $blindPrompt $claudeCli $codexCli $inputDirectories $activeProcesses
    $blindResults = Wait-ParallelRoles $roleA $roleB $runDirectory @('OK', 'BLOCKED')
    Assert-InputsUnchanged $state
    Assert-StagingUnchanged $state
    $packetA = Get-PrivatePlacement $blindResults[0].Report $blindA
    $packetB = Get-PrivatePlacement $blindResults[1].Report $blindB
    $reviewAPath = Join-Path $runDirectory 'review-a.md'
    $reviewBPath = Join-Path $runDirectory 'review-b.md'
    $privateReviewA = Join-Path $blindA 'generated.md'
    $privateReviewB = Join-Path $blindB 'generated.md'
    Invoke-Splitter -Label 'splitter-check-a' -Manifest $packetA.Manifest -SplitText $packetA.SplitText -ReviewOutput $privateReviewA -RunDirectory $runDirectory -StageRoot $staging -CheckOnly
    Invoke-Splitter -Label 'splitter-check-b' -Manifest $packetB.Manifest -SplitText $packetB.SplitText -ReviewOutput $privateReviewB -RunDirectory $runDirectory -StageRoot $staging -CheckOnly
    Invoke-Splitter -Label 'splitter-render-a' -Manifest $packetA.Manifest -SplitText $packetA.SplitText -ReviewOutput $privateReviewA -RunDirectory $runDirectory -StageRoot $staging
    Invoke-Splitter -Label 'splitter-render-b' -Manifest $packetB.Manifest -SplitText $packetB.SplitText -ReviewOutput $privateReviewB -RunDirectory $runDirectory -StageRoot $staging
    Move-Item -LiteralPath $privateReviewA -Destination $reviewAPath
    Move-Item -LiteralPath $privateReviewB -Destination $reviewBPath
    $reviewA = [IO.File]::ReadAllText($reviewAPath, $utf8)
    $reviewB = [IO.File]::ReadAllText($reviewBPath, $utf8)

    Write-Host 'Starting Codex comparator...'
    $comparisonMaterial = "===== GENERATED REVIEW A =====`n$reviewA===== GENERATED REVIEW B =====`n$reviewB"
    $comparisonPrompt = New-Prompt 'COMPARATOR' $guide $rules $guardrails $target $staging -Material $comparisonMaterial
    $comparisonDir = New-RoleDirectory $privateRoot 'comparator'
    $comparison = Invoke-OneRole 'codex' 'comparator' $comparisonDir $comparisonPrompt $claudeCli $codexCli $inputDirectories
    Assert-InputsUnchanged $state
    Assert-StagingUnchanged $state
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
        $proofPromptA = New-Prompt 'PROOF REVIEWER A' $guide $rules $guardrails $target $staging -Material "===== OWN GENERATED REVIEW (SIDE A) =====`n$reviewA===== PROOF REQUESTS =====`n$proofRequests"
        $proofPromptB = New-Prompt 'PROOF REVIEWER B' $guide $rules $guardrails $target $staging -Material "===== OWN GENERATED REVIEW (SIDE B) =====`n$reviewB===== PROOF REQUESTS =====`n$proofRequests"
        $proofDirA = New-RoleDirectory $privateRoot 'proof-a'
        $proofDirB = New-RoleDirectory $privateRoot 'proof-b'
        $proofRoleA = Start-RoleProcess $providerA 'proof-A' $proofDirA $proofPromptA $claudeCli $codexCli $inputDirectories $activeProcesses
        $proofRoleB = Start-RoleProcess 'codex' 'proof-B' $proofDirB $proofPromptB $claudeCli $codexCli $inputDirectories $activeProcesses
        $proofResults = Wait-ParallelRoles $proofRoleA $proofRoleB $runDirectory @('OK', 'BLOCKED')
        Assert-InputsUnchanged $state
        Assert-StagingUnchanged $state
        $proofAReport = $proofResults[0].Report
        $proofBReport = $proofResults[1].Report
    }
    Write-AtomicText (Join-Path $runDirectory 'proof-a.md') $proofAReport
    Write-AtomicText (Join-Path $runDirectory 'proof-b.md') $proofBReport

    Write-Host 'Starting Codex final validator...'
    $validationMaterial = "===== GENERATED REVIEW A =====`n$reviewA===== GENERATED REVIEW B =====`n$reviewB===== COMPARISON =====`n$($comparison.Report)===== PROOF A =====`n$proofAReport===== PROOF B =====`n$proofBReport"
    $validationPrompt = New-Prompt 'FINAL VALIDATOR' $guide $rules $guardrails $target $staging $sourceMap $validationMaterial
    $validationDir = New-RoleDirectory $privateRoot 'validator'
    $validation = Invoke-OneRole 'codex' 'validator' $validationDir $validationPrompt $claudeCli $codexCli $inputDirectories
    Assert-InputsUnchanged $state
    Assert-StagingUnchanged $state
    if ($validation.Status -eq 'USER_DECISION_REQUIRED') {
        $publicDecision = [regex]::Replace($validation.Report, '(?s)BEGIN PLACEMENT MANIFEST.*$', '').TrimEnd() + "`n"
        Write-AtomicText (Join-Path $runDirectory 'user-decision.md') $publicDecision
        $status = $validation.Status
    }
    elseif ($validation.Status -eq 'COMPLETE') {
        $finalPacket = Get-PrivatePlacement $validation.Report $validationDir
        $finalReviewPath = Join-Path $runDirectory 'final-review.md'
        Assert-InputsUnchanged $state
        Assert-StagingUnchanged $state
        Invoke-Splitter -Label 'splitter-check-final' -Manifest $finalPacket.Manifest -SplitText $finalPacket.SplitText -ReviewOutput $finalReviewPath -RunDirectory $runDirectory -StageRoot $staging -CheckOnly
        Assert-InputsUnchanged $state
        Assert-StagingUnchanged $state
        Invoke-Splitter -Label 'splitter-stage-final' -Manifest $finalPacket.Manifest -SplitText $finalPacket.SplitText -ReviewOutput $finalReviewPath -RunDirectory $runDirectory -StageRoot $staging -ApplyStaging
        Assert-InputsUnchanged $state

        Write-Host 'Starting fresh Codex staging verifier...'
        $verifierMaterial = "FINAL GENERATED REVIEW PATH: $finalReviewPath`nSTAGING CONTRACT TREE PATH: $staging"
        $verifierPrompt = New-Prompt 'STAGING VERIFIER' $guide $rules $guardrails $target $staging -Material $verifierMaterial
        $verifierDir = New-RoleDirectory $privateRoot 'verifier'
        $verifier = Invoke-OneRole 'codex' 'verifier' $verifierDir $verifierPrompt $claudeCli $codexCli ($inputDirectories + $runDirectory | Sort-Object -Unique)
        if ($verifier.Status -ne 'VERIFIED') { throw "Staging verifier returned unexpected status: $($verifier.Status)" }
        Write-AtomicText (Join-Path $runDirectory 'staging-verification.md') $verifier.Report
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
    try { Remove-PrivateDirectory $privateRoot }
    catch { $failure = (($failure, "Cleanup failed: $($_.Exception.Message)" | Where-Object { $_ }) -join "`n"); $status = 'FAILED' }
    try { Assert-InputsUnchanged $state }
    catch {
        $failure = (($failure, $_.Exception.Message | Where-Object { $_ }) -join "`n")
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
