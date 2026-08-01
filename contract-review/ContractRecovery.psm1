Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ContractReview.Core.ps1')
function Repair-InterruptedContractReview {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$RunDirectory,[Parameter(Mandatory=$true)][string]$Reason,[string]$RunnerRoot=(Split-Path -Parent $PSScriptRoot),[ValidateRange(1,3600)][int]$GitTimeoutSeconds=60)
    $run=(Resolve-Path -LiteralPath $RunDirectory).Path; $runsRoot=(Resolve-Path -LiteralPath (Join-Path $RunnerRoot 'runs')).Path
    if(-not(Test-ContractReviewPathWithin -Path $run -Root $runsRoot)-or$run -eq $runsRoot){throw 'RunDirectory must be one child run under this runner\runs directory.'}
    $packetJson=Join-Path $run 'decision-packet.json';$packetMd=Join-Path $run 'decision-packet.md'
    if((Test-Path $packetJson)-or(Test-Path $packetMd)){throw 'Run already has a final packet; recovery will not replace it.'}
    $execution=Read-ContractReviewJson -Path (Join-Path $run 'execution-manifest.json') -Label 'execution manifest'
    $target=[string]$execution.targetRepository;$worktree=Join-Path $run 'worktree';$terminated=@()
    foreach($receipt in Get-ChildItem -LiteralPath $run -Filter '*.invocation.json' -File){
        $childId=Stop-ContractReviewRecordedProcessTree -InvocationPath $receipt.FullName
        if($null-ne$childId){$terminated+=$childId}
    }
    if(Test-Path $worktree){[void](Invoke-ContractReviewGit -Repository $target -Arguments @('worktree','remove','--force',$worktree) -TimeoutSeconds $GitTimeoutSeconds)}
    [void](Invoke-ContractReviewGit -Repository $target -Arguments @('worktree','prune') -TimeoutSeconds $GitTimeoutSeconds)
    if(Test-Path $worktree){throw 'Interrupted worktree survived cleanup; no packet was written.'}
    $current=Assert-ContractReviewTarget -Repository $target -TimeoutSeconds $GitTimeoutSeconds
    $packet=[ordered]@{status='FAILED';requestId=[string]$execution.requestId;runId=Split-Path -Leaf $run;sourceRevision=[string]$execution.targetRevision;createdUtc=[DateTime]::UtcNow.ToString('o');blocker="Interrupted run recovered: $Reason";terminatedProcessIds=$terminated;targetRevisionAtRecovery=$current.Revision;artifactHashes=Get-ContractReviewArtifactHashes -RunDirectory $run}
    Write-ContractReviewAtomicJson -Path $packetJson -Value $packet
    $markdown=@('# Contract review decision packet','','- Status: **FAILED**',"- Run: $($packet.runId)","- Source revision: $($packet.sourceRevision)",'','## Recovery reason',$packet.blocker,'','## Terminated process IDs','```json',($terminated|ConvertTo-Json),'```','','## Artifact hashes','```json',($packet.artifactHashes|ConvertTo-Json -Depth 64),'```') -join "`n"
    Write-ContractReviewAtomicText -Path $packetMd -Text ($markdown+"`n");(Get-Item $packetJson).IsReadOnly=$true;(Get-Item $packetMd).IsReadOnly=$true
    return $packetMd
}
Export-ModuleMember -Function Repair-InterruptedContractReview
