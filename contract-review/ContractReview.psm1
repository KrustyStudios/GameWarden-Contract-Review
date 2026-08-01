Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ContractReview.Core.ps1')
. (Join-Path $PSScriptRoot 'ContractReview.Validation.ps1')

$script:GovernancePaths = @('AI_RULES.md','AI_GUARDRAILS.md','contracts/APP_CONTRACT.md','.design/contract-epic.md')
$script:RunnerPaths = @(
    'Start-ContractReview.ps1','Recover-InterruptedContractReview.ps1','contract-review/ContractRecovery.psm1','contract-review/ContractApply.psm1',
    'contract-review/ContractReview.psm1','contract-review/ContractReview.Core.ps1','contract-review/ContractReview.Validation.ps1',
    'contract-review/Invoke-ClaudeReview.ps1','contract-review/Invoke-CodexReview.ps1',
    'schemas/agent-response.schema.json','schemas/contract-review-request.schema.json',
    'schemas/contract-review-execution.schema.json','schemas/contract-apply-decision.schema.json'
)

function Get-ContractReviewExecutionManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RequestPath,
        [Parameter(Mandatory = $true)][string]$RunnerRoot,
        [Parameter(Mandatory = $true)][string]$ClaudeAdapter,
        [Parameter(Mandatory = $true)][string]$CodexAdapter,
        [Parameter(Mandatory = $true)][string]$ClaudeModel,
        [Parameter(Mandatory = $true)][string]$CodexModel,
        [Parameter(Mandatory = $true)][string]$CodexReasoningEffort,
        [Parameter(Mandatory = $true)][int]$RoleTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$GitTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$SplitterTimeoutSeconds,
        [switch]$AllCodex
    )
    $request = Read-ContractReviewJson -Path $RequestPath -Label 'request'
    Assert-ContractReviewRequest -Request $request
    $target = Assert-ContractReviewTarget -Repository ([string]$request.targetRepository) -TimeoutSeconds $GitTimeoutSeconds
    $runnerPath = (Resolve-Path -LiteralPath $RunnerRoot).Path
    if ($runnerPath -ne (Resolve-Path -LiteralPath (Split-Path -Parent $PSScriptRoot)).Path) { throw 'RunnerRoot does not contain the loaded coordinator module.' }
    $pinned = [ordered]@{}
    foreach ($relative in @($script:GovernancePaths + @($request.sources) | Sort-Object -Unique)) {
        $pinned[$relative.Replace('\','/')] = Get-ContractReviewGitObjectId -Repository $target.Path -Revision $target.Revision -RelativePath $relative -TimeoutSeconds $GitTimeoutSeconds
    }
    if ($request.reviewKind -eq 'stage1') {
        $pinned['tools/ai/split-contract.ps1'] = Get-ContractReviewGitObjectId -Repository $target.Path -Revision $target.Revision -RelativePath 'tools/ai/split-contract.ps1' -TimeoutSeconds $GitTimeoutSeconds
    }
    $runnerFiles = [ordered]@{}
    foreach ($relative in $script:RunnerPaths) {
        $path = Join-Path $runnerPath $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required runner file is missing: $relative" }
        $runnerFiles[$relative] = Get-ContractReviewSha256 -Path $path
    }
    $defaultClaude = (Resolve-Path -LiteralPath (Join-Path $runnerPath 'contract-review/Invoke-ClaudeReview.ps1')).Path
    $defaultCodex = (Resolve-Path -LiteralPath (Join-Path $runnerPath 'contract-review/Invoke-CodexReview.ps1')).Path
    if ((Resolve-Path -LiteralPath $ClaudeAdapter).Path -ne $defaultClaude) { $runnerFiles['configured-claude-adapter'] = Get-ContractReviewSha256 -Path $ClaudeAdapter }
    if ((Resolve-Path -LiteralPath $CodexAdapter).Path -ne $defaultCodex) { $runnerFiles['configured-codex-adapter'] = Get-ContractReviewSha256 -Path $CodexAdapter }
    $codexCommand = Resolve-ContractReviewProviderCommand -Provider codex
    $codexProvider = [ordered]@{ provider='codex'; model=$CodexModel; reasoningEffort=$CodexReasoningEffort; commandPath=$codexCommand.path; commandSha256=$codexCommand.sha256; commandVersion=$codexCommand.version }
    $claudeProvider = if ($AllCodex) { $null } else {
        $claudeCommand = Resolve-ContractReviewProviderCommand -Provider claude
        [ordered]@{ provider='claude'; model=$ClaudeModel; reasoningEffort=$null; commandPath=$claudeCommand.path; commandSha256=$claudeCommand.sha256; commandVersion=$claudeCommand.version }
    }
    return [ordered]@{
        protocolVersion = 3; requestId = [string]$request.requestId; requestSha256 = Get-ContractReviewSha256 -Path $RequestPath
        targetRepository = $target.Path; targetRevision = $target.Revision; pinnedObjects = $pinned; runnerFiles = $runnerFiles
        reviewMode = if ($AllCodex) { 'all-codex' } else { 'claude-codex' }
        providers = [ordered]@{
            reviewerA = if ($AllCodex) { $codexProvider } else { $claudeProvider }
            reviewerB = $codexProvider
            comparator = $codexProvider
            reviewerAProof = if ($AllCodex) { $codexProvider } else { $claudeProvider }
            reviewerBProof = $codexProvider
            validator = $codexProvider
        }
        timeouts = [ordered]@{ roleSeconds=$RoleTimeoutSeconds; gitSeconds=$GitTimeoutSeconds; splitterSeconds=$SplitterTimeoutSeconds }
        cleanup = [ordered]@{ keepWorktree=$false; killFullProcessTree=$true; cleanupFailureIsTerminal=$true; automaticRetry=$false }
    }
}

function Get-ContractReviewManifestHash { param([object]$Manifest) return Get-ContractReviewTextSha256 -Text ($Manifest | ConvertTo-Json -Depth 64 -Compress) }

function Get-ContractReviewApproval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RequestPath,[Parameter(Mandatory = $true)][string]$RunnerRoot,
        [Parameter(Mandatory = $true)][string]$ClaudeAdapter,[Parameter(Mandatory = $true)][string]$CodexAdapter,
        [Parameter(Mandatory = $true)][string]$ClaudeModel,[Parameter(Mandatory = $true)][string]$CodexModel,
        [Parameter(Mandatory = $true)][string]$CodexReasoningEffort,[Parameter(Mandatory = $true)][int]$RoleTimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$GitTimeoutSeconds,[Parameter(Mandatory = $true)][int]$SplitterTimeoutSeconds,[switch]$AllCodex
    )
    $manifest = Get-ContractReviewExecutionManifest @PSBoundParameters
    Assert-ContractReviewProviderReadiness -Manifest $manifest -TimeoutSeconds $GitTimeoutSeconds
    return "APPROVE CONTRACT REVIEW $($manifest.requestId) $(Get-ContractReviewManifestHash -Manifest $manifest)"
}

function Claim-ContractReviewApproval {
    param([string]$RunnerRoot, [string]$RequestId, [string]$ManifestHash)
    $directory = Join-Path $RunnerRoot 'approval-receipts'
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $path = Join-Path $directory ("{0}-{1}.json" -f $RequestId, $ManifestHash)
    try {
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $text = ([ordered]@{ requestId=$RequestId; executionManifestSha256=$ManifestHash; claimedUtc=[DateTime]::UtcNow.ToString('o') } | ConvertTo-Json) + "`n"
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
            $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
        } finally { $stream.Dispose() }
    } catch { throw "Approval for request '$RequestId' and manifest '$ManifestHash' has already been consumed. Seed a fresh request ID." }
    return $path
}

function Copy-ContractReviewInputs {
    param([string]$Worktree, [string]$InputRoot, [object]$Request)
    New-Item -ItemType Directory -Path $InputRoot -Force | Out-Null
    foreach ($relative in @($script:GovernancePaths + @($Request.sources) | Sort-Object -Unique)) {
        $source = Join-Path $Worktree $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Pinned input is missing: $relative" }
        $destination = Join-Path $InputRoot $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination
    }
}

function Add-ContractReviewRoleReceipts {
    param([string]$ArtifactName,[System.Collections.Generic.List[string]]$Receipts)
    foreach ($name in @(
        "$ArtifactName.prompt.txt","$ArtifactName.response-schema.json","$ArtifactName.stdout.log",
        "$ArtifactName.stderr.log","$ArtifactName.provider.json","$ArtifactName.invocation.json","$ArtifactName.json"
    )) {
        if (-not $Receipts.Contains($name)) { [void]$Receipts.Add($name) }
    }
}

function Invoke-ContractReviewRole {
    param(
        [string]$Adapter,[string]$Role,[string]$ArtifactName,[ValidateSet('claude','codex')][string]$Provider,
        [string]$Model,[AllowNull()][string]$ReasoningEffort,[string]$Prompt,[string]$RunDirectory,
        [string]$RunnerRoot,[string]$InputRoot,[string]$ProviderCommand,[int]$TimeoutSeconds,[System.Collections.Generic.List[string]]$Receipts
    )
    $promptPath=Join-Path $RunDirectory "$ArtifactName.prompt.txt"; $outputPath=Join-Path $RunDirectory "$ArtifactName.json"
    $stdoutPath=Join-Path $RunDirectory "$ArtifactName.stdout.log"; $stderrPath=Join-Path $RunDirectory "$ArtifactName.stderr.log"
    $metadataPath=Join-Path $RunDirectory "$ArtifactName.provider.json"; $invocationPath=Join-Path $RunDirectory "$ArtifactName.invocation.json"
    $responseSchemaName="$ArtifactName.response-schema.json"; $responseSchemaPath=Join-Path $RunDirectory $responseSchemaName
    Write-ContractReviewAtomicText -Path $promptPath -Text $Prompt
    [void](New-ContractReviewRoleSchema -BaseSchemaPath (Join-Path $RunnerRoot 'schemas/agent-response.schema.json') -Role $Role -Path $responseSchemaPath)
    $invocation=[ordered]@{
        invocationId=[guid]::NewGuid().ToString('D'); role=$Role; provider=$Provider; requestedModel=$Model; reasoningEffort=$ReasoningEffort
        adapterSha256=Get-ContractReviewSha256 -Path $Adapter; promptSha256=Get-ContractReviewSha256 -Path $promptPath
        responseSchemaArtifact=$responseSchemaName; responseSchemaSha256=Get-ContractReviewSha256 -Path $responseSchemaPath
        adapterProcessId=$null; adapterProcessStartTimeUtc=$null; startedUtc=[DateTime]::UtcNow.ToString('o'); completedUtc=$null; status='starting'; providerMetadata=$null
    }
    Write-ContractReviewAtomicJson -Path $invocationPath -Value $invocation
    Add-ContractReviewRoleReceipts -ArtifactName $ArtifactName -Receipts $Receipts
    $environment=@{
        CONTRACT_REVIEW_ROLE=$Role; CONTRACT_REVIEW_ARTIFACT_NAME=$ArtifactName; CONTRACT_REVIEW_PROMPT_FILE=$promptPath; CONTRACT_REVIEW_OUTPUT_PATH=$outputPath
        CONTRACT_REVIEW_METADATA_PATH=$metadataPath; CONTRACT_REVIEW_MODEL=$Model; CONTRACT_REVIEW_REASONING_EFFORT=$ReasoningEffort
        CONTRACT_REVIEW_SCHEMA_PATH=$responseSchemaPath
        CONTRACT_REVIEW_PROVIDER_COMMAND=$ProviderCommand
        CONTRACT_REVIEW_TEST_SCENARIO=[Environment]::GetEnvironmentVariable('CONTRACT_REVIEW_TEST_SCENARIO','Process')
    }
    $cwd=Join-Path $RunDirectory ("cwd-$ArtifactName"); New-Item -ItemType Directory -Path $cwd | Out-Null
    $start=New-ContractReviewProcessStartInfo -FilePath (Get-Command pwsh.exe -ErrorAction Stop).Path -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$Adapter) -WorkingDirectory $cwd -Environment $environment -StdoutPath $stdoutPath -StderrPath $stderrPath
    Write-Host ("[{0}] starting {1} ({2})" -f [DateTime]::Now.ToString('HH:mm:ss'),$ArtifactName,$Provider)
    try {
        $null=Invoke-ContractReviewBoundedProcess -StartInfo $start.Info -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds -ProgressIntervalSeconds 30 -Label "agent role $ArtifactName" -OnStarted {
            param($childId)
            $child = Get-Process -Id $childId -ErrorAction Stop
            $invocation.adapterProcessId=$childId
            $invocation.adapterProcessStartTimeUtc=$child.StartTime.ToUniversalTime().ToString('o')
            Write-ContractReviewAtomicJson -Path $invocationPath -Value $invocation
        }
        $response=Read-ContractReviewJson -Path $outputPath -Label "agent role $ArtifactName response"
        Assert-ContractReviewResponse -Response $response -Role $Role
        Assert-ContractReviewResponseEvidence -Response $response -Role $Role -InputRoot $InputRoot
        $invocation.status='completed'
        if (Test-Path -LiteralPath $metadataPath) { $invocation.providerMetadata=Read-ContractReviewJson -Path $metadataPath -Label 'provider metadata' }
        Write-Host ("[{0}] completed {1}" -f [DateTime]::Now.ToString('HH:mm:ss'),$ArtifactName)
        return $response
    } catch {
        $failure=$_
        $invocation.status='failed'
        if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            $stderr=[IO.File]::ReadAllText($stderrPath,$script:ContractReviewUtf8)
            $configurationMarker=[regex]::Match($stderr,'(?m)^CONTRACT_REVIEW_PROVIDER_CONFIGURATION_BLOCKER:\s*(?<reason>[^\r\n]+)\s*$')
            $authenticationMarker=[regex]::Match($stderr,'(?m)^CONTRACT_REVIEW_PROVIDER_AUTHENTICATION_BLOCKER:\s*(?<reason>[^\r\n]+)\s*$')
            if ($configurationMarker.Success) {
                $invocation.status='blocked'
                throw "BLOCKER:provider configuration:$($configurationMarker.Groups['reason'].Value.Trim())"
            }
            if ($authenticationMarker.Success) {
                $invocation.status='blocked'
                throw "BLOCKER:provider authentication:$($authenticationMarker.Groups['reason'].Value.Trim())"
            }
        }
        throw $failure
    }
    finally { $invocation.completedUtc=[DateTime]::UtcNow.ToString('o'); Write-ContractReviewAtomicJson -Path $invocationPath -Value $invocation }
}

function Test-ContractReviewParallelRoleCompleted {
    param([Parameter(Mandatory = $true)][string]$InvocationPath)
    if (-not (Test-Path -LiteralPath $InvocationPath -PathType Leaf)) { return $false }
    $invocation = Read-ContractReviewJson -Path $InvocationPath -Label 'invocation receipt'
    return -not [string]::IsNullOrWhiteSpace([string]$invocation.completedUtc)
}

function Stop-ContractReviewParallelRoleProcess {
    param([Parameter(Mandatory = $true)][string]$InvocationPath)
    if (-not (Test-Path -LiteralPath $InvocationPath -PathType Leaf)) { return }
    try {
        Stop-ContractReviewRecordedProcessTree -InvocationPath $InvocationPath | Out-Null
    } catch {
        $terminationFailure = $_
        if (-not (Test-ContractReviewParallelRoleCompleted -InvocationPath $InvocationPath)) { throw $terminationFailure }
        if (Get-ContractReviewRecordedProcess -InvocationPath $InvocationPath) { throw $terminationFailure }
    }
}

function Stop-ContractReviewParallelRole {
    param([Parameter(Mandatory = $true)][object]$Entry)
    if ($Entry.Job.State -in @('NotStarted','Running')) {
        Wait-Job -Job $Entry.Job -Timeout 1 -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-ContractReviewParallelRoleCompleted -InvocationPath $Entry.InvocationPath) {
        if ($Entry.Job.State -in @('NotStarted','Running')) { Stop-Job -Job $Entry.Job -ErrorAction SilentlyContinue }
        return
    }
    Stop-ContractReviewParallelRoleProcess -InvocationPath $Entry.InvocationPath
    if ($Entry.Job.State -in @('NotStarted','Running')) {
        Stop-Job -Job $Entry.Job -ErrorAction SilentlyContinue
    }
    Stop-ContractReviewParallelRoleProcess -InvocationPath $Entry.InvocationPath
}

function Invoke-ContractReviewParallelRoles {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ReviewerAParameters,
        [Parameter(Mandatory = $true)][hashtable]$ReviewerBParameters,
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Receipts
    )
    $modulePath = Join-Path $PSScriptRoot 'ContractReview.psm1'
    $definitions = @(
        [pscustomobject]@{ Name='reviewer-a'; Parameters=$ReviewerAParameters },
        [pscustomobject]@{ Name='reviewer-b'; Parameters=$ReviewerBParameters }
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    $results = @{}
    $firstFailure = $null
    $stopFailures = [System.Collections.Generic.List[string]]::new()
    try {
        Get-Command Start-ThreadJob -ErrorAction Stop | Out-Null
        foreach ($definition in $definitions) {
            Add-ContractReviewRoleReceipts -ArtifactName $definition.Name -Receipts $Receipts
            $parameters = @{}
            foreach ($parameter in $definition.Parameters.GetEnumerator()) { $parameters[$parameter.Key] = $parameter.Value }
            $parameters.Receipts = [System.Collections.Generic.List[string]]::new()
            $job = Start-ThreadJob -Name "contract-review-$($definition.Name)" -ArgumentList $modulePath,$parameters -ScriptBlock {
                param($ModulePath,$Parameters)
                $module = Import-Module $ModulePath -Force -PassThru
                try {
                    $response = & $module { param($RoleParameters) Invoke-ContractReviewRole @RoleParameters } $Parameters
                    [pscustomobject]@{ Succeeded=$true; Response=$response; ErrorMessage=$null }
                } catch {
                    [pscustomobject]@{ Succeeded=$false; Response=$null; ErrorMessage=$_.Exception.Message }
                }
            }
            $entries.Add([pscustomobject]@{
                Name=$definition.Name
                Job=$job
                InvocationPath=Join-Path ([string]$definition.Parameters.RunDirectory) "$($definition.Name).invocation.json"
            })
        }
        Write-Host ("[{0}] both blind reviewers are running concurrently" -f [DateTime]::Now.ToString('HH:mm:ss'))
        $pending = @($entries)
        $nextProgress = [DateTime]::UtcNow.AddSeconds(30)
        while ($pending.Count -gt 0) {
            $finished = @($pending | Where-Object { $_.Job.State -notin @('NotStarted','Running') })
            foreach ($entry in $finished) {
                $jobOutput = @(Receive-Job -Job $entry.Job -ErrorAction SilentlyContinue)
                $result = @($jobOutput | Where-Object { $_.PSObject.Properties.Name -contains 'Succeeded' } | Select-Object -Last 1)
                if ($result.Count -eq 0) {
                    $reason = if ($entry.Job.JobStateInfo.Reason) { $entry.Job.JobStateInfo.Reason.Message } else { "parallel role $($entry.Name) ended in state $($entry.Job.State)" }
                    $result = @([pscustomobject]@{ Succeeded=$false; Response=$null; ErrorMessage=$reason })
                }
                $results[$entry.Name] = $result[0]
                $pending = @($pending | Where-Object { $_.Job.Id -ne $entry.Job.Id })
                if (-not $result[0].Succeeded -and -not $firstFailure) {
                    $firstFailure = [string]$result[0].ErrorMessage
                    foreach ($peer in $pending) {
                        try { Stop-ContractReviewParallelRole -Entry $peer }
                        catch { $stopFailures.Add("$($peer.Name): $($_.Exception.Message)") }
                    }
                }
            }
            if ($pending.Count -gt 0) {
                if ([DateTime]::UtcNow -ge $nextProgress) {
                    Write-Host ("[{0}] blind review pair still running" -f [DateTime]::Now.ToString('HH:mm:ss'))
                    $nextProgress = [DateTime]::UtcNow.AddSeconds(30)
                }
                Start-Sleep -Milliseconds 100
            }
        }
        if ($stopFailures.Count -gt 0) { throw "$firstFailure; peer termination failed: $([string]::Join('; ', $stopFailures))" }
        if ($firstFailure) { throw $firstFailure }
        return [pscustomobject]@{ ReviewerA=$results['reviewer-a'].Response; ReviewerB=$results['reviewer-b'].Response }
    } finally {
        foreach ($entry in $entries) {
            if ($entry.Job.State -in @('NotStarted','Running')) {
                try { Stop-ContractReviewParallelRole -Entry $entry }
                catch { $stopFailures.Add("$($entry.Name): $($_.Exception.Message)") }
            }
            Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
        }
        if ($stopFailures.Count -gt 0) {
            throw "Blind-review cleanup failed: $([string]::Join('; ', $stopFailures))"
        }
    }
}

function Remove-ContractReviewWorktree {
    param([string]$Repository,[string]$Worktree,[int]$TimeoutSeconds)
    if (Test-Path -LiteralPath $Worktree) { [void](Invoke-ContractReviewGit -Repository $Repository -Arguments @('worktree','remove','--force',$Worktree) -TimeoutSeconds $TimeoutSeconds) }
    [void](Invoke-ContractReviewGit -Repository $Repository -Arguments @('worktree','prune') -TimeoutSeconds $TimeoutSeconds)
    if (Test-Path -LiteralPath $Worktree) { throw "Disposable worktree still exists after cleanup: $Worktree" }
}

function Write-ContractReviewPacket {
    param([string]$RunDirectory,[System.Collections.IDictionary]$Packet)
    $jsonPath=Join-Path $RunDirectory 'decision-packet.json'; $markdownPath=Join-Path $RunDirectory 'decision-packet.md'
    Write-ContractReviewAtomicJson -Path $jsonPath -Value $Packet
    $lines=@('# Contract review decision packet','',"- Status: **$($Packet.status)**","- Request: $($Packet.requestId)","- Run: $($Packet.runId)","- Source revision: $($Packet.sourceRevision)","- Execution manifest SHA-256: $($Packet.executionManifestSha256)","- Created: $($Packet.createdUtc)")
    if ($Packet.Contains('blocker')) { $lines+=@('','## Blocker',[string]$Packet.blocker) }
    foreach ($section in @('reviewerA','reviewerB','comparison','reviewerAProof','reviewerBProof','validation','unresolved','stage1','artifactHashes')) {
        if ($Packet.Contains($section)) { $lines+=@('',"## $section",'```json',($Packet[$section] | ConvertTo-Json -Depth 64),'```') }
    }
    Write-ContractReviewAtomicText -Path $markdownPath -Text ([string]::Join("`n",$lines)+"`n")
    (Get-Item -LiteralPath $jsonPath).IsReadOnly=$true; (Get-Item -LiteralPath $markdownPath).IsReadOnly=$true
    return $markdownPath
}

function Start-ContractReview {
    [CmdletBinding()]
    param(
        [string]$RequestPath,[string]$Approval,[string]$RunnerRoot,[string]$ClaudeAdapter,[string]$CodexAdapter,
        [string]$ClaudeModel,[string]$CodexModel,[string]$CodexReasoningEffort,
        [int]$RoleTimeoutSeconds,[int]$GitTimeoutSeconds,[int]$SplitterTimeoutSeconds,[switch]$AllCodex
    )
    $manifestParameters=@{ RequestPath=$RequestPath; RunnerRoot=$RunnerRoot; ClaudeAdapter=$ClaudeAdapter; CodexAdapter=$CodexAdapter; ClaudeModel=$ClaudeModel; CodexModel=$CodexModel; CodexReasoningEffort=$CodexReasoningEffort; RoleTimeoutSeconds=$RoleTimeoutSeconds; GitTimeoutSeconds=$GitTimeoutSeconds; SplitterTimeoutSeconds=$SplitterTimeoutSeconds; AllCodex=$AllCodex }
    $manifest=Get-ContractReviewExecutionManifest @manifestParameters
    $manifestHash=Get-ContractReviewManifestHash -Manifest $manifest
    $expected="APPROVE CONTRACT REVIEW $($manifest.requestId) $manifestHash"
    if ($Approval -cne $expected) { throw "Fresh direct user approval for this exact execution manifest is required. Expected: $expected" }
    $confirmation=Get-ContractReviewExecutionManifest @manifestParameters
    if ((Get-ContractReviewManifestHash -Manifest $confirmation) -cne $manifestHash) { throw 'A bound execution input changed while the run was being prepared; obtain a new approval.' }
    $request=Read-ContractReviewJson -Path $RequestPath -Label 'request'
    if ((Get-ContractReviewSha256 -Path $RequestPath) -cne $manifest.requestSha256) { throw 'Request changed after approval validation.' }
    Assert-ContractReviewProviderReadiness -Manifest $manifest -TimeoutSeconds $GitTimeoutSeconds
    $claim=Claim-ContractReviewApproval -RunnerRoot $RunnerRoot -RequestId $manifest.requestId -ManifestHash $manifestHash
    $runId="{0}-{1}-{2}" -f $manifest.requestId,[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'),[guid]::NewGuid().ToString('N').Substring(0,8)
    $runDirectory=Join-Path (Join-Path $RunnerRoot 'runs') $runId; New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
    $worktree=Join-Path $runDirectory 'worktree'; $inputRoot=Join-Path $runDirectory 'inputs'
    $receipts=[System.Collections.Generic.List[string]]::new()
    $packet=[ordered]@{ status='FAILED'; requestId=$manifest.requestId; ticketId=[string]$request.ticketId; runId=$runId; createdUtc=[DateTime]::UtcNow.ToString('o'); sourceRevision=$manifest.targetRevision; executionManifestSha256=$manifestHash; receipts=$receipts }
    $cleanupFailure=$null
    try {
        Copy-Item -LiteralPath $claim -Destination (Join-Path $runDirectory 'approval-claim.json')
        Copy-Item -LiteralPath $RequestPath -Destination (Join-Path $runDirectory 'request.json')
        Write-ContractReviewAtomicJson -Path (Join-Path $runDirectory 'execution-manifest.json') -Value $manifest
        foreach ($name in @('approval-claim.json','request.json','execution-manifest.json')) { [void]$receipts.Add($name) }
        [void](Invoke-ContractReviewGit -Repository $manifest.targetRepository -Arguments @('worktree','add','--detach',$worktree,$manifest.targetRevision) -TimeoutSeconds $GitTimeoutSeconds)
        Copy-ContractReviewInputs -Worktree $worktree -InputRoot $inputRoot -Request $request
        $inputHashes=[ordered]@{}
        Get-ChildItem -LiteralPath $inputRoot -Recurse -File | Sort-Object FullName | ForEach-Object { $inputHashes[[IO.Path]::GetRelativePath($inputRoot,$_.FullName).Replace('\','/')]=Get-ContractReviewSha256 -Path $_.FullName }
        Write-ContractReviewAtomicJson -Path (Join-Path $runDirectory 'input-manifest.json') -Value $inputHashes; [void]$receipts.Add('input-manifest.json')
        $inputBundle=New-ContractReviewInputBundle -InputRoot $inputRoot
        $basePayload=[ordered]@{ reviewKind=$request.reviewKind; stage1=$request.stage1; reviewMode=$manifest.reviewMode }
        $blindPrompt=New-ContractReviewPrompt -Role 'blind-reviewer' -Request $request -InputBundle $inputBundle -Payload $basePayload
        $reviewerAProvider=if ($AllCodex) { 'codex' } else { 'claude' }; $reviewerAAdapter=if ($AllCodex) { $CodexAdapter } else { $ClaudeAdapter }
        $reviewerAModel=if ($AllCodex) { $CodexModel } else { $ClaudeModel }; $reviewerAEffort=if ($AllCodex) { $CodexReasoningEffort } else { $null }
        $blindReviews=Invoke-ContractReviewParallelRoles -ReviewerAParameters @{
            Adapter=$reviewerAAdapter;Role='blind-reviewer';ArtifactName='reviewer-a';Provider=$reviewerAProvider;Model=$reviewerAModel;ReasoningEffort=$reviewerAEffort
            Prompt=$blindPrompt;RunDirectory=$runDirectory;RunnerRoot=$RunnerRoot;InputRoot=$inputRoot;ProviderCommand=$manifest.providers.reviewerA.commandPath;TimeoutSeconds=$RoleTimeoutSeconds
        } -ReviewerBParameters @{
            Adapter=$CodexAdapter;Role='blind-reviewer';ArtifactName='reviewer-b';Provider='codex';Model=$CodexModel;ReasoningEffort=$CodexReasoningEffort
            Prompt=$blindPrompt;RunDirectory=$runDirectory;RunnerRoot=$RunnerRoot;InputRoot=$inputRoot;ProviderCommand=$manifest.providers.reviewerB.commandPath;TimeoutSeconds=$RoleTimeoutSeconds
        } -Receipts $receipts
        $reviewerA=$blindReviews.ReviewerA
        $reviewerB=$blindReviews.ReviewerB
        $comparisonPayload=[ordered]@{ reviewerA=$reviewerA; reviewerB=$reviewerB; reviewContext=$basePayload }
        $comparison=Invoke-ContractReviewRole -Adapter $CodexAdapter -Role comparator -ArtifactName comparison -Provider codex -Model $CodexModel -ReasoningEffort $CodexReasoningEffort -Prompt (New-ContractReviewPrompt -Role comparator -Request $request -InputBundle $inputBundle -Payload $comparisonPayload) -RunDirectory $runDirectory -RunnerRoot $RunnerRoot -InputRoot $inputRoot -ProviderCommand $manifest.providers.comparator.commandPath -TimeoutSeconds $RoleTimeoutSeconds -Receipts $receipts
        Assert-ContractReviewComparisonAccounting -ReviewerA $reviewerA -ReviewerB $reviewerB -Comparison $comparison
        $proofSet=@($comparison.classifications | Where-Object classification -eq 'NEEDS_PROOF')
        $proofA=Invoke-ContractReviewRole -Adapter $reviewerAAdapter -Role proof-reviewer -ArtifactName reviewer-a-proof -Provider $reviewerAProvider -Model $reviewerAModel -ReasoningEffort $reviewerAEffort -Prompt (New-ContractReviewPrompt -Role proof-reviewer -Request $request -InputBundle $inputBundle -Payload ([ordered]@{ classifications=$proofSet; ownFindings=$reviewerA.findings })) -RunDirectory $runDirectory -RunnerRoot $RunnerRoot -InputRoot $inputRoot -ProviderCommand $manifest.providers.reviewerAProof.commandPath -TimeoutSeconds $RoleTimeoutSeconds -Receipts $receipts
        Assert-ContractReviewProofAccounting -Comparison $comparison -Proof $proofA -Reviewer A
        $proofB=Invoke-ContractReviewRole -Adapter $CodexAdapter -Role proof-reviewer -ArtifactName reviewer-b-proof -Provider codex -Model $CodexModel -ReasoningEffort $CodexReasoningEffort -Prompt (New-ContractReviewPrompt -Role proof-reviewer -Request $request -InputBundle $inputBundle -Payload ([ordered]@{ classifications=$proofSet; ownFindings=$reviewerB.findings })) -RunDirectory $runDirectory -RunnerRoot $RunnerRoot -InputRoot $inputRoot -ProviderCommand $manifest.providers.reviewerBProof.commandPath -TimeoutSeconds $RoleTimeoutSeconds -Receipts $receipts
        Assert-ContractReviewProofAccounting -Comparison $comparison -Proof $proofB -Reviewer B
        $validationPayload=[ordered]@{ reviewerA=$reviewerA; reviewerB=$reviewerB; comparison=$comparison; reviewerAProof=$proofA; reviewerBProof=$proofB; reviewContext=$basePayload }
        $validation=Invoke-ContractReviewRole -Adapter $CodexAdapter -Role validator -ArtifactName validation -Provider codex -Model $CodexModel -ReasoningEffort $CodexReasoningEffort -Prompt (New-ContractReviewPrompt -Role validator -Request $request -InputBundle $inputBundle -Payload $validationPayload) -RunDirectory $runDirectory -RunnerRoot $RunnerRoot -InputRoot $inputRoot -ProviderCommand $manifest.providers.validator.commandPath -TimeoutSeconds $RoleTimeoutSeconds -Receipts $receipts
        Assert-ContractReviewValidationAccounting -ReviewerA $reviewerA -ReviewerB $reviewerB -Comparison $comparison -Validation $validation
        $packet.reviewerA=$reviewerA; $packet.reviewerB=$reviewerB; $packet.comparison=$comparison; $packet.reviewerAProof=$proofA; $packet.reviewerBProof=$proofB; $packet.validation=$validation; $packet.unresolved=@($validation.unresolved)
        if (@($validation.unresolved).Count -gt 0) {
            if (@($validation.stage1Manifest).Count -ne 0) { throw 'Stage 1 materialization is forbidden while user decisions remain.' }
            $packet.status='USER_DECISION_REQUIRED'
        } else {
            $packet.status='COMPLETE'
            if ($request.reviewKind -eq 'stage1') {
                $manifestPath=Join-Path $runDirectory 'stage1-manifest.tsv'
                Write-ContractReviewStage1Manifest -Rows @($validation.stage1Manifest) -Path $manifestPath
                $stageOut=Join-Path $runDirectory 'stage1'; $splitter=Join-Path $worktree 'tools/ai/split-contract.ps1'; $stageSource=Join-Path $worktree ([string]$request.stage1.sourceContract)
                $splitStart=New-ContractReviewProcessStartInfo -FilePath (Get-Command pwsh.exe -ErrorAction Stop).Path -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$splitter,'-Source',$stageSource,'-Manifest',$manifestPath,'-OutDir',$stageOut) -WorkingDirectory $runDirectory -Environment @{} -StdoutPath (Join-Path $runDirectory 'splitter.stdout.log') -StderrPath (Join-Path $runDirectory 'splitter.stderr.log')
                $null=Invoke-ContractReviewBoundedProcess -StartInfo $splitStart.Info -StdoutPath $splitStart.StdoutPath -StderrPath $splitStart.StderrPath -TimeoutSeconds $SplitterTimeoutSeconds -ProgressIntervalSeconds 10 -Label 'Stage 1 splitter'
                $packet.stage1=[ordered]@{ manifest='stage1-manifest.tsv'; output='stage1'; splitterGitObject=$manifest.pinnedObjects['tools/ai/split-contract.ps1'] }
                foreach ($name in @('stage1-manifest.tsv','stage1','splitter.stdout.log','splitter.stderr.log')) { [void]$receipts.Add($name) }
            } elseif (@($validation.stage1Manifest).Count -ne 0) { throw 'A decision review cannot return a Stage 1 manifest.' }
        }
    } catch {
        if ($_.Exception.Message.StartsWith('BLOCKER:')) { $packet.status='BLOCKED_RULES_OR_SETTINGS' } else { $packet.status='FAILED' }
        $packet.blocker=$_.Exception.Message
    } finally {
        try { Remove-ContractReviewWorktree -Repository $manifest.targetRepository -Worktree $worktree -TimeoutSeconds $GitTimeoutSeconds } catch { $cleanupFailure=$_.Exception.Message }
        try {
            $current=Assert-ContractReviewTarget -Repository $manifest.targetRepository -TimeoutSeconds $GitTimeoutSeconds
            if ($current.Revision -ne $manifest.targetRevision) { throw 'Target origin/main changed during the run; the approved revision is no longer current.' }
        } catch { $cleanupFailure=if ($cleanupFailure) { "$cleanupFailure; $($_.Exception.Message)" } else { $_.Exception.Message } }
        if ($cleanupFailure) { $packet.status='FAILED'; $packet.blocker="Cleanup verification failed: $cleanupFailure" }
        $packet.receipts=@($receipts | Where-Object { Test-Path -LiteralPath (Join-Path $runDirectory $_) })
        $packet.artifactHashes=Get-ContractReviewArtifactHashes -RunDirectory $runDirectory
        $packetPath=Write-ContractReviewPacket -RunDirectory $runDirectory -Packet $packet
    }
    return $packetPath
}

Export-ModuleMember -Function Get-ContractReviewApproval,Get-ContractReviewExecutionManifest,Start-ContractReview
