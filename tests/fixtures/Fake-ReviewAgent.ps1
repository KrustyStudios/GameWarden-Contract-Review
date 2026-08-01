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
function Finding([string]$Id,[string]$Claim){[ordered]@{id=$Id;claim=$Claim;evidence=Evidence;classification='fact';placement=[ordered]@{disposition='MOVE';destinations=@('sample-owner');existingTag='[sample]';proposedTags=@('[sample]');rationale='Generic ownership.'}}}
$scenario=$env:CONTRACT_REVIEW_TEST_SCENARIO;$artifact=$env:CONTRACT_REVIEW_ARTIFACT_NAME;$role=$env:CONTRACT_REVIEW_ROLE;$response=New-Envelope
$roleSchema=Get-Content $env:CONTRACT_REVIEW_SCHEMA_PATH -Raw|ConvertFrom-Json
if($scenario -eq 'BLOCKER'){$response.status='blocker';$response.reason='Pinned review rules conflict.';$response|ConvertTo-Json -Depth 20|Set-Content $env:CONTRACT_REVIEW_OUTPUT_PATH -Encoding utf8;exit 0}
switch($role){
    'blind-reviewer' {
        if($artifact -eq 'reviewer-a'){$response.findings=@(Finding A1 'Parent owns the generic rule.')}else{$response.findings=@(Finding B1 'Child changes the generic rule.')}
        if($scenario -eq 'PROOF_FINDING_GAP' -and $artifact -eq 'reviewer-a'){$response.findings+=@(Finding A2 'A second parent-side finding.')}
        if($scenario -eq 'ROLE_SCHEMA_STAGE1' -and $roleSchema.properties.stage1Manifest.maxItems-ne0){$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('sample-owner');name='[sample]';disposition='MOVE';perDestinationNames=$null})}
    }
    'comparator' {
        $response.classifications=@([ordered]@{id='C1';classification='NEEDS_PROOF';statement='Parent versus child placement.';reviewerAFindingIds=@('A1');reviewerBFindingIds=@('B1');evidence=Evidence;rationale='The reviews differ.'})
        if($scenario -eq 'OMIT_FINDING'){$response.classifications[0].reviewerBFindingIds=@()}
        if($scenario -eq 'UNKNOWN_REF'){$response.classifications[0].reviewerAFindingIds=@('missing')}
        if($scenario -eq 'PROOF_FINDING_GAP'){$response.classifications[0].reviewerAFindingIds=@('A1','A2')}
        if($scenario -eq 'ROLE_LEAK'){$response.findings=@(Finding L1 'Wrong role field.')}
    }
    'proof-reviewer' { $response.proofs=@([ordered]@{classificationId='C1';findingIds=@($(if($artifact -eq 'reviewer-a-proof'){'A1'}else{'B1'}));position='CONFIRM';evidence=Evidence;rationale='The input supports this position.'});if($scenario -eq 'PROOF_GAP'){$response.proofs=@()} }
    'validator' {
        $outcome=if($scenario -in @('COMPLETE','STAGE1','ROLE_SCHEMA_STAGE1')){'ACCEPT_A'}else{'USER_DECISION'}
        $response.resolutions=@([ordered]@{classificationId='C1';outcome=$outcome;acceptedFindingIds=@($(if($outcome -eq 'ACCEPT_A'){'A1'}));evidence=Evidence;rationale='Rechecked against the input.'})
        if($outcome -eq 'USER_DECISION'){$response.unresolved=@([ordered]@{id='C1';reason='The evidence leaves a policy choice.';options=@('parent','child')})}
        if($scenario -eq 'RESOLUTION_GAP'){$response.resolutions=@();$response.unresolved=@()}
        if($scenario -eq 'WRONG_RESOLUTION_FINDING'){$response.resolutions[0].outcome='ACCEPT_A';$response.resolutions[0].acceptedFindingIds=@('B1');$response.unresolved=@()}
        if($scenario -in @('STAGE1','ROLE_SCHEMA_STAGE1')){$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('sample-owner');name='[sample]';disposition='MOVE';perDestinationNames=$null})}
        if($scenario -eq 'STAGE_WITH_UNRESOLVED'){$response.stage1Manifest=@([ordered]@{start=1;end=3;destinations=@('sample-owner');name='[sample]';disposition='MOVE';perDestinationNames=$null})}
    }
    default {throw "Unexpected fake role: $role"}
}
$response|ConvertTo-Json -Depth 20|Set-Content $env:CONTRACT_REVIEW_OUTPUT_PATH -Encoding utf8
