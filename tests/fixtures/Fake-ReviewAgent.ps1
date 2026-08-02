Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$prompt=[IO.File]::ReadAllText($env:CONTRACT_REVIEW_PROMPT_FILE)
if($prompt -match '(?i)gw-hidden|ticketId|APPROVE CONTRACT REVIEW'){throw 'ticket firewall failed: protected coordinator data reached an agent prompt'}
foreach($character in $prompt.ToCharArray()){if([int]$character -lt 32 -and $character -notin @("`r","`n","`t")){throw 'prompt contains a forbidden control character'}}
function New-Envelope { [ordered]@{status='ok';reason=$null;findings=@();classifications=@();proofs=@();resolutions=@();unresolved=@();stage1Manifest=@()} }
function Evidence {
    $excerpt=switch($env:CONTRACT_REVIEW_TEST_SCENARIO){
        'BAD_EVIDENCE'{'Invented source text.'}
        'ELLIPSIS_EVIDENCE'{'A ... rule.'}
        'WRAPPED_EVIDENCE'{"A generic`r`nrule."}
        default{'A generic rule.'}
    }
    @([ordered]@{source='contracts/sample.md';locator='rule paragraph';excerpt=$excerpt})
}
function Finding([string]$Id,[string]$Claim,[string]$ExistingTag='[sample]',[string]$ProposedTag='[sample renamed]'){
    [ordered]@{id=$Id;claim=$Claim;evidence=Evidence;classification='fact';placement=[ordered]@{disposition='MOVE';destinations=@('contracts/SAMPLE_CONTRACT.md');existingTag=$ExistingTag;proposedTags=@($ProposedTag);fragments=@();rationale='Generic ownership.'}}
}
$scenario=$env:CONTRACT_REVIEW_TEST_SCENARIO;$artifact=$env:CONTRACT_REVIEW_ARTIFACT_NAME;$role=$env:CONTRACT_REVIEW_ROLE;$response=New-Envelope
$isStage1=$prompt -match '"reviewKind":"stage1"'
$runDirectory=Split-Path -Parent $env:CONTRACT_REVIEW_OUTPUT_PATH
if($role-eq'blind-reviewer'-and$scenario-in@('REQUIRE_CONCURRENT_BLIND','REVIEWER_A_BLOCKER')){
    $coordinationRoot=$env:CONTRACT_REVIEW_TEST_COORDINATION_ROOT
    if([string]::IsNullOrWhiteSpace($coordinationRoot)){throw 'Blind-review test coordination root was not supplied.'}
    $peer=if($artifact-eq'reviewer-a'){'reviewer-b'}else{'reviewer-a'}
    [IO.File]::WriteAllText((Join-Path $coordinationRoot "$artifact.concurrent-ready"),'ready',[Text.UTF8Encoding]::new($false))
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while(-not(Test-Path -LiteralPath (Join-Path $coordinationRoot "$peer.concurrent-ready"))-and[DateTime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 50}
    if(-not(Test-Path -LiteralPath (Join-Path $coordinationRoot "$peer.concurrent-ready"))){throw "Blind reviewer peer '$peer' did not start concurrently."}
    if($scenario-eq'REVIEWER_A_BLOCKER'){
        if($artifact-eq'reviewer-a'){$response.status='blocker';$response.reason='Pinned review rules conflict.';$response|ConvertTo-Json -Depth 20|Set-Content $env:CONTRACT_REVIEW_OUTPUT_PATH -Encoding utf8;exit 0}
        $peerChild=Start-Process -FilePath (Get-Command pwsh.exe).Path -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 300') -PassThru
        [ordered]@{childProcessId=$peerChild.Id}|ConvertTo-Json|Set-Content (Join-Path $runDirectory 'reviewer-b-peer-child.json') -Encoding utf8
        Start-Sleep -Seconds 60
    }
}
$roleSchema=Get-Content $env:CONTRACT_REVIEW_SCHEMA_PATH -Raw|ConvertFrom-Json
if($scenario -eq 'BLOCKER'){$response.status='blocker';$response.reason='Pinned review rules conflict.';$response|ConvertTo-Json -Depth 20|Set-Content $env:CONTRACT_REVIEW_OUTPUT_PATH -Encoding utf8;exit 0}
switch($role){
    'blind-reviewer' {
        if($artifact -eq 'reviewer-a'){$response.findings=@(Finding A1 'Parent owns the generic rule.')}else{$response.findings=@(Finding B1 'Child changes the generic rule.')}
        if($scenario -eq 'COLLIDING_FINDING_IDS'){$response.findings[0].id='F1'}
        if($isStage1){$response.findings[0].placement.fragments=@([ordered]@{start=1;end=3;destination='contracts/SAMPLE_CONTRACT.md';proposedTag='[sample renamed]'})}
        if($scenario -eq 'TAG_JUDGMENT'){
            if($artifact -eq 'reviewer-a'){
                $response.findings[0].placement.proposedTags=@('[server install]')
                $response.findings+=@(Finding A2 'The progress fallback stays in the same contract.' '[sample progress]' '[output fallback]')
            }else{
                $response.findings[0].placement.proposedTags=@('[steamcmd installation]')
                $response.findings+=@(Finding B2 'The progress fallback stays in the same contract.' '[sample progress]' '[stdout progress fallback]')
            }
            $response.findings[0].placement.fragments=@([ordered]@{start=1;end=3;destination='contracts/SAMPLE_CONTRACT.md';proposedTag=$response.findings[0].placement.proposedTags[0]})
            $response.findings[1].placement.fragments=@([ordered]@{start=4;end=6;destination='contracts/SAMPLE_CONTRACT.md';proposedTag=$response.findings[1].placement.proposedTags[0]})
        }
        if($scenario -eq 'DUPLICATE_DESTINATIONS'){$response.findings[0].placement.destinations=@('contracts/SAMPLE_CONTRACT.md','contracts/SAMPLE_CONTRACT.md')}
        if($scenario -eq 'DUPLICATE_PROPOSED_TAGS'){$response.findings[0].placement.proposedTags=@('[sample]','[sample]')}
        if($scenario -eq 'PROOF_FINDING_GAP' -and $artifact -eq 'reviewer-a'){$response.findings+=@(Finding A2 'A second parent-side finding.')}
        if($scenario -eq 'DESTINATION_FRAGMENT_SPLIT' -and $artifact -eq 'reviewer-a'){$response.findings[0].placement.disposition='SPLIT';$response.findings[0].placement.destinations=@('contracts/SAMPLE_CONTRACT.md','contracts/APP_CONTRACT.md');$response.findings[0].placement.proposedTags=@('[sample fragment]','[app fragment]');$response.findings[0].placement.fragments=@([ordered]@{start=1;end=1;destination='contracts/SAMPLE_CONTRACT.md';proposedTag='[sample fragment]'},[ordered]@{start=2;end=3;destination='contracts/APP_CONTRACT.md';proposedTag='[app fragment]'})}
        if($scenario -eq 'ROLE_SCHEMA_STAGE1' -and $roleSchema.properties.stage1Manifest.maxItems-ne0){$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('contracts/SAMPLE_CONTRACT.md');name='[sample]';disposition='MOVE';perDestinationNames=@('[sample renamed]');findingIds=@('A1')})}
    }
    'comparator' {
        $response.classifications=@([ordered]@{id='C1';classification='NEEDS_PROOF';statement='Parent versus child placement.';reviewerAFindingIds=@('A1');reviewerBFindingIds=@('B1');evidence=Evidence;rationale='The reviews differ.'})
        if($scenario -eq 'COLLIDING_FINDING_IDS'){$response.classifications[0].reviewerAFindingIds=@('F1');$response.classifications[0].reviewerBFindingIds=@('F1')}
        if($scenario -eq 'TAG_JUDGMENT'){
            $response.classifications[0].classification='RESOLVED_BY_JUDGMENT';$response.classifications[0].statement='Both proposed tags are compliant; choose the clearer replacement.';$response.classifications[0].rationale='[steamcmd installation] is the clearer compliant name for this contract.'
            $response.classifications+=@([ordered]@{id='C2';classification='RESOLVED_BY_JUDGMENT';statement='Both progress tags are compliant; choose the clearer replacement.';reviewerAFindingIds=@('A2');reviewerBFindingIds=@('B2');evidence=Evidence;rationale='[stdout progress fallback] is the clearer compliant name for this behavior.'})
        }
        if($scenario -eq 'OMIT_FINDING'){$response.classifications[0].reviewerBFindingIds=@()}
        if($scenario -eq 'UNKNOWN_REF'){$response.classifications[0].reviewerAFindingIds=@('missing')}
        if($scenario -eq 'PROOF_FINDING_GAP'){$response.classifications[0].reviewerAFindingIds=@('A1','A2')}
        if($scenario -eq 'DUPLICATE_A_FINDING_REFS'){$response.classifications[0].reviewerAFindingIds=@('A1','A1')}
        if($scenario -eq 'DUPLICATE_B_FINDING_REFS'){$response.classifications[0].reviewerBFindingIds=@('B1','B1')}
        if($scenario -eq 'ROLE_LEAK'){$response.findings=@(Finding L1 'Wrong role field.')}
    }
    'proof-reviewer' {
        $proofFindingId=if($scenario -eq 'COLLIDING_FINDING_IDS'){'F1'}elseif($artifact -eq 'reviewer-a-proof'){'A1'}else{'B1'}
        $response.proofs=@([ordered]@{classificationId='C1';findingIds=@($proofFindingId);position='CONFIRM';evidence=Evidence;rationale='The input supports this position.'})
        if($scenario -eq 'PROOF_GAP'){$response.proofs=@()}
        if($scenario -eq 'EMPTY_PROOF_EVIDENCE'){$response.proofs[0].evidence=@()}
        if($scenario -eq 'DUPLICATE_PROOF_FINDING_REFS'){$response.proofs[0].findingIds=@($response.proofs[0].findingIds[0],$response.proofs[0].findingIds[0])}
    }
    'validator' {
        $outcome=if($scenario -eq 'COLLIDING_FINDING_IDS'){'ACCEPT_BOTH'}elseif($scenario -in @('COMPLETE','STAGE1','ROLE_SCHEMA_STAGE1','DESTINATION_FRAGMENT_SPLIT')){'ACCEPT_A'}elseif($scenario -eq 'TAG_JUDGMENT'){'ACCEPT_B'}else{'USER_DECISION'}
        $acceptedFindingIds=@($(if($outcome -eq 'ACCEPT_A'){'A:A1'}elseif($outcome -eq 'ACCEPT_B'){'B:B1'}elseif($outcome -eq 'ACCEPT_BOTH'){'A:F1';'B:F1'}))
        $response.resolutions=@([ordered]@{classificationId='C1';outcome=$outcome;acceptedFindingIds=$acceptedFindingIds;evidence=Evidence;rationale='Rechecked against the input.'})
        if($scenario -eq 'TAG_JUDGMENT'){$response.resolutions+=@([ordered]@{classificationId='C2';outcome='ACCEPT_B';acceptedFindingIds=@('B:B2');evidence=Evidence;rationale='Rechecked the second independent tag choice against the input.'})}
        if($outcome -eq 'USER_DECISION'){$response.unresolved=@([ordered]@{id='C1';reason='The evidence leaves a policy choice.';options=@('parent','child')})}
        if($scenario -eq 'RESOLUTION_GAP'){$response.resolutions=@();$response.unresolved=@()}
        if($scenario -eq 'WRONG_RESOLUTION_FINDING'){$response.resolutions[0].outcome='ACCEPT_A';$response.resolutions[0].acceptedFindingIds=@('B:B1');$response.unresolved=@()}
        if($scenario -eq 'DUPLICATE_ACCEPTED_FINDING_REFS'){$response.resolutions[0].outcome='ACCEPT_A';$response.resolutions[0].acceptedFindingIds=@('A:A1','A:A1');$response.unresolved=@()}
        if($scenario -eq 'DUPLICATE_OPTIONS'){$response.unresolved[0].options=@('parent','parent')}
        if($scenario -in @('STAGE1','ROLE_SCHEMA_STAGE1')){$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('contracts/SAMPLE_CONTRACT.md');name='[sample]';disposition='MOVE';perDestinationNames=@('[sample renamed]');findingIds=@('A:A1')})}
        if($scenario -eq 'DESTINATION_FRAGMENT_SPLIT'){$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('contracts/SAMPLE_CONTRACT.md','contracts/APP_CONTRACT.md');name='[sample]';disposition='SPLIT';perDestinationNames=@('[sample fragment]','[app fragment]');findingIds=@('A:A1')})}
        if($scenario -eq 'DUPLICATE_STAGE_DESTINATIONS'){$response.resolutions[0].outcome='ACCEPT_A';$response.resolutions[0].acceptedFindingIds=@('A:A1');$response.unresolved=@();$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('contracts/SAMPLE_CONTRACT.md','contracts/SAMPLE_CONTRACT.md');name='[sample]';disposition='MOVE';perDestinationNames=@('[sample renamed]');findingIds=@('A:A1')})}
        if($scenario -eq 'DUPLICATE_STAGE_NAMES'){$response.resolutions[0].outcome='ACCEPT_A';$response.resolutions[0].acceptedFindingIds=@('A:A1');$response.unresolved=@();$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('contracts/SAMPLE_CONTRACT.md');name='[sample]';disposition='MOVE';perDestinationNames=@('[sample renamed]','[sample renamed]');findingIds=@('A:A1')})}
        if($scenario -eq 'STAGE_WITH_UNRESOLVED'){$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('contracts/SAMPLE_CONTRACT.md');name='[sample]';disposition='MOVE';perDestinationNames=@('[sample renamed]');findingIds=@('A:A1')})}
    }
    default {throw "Unexpected fake role: $role"}
}
$peerBlindness=$role-eq'blind-reviewer'-and$scenario-eq'REQUIRE_PEER_BLINDNESS'
if($peerBlindness-and$artifact-eq'reviewer-b'){
    $coordinationRoot=$env:CONTRACT_REVIEW_TEST_COORDINATION_ROOT
    $completionMarker=Join-Path $coordinationRoot 'reviewer-a-response-ready'
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while(-not(Test-Path -LiteralPath $completionMarker)-and[DateTime]::UtcNow-lt$deadline){Start-Sleep -Milliseconds 50}
    if(-not(Test-Path -LiteralPath $completionMarker)){throw 'Reviewer A did not finish before the peer-blindness check.'}
    $requestId=$env:CONTRACT_REVIEW_TEST_REQUEST_ID
    $runnerRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $sharedRuns=@(Get-ChildItem -LiteralPath (Join-Path $runnerRoot 'runs') -Directory|Where-Object Name -Like "$requestId-*")
    if($sharedRuns.Count-ne1){throw "Could not identify the shared run for $requestId."}
    if(Test-Path -LiteralPath (Join-Path $sharedRuns[0].FullName 'reviewer-a.json')){throw 'Reviewer A answer was published before Reviewer B ended.'}
}
$response|ConvertTo-Json -Depth 20|Set-Content $env:CONTRACT_REVIEW_OUTPUT_PATH -Encoding utf8
if($peerBlindness-and$artifact-eq'reviewer-a'){
    [IO.File]::WriteAllText((Join-Path $env:CONTRACT_REVIEW_TEST_COORDINATION_ROOT 'reviewer-a-response-ready'),'ready',[Text.UTF8Encoding]::new($false))
}
