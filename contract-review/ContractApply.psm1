Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ContractReview.Core.ps1')
function Get-ContractApplyManifest {
    param([Parameter(Mandatory=$true)][string]$RunDirectory,[Parameter(Mandatory=$true)][string]$DecisionPath)
    $run=(Resolve-Path -LiteralPath $RunDirectory).Path
    $packetPath=Join-Path $run 'decision-packet.json'; $packet=Read-ContractReviewJson -Path $packetPath -Label 'decision packet'
    if ([string]$packet.status -ne 'COMPLETE') { throw 'Contract apply authorization requires a COMPLETE review packet.' }
    $decision=Read-ContractReviewJson -Path $DecisionPath -Label 'human apply decision'
    $required=@('runId','approvedResolutionIds','deniedResolutionIds','decidedBy','decidedUtc'); $actual=@($decision.PSObject.Properties.Name)
    foreach ($name in $required) { if ($actual -notcontains $name) { throw "Human decision is missing '$name'." } }
    foreach ($name in $actual) { if ($name -notin $required) { throw "Human decision has unsupported property '$name'." } }
    if ([string]$decision.runId -cne [string]$packet.runId) { throw 'Human decision runId does not match the packet.' }
    if ([string]::IsNullOrWhiteSpace([string]$decision.decidedBy)) { throw 'Human decision decidedBy is required.' }
    $decidedText=[string]$decision.decidedUtc;$decidedUtc=[DateTimeOffset]::MinValue
    if(-not$decidedText.EndsWith('Z',[StringComparison]::Ordinal)-or-not[DateTimeOffset]::TryParse($decidedText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$decidedUtc)){throw 'Human decision decidedUtc must be an ISO-8601 UTC timestamp.'}
    $approved=@($decision.approvedResolutionIds); $denied=@($decision.deniedResolutionIds)
    if (@($approved | Where-Object { $_ -in $denied }).Count -gt 0) { throw 'A resolution cannot be both approved and denied.' }
    $resolutionIds=@($packet.validation.resolutions | ForEach-Object { [string]$_.classificationId })
    $decided=@($approved+$denied)
    if($resolutionIds.Count-ne$decided.Count-or@($resolutionIds|Where-Object{$_-notin$decided}).Count-ne0){throw 'Human decision must approve or deny every validated resolution exactly once.'}
    if (@($approved|Sort-Object -Unique).Count -ne $approved.Count -or @($denied|Sort-Object -Unique).Count -ne $denied.Count) { throw 'Human decision contains duplicate resolution IDs.' }
    foreach ($property in $packet.artifactHashes.PSObject.Properties) {
        $artifact=Join-Path $run $property.Name
        if (-not (Test-Path -LiteralPath $artifact -PathType Leaf) -or (Get-ContractReviewSha256 $artifact) -cne [string]$property.Value) { throw "Run artifact changed after review: $($property.Name)" }
    }
    $stageManifest=Join-Path $run 'stage1-manifest.tsv'
    return [ordered]@{ protocolVersion=1; runId=[string]$packet.runId; reviewPacketSha256=Get-ContractReviewSha256 $packetPath; humanDecisionSha256=Get-ContractReviewSha256 $DecisionPath; sourceRevision=[string]$packet.sourceRevision; approvedResolutionIds=$approved; deniedResolutionIds=$denied; stage1ManifestSha256=if(Test-Path $stageManifest){Get-ContractReviewSha256 $stageManifest}else{$null}; runDirectory=$run }
}
function Get-ContractApplyApproval {
    param([Parameter(Mandatory=$true)][string]$RunDirectory,[Parameter(Mandatory=$true)][string]$DecisionPath)
    $manifest=Get-ContractApplyManifest @PSBoundParameters; $manifest.Remove('runDirectory')
    $hash=Get-ContractReviewTextSha256 -Text ($manifest|ConvertTo-Json -Depth 32 -Compress)
    return "APPROVE CONTRACT APPLY $($manifest.runId) $hash"
}
function New-ContractApplyAuthorization {
    param([Parameter(Mandatory=$true)][string]$RunDirectory,[Parameter(Mandatory=$true)][string]$DecisionPath,[Parameter(Mandatory=$true)][string]$Approval)
    $manifest=Get-ContractApplyManifest -RunDirectory $RunDirectory -DecisionPath $DecisionPath; $run=$manifest.runDirectory; $manifest.Remove('runDirectory')
    $hash=Get-ContractReviewTextSha256 -Text ($manifest|ConvertTo-Json -Depth 32 -Compress); $phrase="APPROVE CONTRACT APPLY $($manifest.runId) $hash"
    if($Approval -cne $phrase){throw "Fresh direct user apply approval is required. Expected: $phrase"}
    $manifestOut=Join-Path $run 'contract-apply-manifest.json'; $authorizationOut=Join-Path $run 'contract-apply-authorization.json'
    if((Test-Path $manifestOut)-or(Test-Path $authorizationOut)){throw 'Apply authorization for this run already exists.'}
    Write-ContractReviewAtomicJson -Path $manifestOut -Value $manifest
    Write-ContractReviewAtomicJson -Path $authorizationOut -Value ([ordered]@{runId=$manifest.runId;applyManifestSha256=$hash;authorizedUtc=[DateTime]::UtcNow.ToString('o')})
    (Get-Item $manifestOut).IsReadOnly=$true;(Get-Item $authorizationOut).IsReadOnly=$true
    return $authorizationOut
}
Export-ModuleMember -Function Get-ContractApplyApproval,New-ContractApplyAuthorization
