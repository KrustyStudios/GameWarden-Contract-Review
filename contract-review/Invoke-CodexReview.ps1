Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Write-Atomic([string]$Path,[string]$Text) { $tmp="$Path.tmp-$([guid]::NewGuid().ToString('N'))"; try { [IO.File]::WriteAllText($tmp,$Text,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($tmp,$Path,$true) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
function Stop-AuthenticationFailure([string]$Text) {
    if ($Text -match '(?i)(failed to authenticate|authentication (?:failed|error)|oauth session expired|not logged in|please log in|unauthorized|refresh token)') {
        [Console]::Error.WriteLine('CONTRACT_REVIEW_PROVIDER_AUTHENTICATION_BLOCKER: Codex CLI authentication became unavailable after readiness validation.')
        exit 79
    }
}
$promptPath=$env:CONTRACT_REVIEW_PROMPT_FILE;$outputPath=$env:CONTRACT_REVIEW_OUTPUT_PATH;$metadataPath=$env:CONTRACT_REVIEW_METADATA_PATH;$providerCwd=$env:CONTRACT_REVIEW_PROVIDER_CWD
$prompt=[IO.File]::ReadAllText($promptPath,[Text.UTF8Encoding]::new($false,$true))
$codex=$env:CONTRACT_REVIEW_PROVIDER_COMMAND
if (-not (Test-Path -LiteralPath $codex -PathType Leaf)) { throw "Codex CLI not found: $codex" }
$model=$env:CONTRACT_REVIEW_MODEL; $effort=$env:CONTRACT_REVIEW_REASONING_EFFORT
if ([string]::IsNullOrWhiteSpace($model) -or [string]::IsNullOrWhiteSpace($effort)) { throw 'Codex model and effort are required.' }
$schemaPath=$env:CONTRACT_REVIEW_SCHEMA_PATH; if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'Response schema is missing.' }
if ([string]::IsNullOrWhiteSpace($providerCwd) -or -not (Test-Path -LiteralPath $providerCwd -PathType Container) -or @(Get-ChildItem -LiteralPath $providerCwd -Force).Count -ne 0) {
    [Console]::Error.WriteLine('CONTRACT_REVIEW_PROVIDER_CONFIGURATION_BLOCKER: Codex requires a fresh empty provider working directory.')
    exit 78
}
$contractNames=@(Get-ChildItem Env: | Where-Object Name -like 'CONTRACT_REVIEW_*' | ForEach-Object Name);foreach($name in $contractNames){Remove-Item "Env:\$name" -ErrorAction SilentlyContinue}
$global:LASTEXITCODE=0;$versionOutput=& $codex '--version' 2>&1; if ($LASTEXITCODE -ne 0) { throw "Codex version check failed: $($versionOutput -join ' ')" }
$disabled=@('apps','browser_use','browser_use_external','browser_use_full_cdp_access','code_mode_host','computer_use','goals','hooks','image_generation','in_app_browser','memories','multi_agent','plugins','shell_tool','tool_suggest','unified_exec','workspace_dependencies')
$metadata=[ordered]@{ cliVersion=($versionOutput -join ' ').Trim(); requestedModel=$model; reasoningEffort=$effort; ephemeral=$true; ignoreUserConfig=$true; ignoreRules=$true; sandbox='read-only'; disabledFeatures=$disabled; promptTransport='stdin'; isolatedWorkingDirectory=$true }
Write-Atomic -Path $metadataPath -Text (($metadata | ConvertTo-Json -Depth 8)+"`n")
$arguments=@('exec','--model',$model,'--config',("model_reasoning_effort=`"$effort`""),'--sandbox','read-only','--skip-git-repo-check','--ephemeral','--ignore-user-config','--ignore-rules','--strict-config')
foreach ($feature in $disabled) { $arguments+=@('--disable',$feature) }
$arguments+=@('--output-schema',$schemaPath,'--output-last-message',$outputPath,'-')
$global:LASTEXITCODE=0
Push-Location -LiteralPath $providerCwd
try { $result=Write-Output -NoEnumerate $prompt | & $codex @arguments 2>&1 }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { $errorText=$result -join "`n";Stop-AuthenticationFailure -Text $errorText;throw "Codex CLI exited $LASTEXITCODE`: $errorText" }
if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) { throw 'Codex wrote no response file.' }
$responseText=[IO.File]::ReadAllText($outputPath,[Text.UTF8Encoding]::new($false,$true))
try { $null=$responseText | ConvertFrom-Json -ErrorAction Stop } catch { throw "Codex result is not valid review JSON: $($_.Exception.Message)" }
Write-Atomic -Path $outputPath -Text ($responseText.TrimEnd()+"`n")
