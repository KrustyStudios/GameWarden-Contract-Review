Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path -Parent $PSScriptRoot
$temp=Join-Path ([IO.Path]::GetTempPath()) ('contract-review-tests-'+[guid]::NewGuid().ToString('N'))
$target=Join-Path $temp 'target';$runnerRoot=Join-Path $temp 'runner';$requests=Join-Path $temp 'requests'
$script:gitExe=(Get-Command git.exe -ErrorAction Stop).Source
function Assert-That([bool]$Condition,[string]$Message){if(-not$Condition){throw $Message}}
function Git([string[]]$Arguments){$output=& $script:gitExe -C $target @Arguments 2>&1;if($LASTEXITCODE-ne0){throw "fixture git failed: $($output-join "`n")"};return($output-join "`n").Trim()}
function Write-Json([string]$Path,[object]$Value){$Value|ConvertTo-Json -Depth 32|Set-Content -LiteralPath $Path -Encoding utf8}
function New-Request([string]$Id,[string]$Kind='decision'){
    $path=Join-Path $requests "$Id.json"
    $stage=if($Kind-eq'stage1'){[ordered]@{enabled=$true;sourceContract='contracts/sample.md'}}else{[ordered]@{enabled=$false;sourceContract=$null}}
    Write-Json $path ([ordered]@{requestId=$Id;ticketId='gw-hidden';targetRepository=$target;reviewKind=$Kind;reviewSubject='Generic ownership';neutralQuestion='Which contract owns the generic rule?';sources=@('contracts/sample.md');stage1=$stage})
    return $path
}
function Invoke-FakeRun([string]$Id,[string]$Scenario='',[string]$Kind='decision',[string]$Adapter=$script:fake,[int]$Timeout=20){
    $request=New-Request $Id $Kind;$env:CONTRACT_REVIEW_TEST_SCENARIO=$Scenario
    try{
        $base=@{RequestPath=$request;RunnerRoot=$runnerRoot;ClaudeAdapter=$Adapter;CodexAdapter=$Adapter;ClaudeModel='claude-fable-5';CodexModel='gpt-5.6-sol';CodexReasoningEffort='max';RoleTimeoutSeconds=$Timeout;GitTimeoutSeconds=20;SplitterTimeoutSeconds=20}
        $approval=Get-ContractReviewApproval @base
        $packetPath=Start-ContractReview @base -Approval $approval
        return [pscustomobject]@{Request=$request;Approval=$approval;PacketPath=$packetPath;Packet=Get-Content ($packetPath-replace'\.md$','.json') -Raw|ConvertFrom-Json;RunDirectory=Split-Path -Parent $packetPath}
    }finally{Remove-Item Env:\CONTRACT_REVIEW_TEST_SCENARIO -ErrorAction SilentlyContinue}
}
function Invoke-LauncherRun([string]$Id,[string]$Scenario){
    $request=New-Request $Id;$env:CONTRACT_REVIEW_TEST_SCENARIO=$Scenario
    try{
        $base=@{RequestPath=$request;RunnerRoot=$runnerRoot;ClaudeAdapter=$script:fake;CodexAdapter=$script:fake;ClaudeModel='claude-fable-5';CodexModel='gpt-5.6-sol';CodexReasoningEffort='max';RoleTimeoutSeconds=20;GitTimeoutSeconds=20;SplitterTimeoutSeconds=20}
        $approval=Get-ContractReviewApproval @base
        $output=& pwsh -NoLogo -NoProfile -NonInteractive -File $script:runner -RequestPath $request -RunnerRoot $runnerRoot -ClaudeAdapter $script:fake -CodexAdapter $script:fake -RoleTimeoutSeconds 20 -GitTimeoutSeconds 20 -SplitterTimeoutSeconds 20 -NoSound -Approval $approval 2>&1
        $exitCode=$LASTEXITCODE
        $packetPath=@($output|ForEach-Object{[string]$_}|Where-Object{$_-match'decision-packet\.md$'}|Select-Object -Last 1)
        Assert-That ($packetPath.Count-eq1) "Launcher did not preserve the packet path: $($output-join ' | ')"
        return [pscustomobject]@{ExitCode=$exitCode;PacketPath=$packetPath[0];Packet=Get-Content ($packetPath[0]-replace'\.md$','.json') -Raw|ConvertFrom-Json}
    }finally{Remove-Item Env:\CONTRACT_REVIEW_TEST_SCENARIO -ErrorAction SilentlyContinue}
}
try{
    $parseFiles=@((Join-Path $sourceRoot 'Start-ContractReview.ps1'),(Join-Path $sourceRoot 'Recover-InterruptedContractReview.ps1'))+@(Get-ChildItem (Join-Path $sourceRoot 'contract-review') -File | Where-Object Extension -in @('.ps1','.psm1') | ForEach-Object FullName)+@(Get-ChildItem (Join-Path $sourceRoot 'tests') -Recurse -File -Filter '*.ps1' | ForEach-Object FullName)
    foreach($parseFile in $parseFiles){$tokens=$null;$errors=$null;[Management.Automation.Language.Parser]::ParseFile($parseFile,[ref]$tokens,[ref]$errors)|Out-Null;if($errors.Count){throw "PowerShell parse failure in $parseFile`: $($errors.Message -join '; ')"}}
    foreach($schema in Get-ChildItem (Join-Path $sourceRoot 'schemas') -File -Filter '*.json'){Get-Content $schema.FullName -Raw|ConvertFrom-Json -ErrorAction Stop|Out-Null}
    New-Item -ItemType Directory -Path $target,$runnerRoot,$requests|Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'Start-ContractReview.ps1'),(Join-Path $sourceRoot 'Recover-InterruptedContractReview.ps1') -Destination $runnerRoot
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'contract-review') -Destination $runnerRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'schemas') -Destination $runnerRoot -Recurse
    Copy-Item -LiteralPath (Join-Path $sourceRoot 'tests') -Destination $runnerRoot -Recurse
    $script:runner=Join-Path $runnerRoot 'Start-ContractReview.ps1';$script:fake=Join-Path $runnerRoot 'tests\fixtures\Fake-ReviewAgent.ps1'
    Import-Module (Join-Path $runnerRoot 'contract-review\ContractReview.psm1') -Force
    . (Join-Path $runnerRoot 'contract-review\ContractReview.Runtime.ps1');. (Join-Path $runnerRoot 'contract-review\ContractReview.Validation.ps1')
    $blindSchemaPath=Join-Path $requests 'blind-response.schema.json';$validatorSchemaPath=Join-Path $requests 'validator-response.schema.json';$baseSchemaPath=Join-Path $runnerRoot 'schemas\agent-response.schema.json'
    [void](New-ContractReviewRoleSchema -BaseSchemaPath $baseSchemaPath -Role blind-reviewer -Path $blindSchemaPath)
    [void](New-ContractReviewRoleSchema -BaseSchemaPath $baseSchemaPath -Role validator -Path $validatorSchemaPath)
    $blindSchema=Get-Content $blindSchemaPath -Raw|ConvertFrom-Json;$validatorSchema=Get-Content $validatorSchemaPath -Raw|ConvertFrom-Json
    Assert-That ($blindSchema.properties.stage1Manifest.maxItems-eq0-and$blindSchema.properties.classifications.maxItems-eq0) 'Blind schema did not mechanically forbid role-inappropriate arrays.'
    Assert-That ($validatorSchema.properties.stage1Manifest.PSObject.Properties.Name-notcontains'maxItems'-and$validatorSchema.properties.findings.maxItems-eq0) 'Validator schema did not allow only validator-owned arrays.'
    $rolePrompt=New-ContractReviewPrompt -Role blind-reviewer -Request ([pscustomobject]@{reviewSubject='subject';neutralQuestion='question'}) -InputBundle 'input' -Payload $null
    Assert-That ($rolePrompt-match'Only these response arrays may be non-empty for blind-reviewer: findings\.') 'Blind prompt omitted its explicit role-field contract.'
    New-Item -ItemType Directory -Path (Join-Path $target 'contracts'),(Join-Path $target '.design'),(Join-Path $target 'tools\ai')|Out-Null
    [IO.File]::WriteAllText((Join-Path $target 'contracts\sample.md'),"# Sample`n`nA generic rule.",[Text.UTF8Encoding]::new($false))
    Set-Content (Join-Path $target 'AI_RULES.md') 'Rules apply. The epic governs review protocol.' -Encoding utf8
    Set-Content (Join-Path $target 'AI_GUARDRAILS.md') 'No contract edits during review.' -Encoding utf8
    Set-Content (Join-Path $target 'contracts\APP_CONTRACT.md') '[app] Generic rules have one owner.' -Encoding utf8
    Set-Content (Join-Path $target '.design\contract-epic.md') 'Ticket content is excluded. MOVE is byte-exact.' -Encoding utf8
    Copy-Item (Join-Path $sourceRoot 'tests\fixtures\Fake-Splitter.ps1') (Join-Path $target 'tools\ai\split-contract.ps1')
    Git @('init','--initial-branch=main')|Out-Null;Git @('config','user.email','loop-test@example.invalid')|Out-Null;Git @('config','user.name','Loop Test')|Out-Null;Git @('add','.')|Out-Null;Git @('commit','-m','fixture')|Out-Null

    Write-Host 'adapter boundary tests...'
    $adapterPrompt=Join-Path $requests 'adapter-prompt.txt';$adapterOutput=Join-Path $requests 'adapter-output.json';$adapterMetadata=Join-Path $requests 'adapter-metadata.json'
    Set-Content $adapterPrompt 'Return the empty valid envelope.' -Encoding utf8
    $env:CONTRACT_REVIEW_PROMPT_FILE=$adapterPrompt;$env:CONTRACT_REVIEW_OUTPUT_PATH=$adapterOutput;$env:CONTRACT_REVIEW_METADATA_PATH=$adapterMetadata;$env:CONTRACT_REVIEW_SCHEMA_PATH=Join-Path $runnerRoot 'schemas\agent-response.schema.json'
    $env:CONTRACT_REVIEW_MODEL='claude-fable-5';$env:CONTRACT_REVIEW_PROVIDER_COMMAND=Join-Path $runnerRoot 'tests\fixtures\Fake-StructuredCli.ps1'
    & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $runnerRoot 'contract-review\Invoke-ClaudeReview.ps1');if($LASTEXITCODE-ne0){throw 'Claude adapter fixture failed.'}
    $claudeMeta=Get-Content $adapterMetadata -Raw|ConvertFrom-Json;Assert-That ($claudeMeta.safeMode-and$claudeMeta.promptTransport-eq'stdin'-and@($claudeMeta.tools).Count-eq0) 'Claude adapter isolation flags were not enforced.'
    Remove-Item $adapterOutput;New-Item -ItemType File -Path (Join-Path $runnerRoot 'tests\fixtures\provider-late-auth.flag')|Out-Null
    $lateAuthOutput=& pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $runnerRoot 'contract-review\Invoke-ClaudeReview.ps1') 2>&1;$lateAuthExit=$LASTEXITCODE
    Remove-Item (Join-Path $runnerRoot 'tests\fixtures\provider-late-auth.flag');Assert-That ($lateAuthExit-eq79-and($lateAuthOutput-join "`n")-match'CONTRACT_REVIEW_PROVIDER_AUTHENTICATION_BLOCKER') 'Claude adapter did not classify a late OAuth rejection as a provider-authentication blocker.'
    Remove-Item $adapterOutput -ErrorAction SilentlyContinue;$env:CONTRACT_REVIEW_MODEL='gpt-5.6-sol';$env:CONTRACT_REVIEW_REASONING_EFFORT='max';$env:CONTRACT_REVIEW_PROVIDER_COMMAND=Join-Path $runnerRoot 'tests\fixtures\Fake-StructuredCli.ps1'
    & pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $runnerRoot 'contract-review\Invoke-CodexReview.ps1');if($LASTEXITCODE-ne0){throw 'Codex adapter fixture failed.'}
    $codexMeta=Get-Content $adapterMetadata -Raw|ConvertFrom-Json;Assert-That ($codexMeta.ephemeral-and$codexMeta.ignoreUserConfig-and$codexMeta.promptTransport-eq'stdin') 'Codex adapter isolation flags were not enforced.'
    foreach($name in @('CONTRACT_REVIEW_PROMPT_FILE','CONTRACT_REVIEW_OUTPUT_PATH','CONTRACT_REVIEW_METADATA_PATH','CONTRACT_REVIEW_SCHEMA_PATH','CONTRACT_REVIEW_MODEL','CONTRACT_REVIEW_REASONING_EFFORT','CONTRACT_REVIEW_PROVIDER_COMMAND')){Remove-Item "Env:\$name" -ErrorAction SilentlyContinue}
    Write-Host 'adapter boundary tests passed'

    $env:CONTRACT_REVIEW_CLAUDE_COMMAND=Join-Path $runnerRoot 'tests\fixtures\Fake-StructuredCli.ps1';$env:CONTRACT_REVIEW_CODEX_COMMAND=$env:CONTRACT_REVIEW_CLAUDE_COMMAND
    $readinessFlag=Join-Path $runnerRoot 'tests\fixtures\provider-logged-out.flag'
    $seedRequest=New-Request 'fixture-provider-seed-auth-001';New-Item -ItemType File -Path $readinessFlag|Out-Null
    $seedBlocked=$false;try{Get-ContractReviewApproval -RequestPath $seedRequest -RunnerRoot $runnerRoot -ClaudeAdapter $script:fake -CodexAdapter $script:fake -ClaudeModel 'claude-fable-5' -CodexModel 'gpt-5.6-sol' -CodexReasoningEffort max -RoleTimeoutSeconds 20 -GitTimeoutSeconds 20 -SplitterTimeoutSeconds 20|Out-Null}catch{$seedBlocked=$_.Exception.Message-match'claude.*not authenticated'}
    Remove-Item $readinessFlag;Assert-That $seedBlocked 'A logged-out provider was allowed to seed an approval.'
    $claimRequest=New-Request 'fixture-provider-claim-auth-001';$claimBase=@{RequestPath=$claimRequest;RunnerRoot=$runnerRoot;ClaudeAdapter=$script:fake;CodexAdapter=$script:fake;ClaudeModel='claude-fable-5';CodexModel='gpt-5.6-sol';CodexReasoningEffort='max';RoleTimeoutSeconds=20;GitTimeoutSeconds=20;SplitterTimeoutSeconds=20}
    $claimApproval=Get-ContractReviewApproval @claimBase;New-Item -ItemType File -Path $readinessFlag|Out-Null
    $claimBlocked=$false;try{Start-ContractReview @claimBase -Approval $claimApproval|Out-Null}catch{$claimBlocked=$_.Exception.Message-match'claude.*not authenticated'}
    Remove-Item $readinessFlag;Assert-That $claimBlocked 'Provider readiness was not rechecked immediately before claim.'
    $claimHash=$claimApproval.Split(' ')[-1];Assert-That (-not(Test-Path (Join-Path $runnerRoot "approval-receipts\fixture-provider-claim-auth-001-$claimHash.json"))) 'Failed provider readiness consumed the one-time approval.'
    $env:SHOULD_NOT_REACH_CONTRACT_REVIEW='secret-sentinel'
    $default=Invoke-FakeRun 'fixture-default-001'
    Remove-Item Env:\SHOULD_NOT_REACH_CONTRACT_REVIEW
    Assert-That ($default.Packet.status-eq'USER_DECISION_REQUIRED') "default status: $($default.Packet.status)"
    Assert-That (@($default.Packet.reviewerA.findings).Count-eq1-and@($default.Packet.comparison.classifications).Count-eq1) 'Packet omitted initial/comparison results.'
    Assert-That (@($default.Packet.validation.resolutions).Count-eq1-and@($default.Packet.unresolved).Count-eq1) 'Packet omitted resolutions/unresolved choices.'
    $execution=Get-Content (Join-Path $default.RunDirectory 'execution-manifest.json') -Raw|ConvertFrom-Json
    Assert-That (@($execution.providers.PSObject.Properties.Name).Count-eq6-and$execution.providers.reviewerAProof.commandSha256-match'^[a-f0-9]{64}$') 'Execution manifest omitted proof-role provider command bindings.'
    $invocation=Get-Content (Join-Path $default.RunDirectory 'reviewer-a.invocation.json') -Raw|ConvertFrom-Json;Assert-That (-not[string]::IsNullOrWhiteSpace([string]$invocation.adapterProcessStartTimeUtc)) 'Invocation receipt omitted adapter process identity.'
    $promptA=Get-FileHash (Join-Path $default.RunDirectory 'reviewer-a.prompt.txt');$promptB=Get-FileHash (Join-Path $default.RunDirectory 'reviewer-b.prompt.txt')
    Assert-That ($promptA.Hash-eq$promptB.Hash) 'Blind reviewers did not receive byte-identical prompts.'
    $promptText=Get-Content (Join-Path $default.RunDirectory 'reviewer-a.prompt.txt') -Raw
    Assert-That ($promptText-notmatch'gw-hidden|ticketId|APPROVE CONTRACT REVIEW') 'Ticket/approval data crossed the prompt firewall.'
    Assert-That (-not(Test-Path (Join-Path $default.RunDirectory 'worktree'))) 'Disposable worktree survived.'
    Assert-That ((Git @('status','--porcelain'))-eq'') 'Target became dirty.'
    $markdown=Get-Content $default.PacketPath -Raw;Assert-That ($markdown-match'## unresolved'-and$markdown-match'## reviewerA') 'Human Markdown packet is incomplete.'
    foreach($property in $default.Packet.artifactHashes.PSObject.Properties){Assert-That ((Get-FileHash (Join-Path $default.RunDirectory $property.Name)).Hash.ToLowerInvariant()-eq[string]$property.Value) "Artifact hash mismatch: $($property.Name)"}
    $replay=$false;try{Start-ContractReview -RequestPath $default.Request -RunnerRoot $runnerRoot -ClaudeAdapter $fake -CodexAdapter $fake -ClaudeModel 'claude-fable-5' -CodexModel 'gpt-5.6-sol' -CodexReasoningEffort max -RoleTimeoutSeconds 20 -GitTimeoutSeconds 20 -SplitterTimeoutSeconds 20 -Approval $default.Approval|Out-Null}catch{$replay=$_.Exception.Message-match'already been consumed'};Assert-That $replay 'Approval replay was accepted.'
    $changed=Get-ContractReviewApproval -RequestPath $default.Request -RunnerRoot $runnerRoot -ClaudeAdapter $fake -CodexAdapter $fake -ClaudeModel 'claude-fable-5' -CodexModel 'gpt-5.6-sol' -CodexReasoningEffort max -RoleTimeoutSeconds 21 -GitTimeoutSeconds 20 -SplitterTimeoutSeconds 20
    Assert-That ($changed-ne$default.Approval) 'Timeout change did not invalidate execution approval.'
    Remove-Item Env:\CONTRACT_REVIEW_CLAUDE_COMMAND
    $allCodexRequest=New-Request 'fixture-all-codex-001';$allCodexBase=@{RequestPath=$allCodexRequest;RunnerRoot=$runnerRoot;ClaudeAdapter=$fake;CodexAdapter=$fake;ClaudeModel='claude-fable-5';CodexModel='gpt-5.6-sol';CodexReasoningEffort='max';RoleTimeoutSeconds=20;GitTimeoutSeconds=20;SplitterTimeoutSeconds=20;AllCodex=$true}
    $allCodexApproval=Get-ContractReviewApproval @allCodexBase;$allCodexPacketPath=Start-ContractReview @allCodexBase -Approval $allCodexApproval;$allCodexPacket=Get-Content ($allCodexPacketPath-replace'\.md$','.json') -Raw|ConvertFrom-Json
    $allCodexExecution=Get-Content (Join-Path (Split-Path -Parent $allCodexPacketPath) 'execution-manifest.json') -Raw|ConvertFrom-Json
    Assert-That ($allCodexPacket.status-eq'USER_DECISION_REQUIRED'-and@($allCodexExecution.providers.PSObject.Properties.Value.provider|Where-Object{$_-ne'codex'}).Count-eq0) 'All-Codex mode did not bind every role to Codex.'
    $env:CONTRACT_REVIEW_CLAUDE_COMMAND=$env:CONTRACT_REVIEW_CODEX_COMMAND

    foreach($case in @(@('OMIT_FINDING','omitted'),@('UNKNOWN_REF','unknown'),@('PROOF_GAP','proof IDs'),@('PROOF_FINDING_GAP','every finding'),@('RESOLUTION_GAP','resolve every'),@('WRONG_RESOLUTION_FINDING','acceptedFindingIds'),@('BAD_EVIDENCE','does not occur verbatim'),@('ROLE_LEAK','role-inappropriate'))){$run=Invoke-FakeRun ("fixture-{0}-001"-f$case[0].ToLower()) $case[0];Assert-That ($run.Packet.status-eq'FAILED') "$($case[0]) did not fail";Assert-That ($run.Packet.blocker-match$case[1]) "$($case[0]) failure was not explicit: $($run.Packet.blocker)"}
    $blocked=Invoke-FakeRun 'fixture-blocker-001' 'BLOCKER';Assert-That ($blocked.Packet.status-eq'BLOCKED_RULES_OR_SETTINGS') 'Rules/settings blocker did not stop distinctly.'
    $providerBlocked=Invoke-FakeRun 'fixture-provider-config-blocker-001' '' 'decision' (Join-Path $runnerRoot 'tests\fixtures\Fake-ProviderConfigFailure.ps1')
    Assert-That ($providerBlocked.Packet.status-eq'BLOCKED_RULES_OR_SETTINGS'-and$providerBlocked.Packet.blocker-match'provider configuration') 'Provider configuration rejection was not reported as a rules/settings blocker.'
    Assert-That (@($providerBlocked.Packet.receipts)-contains'reviewer-a.stderr.log') 'Provider configuration blocker omitted its stderr receipt.'
    Assert-That (-not(Test-Path (Join-Path $providerBlocked.RunDirectory 'reviewer-b.invocation.json'))) 'Provider configuration blocker continued to reviewer B.'
    Assert-That (-not(Test-Path (Join-Path $providerBlocked.RunDirectory 'worktree'))) 'Provider configuration blocker left its disposable worktree.'
    $authBlocked=Invoke-FakeRun 'fixture-provider-auth-blocker-001' '' 'decision' (Join-Path $runnerRoot 'tests\fixtures\Fake-ProviderAuthFailure.ps1')
    Assert-That ($authBlocked.Packet.status-eq'BLOCKED_RULES_OR_SETTINGS'-and$authBlocked.Packet.blocker-match'provider authentication') 'Late provider authentication rejection was not retained as a rules/settings blocker.'
    $badStage=Invoke-FakeRun 'fixture-stage-unresolved-001' 'STAGE_WITH_UNRESOLVED' 'stage1';Assert-That ($badStage.Packet.status-eq'FAILED') 'Stage 1 materialized with unresolved choices.';Assert-That (-not(Test-Path (Join-Path $badStage.RunDirectory 'stage1'))) 'Invalid Stage 1 output exists.'
    $stage=Invoke-FakeRun 'fixture-stage1-001' 'STAGE1' 'stage1';Assert-That ($stage.Packet.status-eq'COMPLETE') "Stage 1 status: $($stage.Packet.status)";Assert-That (Test-Path (Join-Path $stage.RunDirectory 'stage1\stage1-sample-owner.md')) 'Stage 1 staging output is absent.'
    $roleSchemaStage=Invoke-FakeRun 'fixture-role-schema-stage1-001' 'ROLE_SCHEMA_STAGE1' 'stage1';Assert-That ($roleSchemaStage.Packet.status-eq'COMPLETE') 'Role-specific provider schema did not prevent a blind Stage 1 manifest leak.'
    $blindInvocation=Get-Content (Join-Path $roleSchemaStage.RunDirectory 'reviewer-a.invocation.json') -Raw|ConvertFrom-Json;$retainedBlindSchema=Join-Path $roleSchemaStage.RunDirectory 'reviewer-a.response-schema.json'
    Assert-That ((Test-Path $retainedBlindSchema)-and(Get-FileHash $retainedBlindSchema).Hash.ToLowerInvariant()-eq[string]$blindInvocation.responseSchemaSha256) 'Blind role schema/hash was not retained in the run receipt.'

    $complete=Invoke-FakeRun 'fixture-complete-001' 'COMPLETE';Assert-That ($complete.Packet.status-eq'COMPLETE') 'Complete decision did not complete.'
    foreach($exitCase in @(@('COMPLETE',0),@('',2),@('BLOCKER',3),@('OMIT_FINDING',1))){$exitRun=Invoke-LauncherRun ("fixture-exit-{0}-001"-f$(if($exitCase[0]){$exitCase[0].ToLower()}else{'decision'})) $exitCase[0];Assert-That ($exitRun.ExitCode-eq$exitCase[1]) "Launcher status $($exitRun.Packet.status) exited $($exitRun.ExitCode), expected $($exitCase[1])."}
    Import-Module (Join-Path $runnerRoot 'contract-review\ContractApply.psm1') -Force
    $decisionPath=Join-Path $requests 'apply-decision.json';Write-Json $decisionPath ([ordered]@{runId=$complete.Packet.runId;approvedResolutionIds=@('C1');deniedResolutionIds=@();decidedBy='test-human';decidedUtc=[DateTime]::UtcNow.ToString('o')})
    $applyPhrase=Get-ContractApplyApproval -RunDirectory $complete.RunDirectory -DecisionPath $decisionPath;Assert-That ($applyPhrase-match'^APPROVE CONTRACT APPLY .+ [a-f0-9]{64}$') 'Apply phrase format is invalid.'
    $authorization=New-ContractApplyAuthorization -RunDirectory $complete.RunDirectory -DecisionPath $decisionPath -Approval $applyPhrase;Assert-That (Test-Path $authorization) 'Apply authorization was not materialized.'
    $applyBlocked=$false;try{Get-ContractApplyApproval -RunDirectory $default.RunDirectory -DecisionPath $decisionPath|Out-Null}catch{$applyBlocked=$_.Exception.Message-match'COMPLETE'};Assert-That $applyBlocked 'Incomplete packet was allowed into apply approval.'

    $hang=Invoke-FakeRun 'fixture-timeout-001' '' 'decision' (Join-Path $runnerRoot 'tests\fixtures\Fake-HangingReviewAgent.ps1') 2
    Assert-That ($hang.Packet.status-eq'FAILED'-and$hang.Packet.blocker-match'full process tree') 'Timeout did not fail with tree termination.'
    $child=(Get-Content (Join-Path $hang.RunDirectory 'hanging-child.json') -Raw|ConvertFrom-Json).childProcessId;Start-Sleep -Milliseconds 500
    Assert-That (-not(Get-Process -Id $child -ErrorAction SilentlyContinue)) 'Timed-out adapter child process survived.'

    $invalid=Get-Content $default.Request -Raw|ConvertFrom-Json;$invalid.requestId='fixture-invalid-001';$invalid.neutralQuestion='Move the rule to lines 4-9.';$invalidPath=Join-Path $requests 'invalid.json';Write-Json $invalidPath $invalid
    $firewall=$false;try{Get-ContractReviewApproval -RequestPath $invalidPath -RunnerRoot $runnerRoot -ClaudeAdapter $fake -CodexAdapter $fake -ClaudeModel 'claude-fable-5' -CodexModel 'gpt-5.6-sol' -CodexReasoningEffort max -RoleTimeoutSeconds 20 -GitTimeoutSeconds 20 -SplitterTimeoutSeconds 20|Out-Null}catch{$firewall=$_.Exception.Message-match'ticket firewall'};Assert-That $firewall 'Prescriptive request crossed the ticket firewall.'

    Import-Module (Join-Path $runnerRoot 'contract-review\ContractRecovery.psm1') -Force
    $pidReuseRun=Join-Path $runnerRoot 'runs\fixture-pid-reuse';New-Item -ItemType Directory -Path $pidReuseRun|Out-Null
    Write-Json (Join-Path $pidReuseRun 'execution-manifest.json') ([ordered]@{requestId='fixture-pid-reuse';targetRepository=$target;targetRevision=(Git @('rev-parse','HEAD'))})
    Write-Json (Join-Path $pidReuseRun 'live.invocation.json') ([ordered]@{adapterProcessId=$PID;adapterProcessStartTimeUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().AddSeconds(-1).ToString('o')})
    $pidSafe=$false;try{Repair-InterruptedContractReview -RunDirectory $pidReuseRun -RunnerRoot $runnerRoot -Reason 'pid test' -GitTimeoutSeconds 20|Out-Null}catch{$pidSafe=$_.Exception.Message-match'reused PID'};Assert-That $pidSafe 'Recovery did not reject a mismatched PID identity.';Assert-That ([bool](Get-Process -Id $PID -ErrorAction SilentlyContinue)) 'Recovery terminated the test process.'
    $recoveryRun=Join-Path $runnerRoot 'runs\fixture-recovery';New-Item -ItemType Directory -Path $recoveryRun|Out-Null
    Write-Json (Join-Path $recoveryRun 'execution-manifest.json') ([ordered]@{requestId='fixture-recovery';targetRepository=$target;targetRevision=(Git @('rev-parse','HEAD'))})
    Git @('worktree','add','--detach',(Join-Path $recoveryRun 'worktree'),'HEAD')|Out-Null
    $recovered=& (Join-Path $runnerRoot 'Recover-InterruptedContractReview.ps1') -RunDirectory $recoveryRun -RunnerRoot $runnerRoot -Reason 'test interruption' -GitTimeoutSeconds 20
    Assert-That (Test-Path $recovered) 'Recovery packet was not written.';Assert-That (-not(Test-Path (Join-Path $recoveryRun 'worktree'))) 'Recovery left its worktree.'

    Write-Host 'ContractReview.Tests.ps1: PASS' -ForegroundColor Green
}finally{
    Remove-Item Env:\SHOULD_NOT_REACH_CONTRACT_REVIEW -ErrorAction SilentlyContinue;Remove-Item Env:\CONTRACT_REVIEW_TEST_SCENARIO -ErrorAction SilentlyContinue;Remove-Item Env:\CONTRACT_REVIEW_CLAUDE_COMMAND -ErrorAction SilentlyContinue;Remove-Item Env:\CONTRACT_REVIEW_CODEX_COMMAND -ErrorAction SilentlyContinue;Remove-Item Env:\CONTRACT_REVIEW_PROVIDER_COMMAND -ErrorAction SilentlyContinue
    if(Test-Path $target){& $script:gitExe -C $target worktree prune 2>$null|Out-Null}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
