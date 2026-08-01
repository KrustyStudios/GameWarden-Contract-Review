Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Write-Atomic([string]$Path,[string]$Text) { $tmp="$Path.tmp-$([guid]::NewGuid().ToString('N'))"; try { [IO.File]::WriteAllText($tmp,$Text,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($tmp,$Path,$true) } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
function Stop-AuthenticationFailure([string]$Text) {
    if ($Text -match '(?i)(failed to authenticate|authentication (?:failed|error)|oauth session expired|not logged in|please log in|run /login|refresh token)') {
        [Console]::Error.WriteLine('CONTRACT_REVIEW_PROVIDER_AUTHENTICATION_BLOCKER: Claude CLI authentication became unavailable after readiness validation.')
        exit 79
    }
}
$promptPath=$env:CONTRACT_REVIEW_PROMPT_FILE;$outputPath=$env:CONTRACT_REVIEW_OUTPUT_PATH;$metadataPath=$env:CONTRACT_REVIEW_METADATA_PATH
$prompt=[IO.File]::ReadAllText($promptPath,[Text.UTF8Encoding]::new($false,$true))
$claude=$env:CONTRACT_REVIEW_PROVIDER_COMMAND
if (-not (Test-Path -LiteralPath $claude -PathType Leaf)) { throw "Claude CLI not found: $claude" }
$model=$env:CONTRACT_REVIEW_MODEL; if ([string]::IsNullOrWhiteSpace($model)) { throw 'Claude model was not supplied.' }
$schemaPath=$env:CONTRACT_REVIEW_SCHEMA_PATH; if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) { throw 'Response schema is missing.' }
$schema=[IO.File]::ReadAllText($schemaPath,[Text.UTF8Encoding]::new($false,$true))
$contractNames=@(Get-ChildItem Env: | Where-Object Name -like 'CONTRACT_REVIEW_*' | ForEach-Object Name);foreach($name in $contractNames){Remove-Item "Env:\$name" -ErrorAction SilentlyContinue};$env:CLAUDE_CODE_SAFE_MODE='1'
$global:LASTEXITCODE=0;$versionOutput=& $claude '--version' 2>&1; if ($LASTEXITCODE -ne 0) { throw "Claude version check failed: $($versionOutput -join ' ')" }
$metadata=[ordered]@{ cliVersion=($versionOutput -join ' ').Trim(); requestedModel=$model; sessionPersistence=$false; tools=@(); safeMode=$true; settingsSources=@(); skills=$false; plugins=$false; hooks=$false; mcpServers=@(); chrome=$false; promptTransport='stdin' }
Write-Atomic -Path $metadataPath -Text (($metadata | ConvertTo-Json -Depth 8)+"`n")
$mcpConfig='{"mcpServers":{}}'
$arguments=@('--model',$model,'--safe-mode','--setting-sources','','--tools','','--disable-slash-commands','--no-session-persistence','--strict-mcp-config','--mcp-config',$mcpConfig,'--no-chrome','--permission-mode','dontAsk','--output-format','json','--json-schema',$schema,'--print')
$global:LASTEXITCODE=0;$result=Write-Output -NoEnumerate $prompt | & $claude @arguments 2>&1
if ($LASTEXITCODE -ne 0) {
    $errorText=$result -join "`n"
    Stop-AuthenticationFailure -Text $errorText
    if ($errorText -match '(?i)Invalid MCP configuration') {
        [Console]::Error.WriteLine('CONTRACT_REVIEW_PROVIDER_CONFIGURATION_BLOCKER: Claude CLI rejected the isolated MCP configuration.')
        exit 78
    }
    throw "Claude CLI exited $LASTEXITCODE`: $errorText"
}
try { $envelope=($result -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { throw "Claude returned no valid JSON envelope: $($_.Exception.Message)" }
if ($envelope.is_error -eq $true) { Stop-AuthenticationFailure -Text ([string]$envelope.result); throw "Claude reported an error: $($envelope.result)" }
if (-not ($envelope.PSObject.Properties.Name -contains 'result')) { throw 'Claude response envelope has no result.' }
$responseText=if ($envelope.result -is [string]) { $envelope.result } else { $envelope.result | ConvertTo-Json -Depth 64 }
try { $null=$responseText | ConvertFrom-Json -ErrorAction Stop } catch { throw "Claude result is not valid review JSON: $($_.Exception.Message)" }
Write-Atomic -Path $outputPath -Text ($responseText.TrimEnd()+"`n")
