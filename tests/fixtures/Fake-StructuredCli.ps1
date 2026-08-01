[CmdletBinding(PositionalBinding=$false)]
param([Parameter(ValueFromPipeline=$true)][string]$PromptInput,[Parameter(ValueFromRemainingArguments=$true)][string[]]$CliArguments)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Assert-StrictSchema([object]$Schema,[string]$Path='$'){
    if($Schema.PSObject.Properties.Name -contains 'definitions'){foreach($property in $Schema.definitions.PSObject.Properties){Assert-StrictSchema $property.Value "$Path.definitions.$($property.Name)"}}
    $types=if($Schema.PSObject.Properties.Name -contains 'type'){@($Schema.type)}else{@()}
    if($types -contains 'object'){
        if($Schema.additionalProperties -ne $false){throw "$Path must close additionalProperties."}
        foreach($property in $Schema.properties.PSObject.Properties){if(@($Schema.required)-notcontains $property.Name){throw "$Path must require $($property.Name)."};Assert-StrictSchema $property.Value "$Path.$($property.Name)"}
    }
    if($types -contains 'array'){if(-not($Schema.PSObject.Properties.Name -contains 'items')){throw "$Path needs items."};Assert-StrictSchema $Schema.items "$Path[]"}
}
function Envelope{[ordered]@{status='ok';reason=$null;findings=@();classifications=@();proofs=@();resolutions=@();unresolved=@();stage1Manifest=@()}}
$loggedOut=Test-Path -LiteralPath (Join-Path $PSScriptRoot 'provider-logged-out.flag')
$lateAuth=Test-Path -LiteralPath (Join-Path $PSScriptRoot 'provider-late-auth.flag')
if($CliArguments.Count -eq 1 -and $CliArguments[0] -eq '--version'){'fake-structured-cli 2.0'}
elseif($CliArguments.Count -eq 2 -and $CliArguments[0] -eq 'auth' -and $CliArguments[1] -eq 'status'){
    @{loggedIn=(-not$loggedOut);authMethod=if($loggedOut){'none'}else{'test'}}|ConvertTo-Json -Compress
}
elseif($CliArguments.Count -eq 2 -and $CliArguments[0] -eq 'login' -and $CliArguments[1] -eq 'status'){
    if($loggedOut){'Not logged in';& $env:ComSpec /d /c exit 1}else{'Logged in using test fixture'}
}
else{
$stdin=if($PromptInput){$PromptInput}else{[Console]::In.ReadToEnd()};if([string]::IsNullOrWhiteSpace($stdin)){throw 'Prompt must arrive on stdin.'}
if($lateAuth){'Failed to authenticate. OAuth session expired.';& $env:ComSpec /d /c exit 1;return}
if($CliArguments -contains '--output-format'){
    foreach($flag in @('--safe-mode','--disable-slash-commands','--no-session-persistence','--strict-mcp-config','--no-chrome','--tools')){if($CliArguments -notcontains $flag){throw "Claude isolation flag missing: $flag"}}
    $modelIndex=[array]::IndexOf($CliArguments,'--model');if($CliArguments[$modelIndex+1]-ne'claude-fable-5'){throw 'Wrong Claude model.'}
    $mcpIndex=[array]::IndexOf($CliArguments,'--mcp-config');if($mcpIndex-lt0-or$CliArguments[$mcpIndex+1]-cne'{"mcpServers":{}}'){throw 'Claude MCP configuration must be an explicit empty mcpServers record.'}
    $schemaIndex=[array]::IndexOf($CliArguments,'--json-schema');$schema=$CliArguments[$schemaIndex+1]|ConvertFrom-Json;Assert-StrictSchema $schema
    @{is_error=$false;result=(Envelope|ConvertTo-Json -Compress -Depth 20)}|ConvertTo-Json -Compress
}else{
foreach($flag in @('--ephemeral','--ignore-user-config','--ignore-rules','--strict-config','--sandbox','--output-schema','--output-last-message')){if($CliArguments -notcontains $flag){throw "Codex isolation flag missing: $flag"}}
if($CliArguments[-1] -ne '-'){throw 'Codex prompt must use stdin marker.'}
$modelIndex=[array]::IndexOf($CliArguments,'--model');if($CliArguments[$modelIndex+1]-ne'gpt-5.6-sol'){throw 'Wrong Codex model.'}
$schemaIndex=[array]::IndexOf($CliArguments,'--output-schema');$schema=Get-Content $CliArguments[$schemaIndex+1]-Raw|ConvertFrom-Json;Assert-StrictSchema $schema
foreach($feature in @('apps','browser_use','computer_use','hooks','memories','multi_agent','plugins','shell_tool','unified_exec')){for($i=0;$i-lt$CliArguments.Count-1;$i++){if($CliArguments[$i]-eq'--disable'-and$CliArguments[$i+1]-eq$feature){continue 2}};throw "Codex feature not disabled: $feature"}
$outputIndex=[array]::IndexOf($CliArguments,'--output-last-message');Envelope|ConvertTo-Json -Depth 20|Set-Content $CliArguments[$outputIndex+1] -Encoding utf8
}
}
