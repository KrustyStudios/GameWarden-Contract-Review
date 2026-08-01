[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RequestPath,
    [string]$Approval,
    [switch]$ShowApproval,
    [string]$RunnerRoot = $PSScriptRoot,
    [string]$ClaudeAdapter = (Join-Path $PSScriptRoot 'contract-review\Invoke-ClaudeReview.ps1'),
    [string]$CodexAdapter = (Join-Path $PSScriptRoot 'contract-review\Invoke-CodexReview.ps1'),
    [string]$ClaudeModel = 'claude-fable-5',
    [string]$CodexModel = 'gpt-5.6-sol',
    [ValidateSet('low','medium','high','xhigh','max')][string]$CodexReasoningEffort = 'max',
    [ValidateRange(1,86400)][int]$RoleTimeoutSeconds = 1200,
    [ValidateRange(1,3600)][int]$GitTimeoutSeconds = 60,
    [ValidateRange(1,3600)][int]$SplitterTimeoutSeconds = 120,
    [switch]$AllCodex,
    [switch]$NoSound
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'contract-review\ContractReview.psm1') -Force
if ((Resolve-Path -LiteralPath $RunnerRoot).Path -ne (Resolve-Path -LiteralPath $PSScriptRoot).Path) { throw 'RunnerRoot must be the directory containing this launcher.' }

$parameters = @{
    RequestPath=$RequestPath; RunnerRoot=$RunnerRoot; ClaudeAdapter=$ClaudeAdapter; CodexAdapter=$CodexAdapter
    ClaudeModel=$ClaudeModel; CodexModel=$CodexModel; CodexReasoningEffort=$CodexReasoningEffort
    RoleTimeoutSeconds=$RoleTimeoutSeconds; GitTimeoutSeconds=$GitTimeoutSeconds; SplitterTimeoutSeconds=$SplitterTimeoutSeconds; AllCodex=$AllCodex
}
if ($ShowApproval) { Get-ContractReviewApproval @parameters; exit 0 }
if ([string]::IsNullOrWhiteSpace($Approval)) { throw 'Approval is required unless -ShowApproval is used.' }

function Get-ContractReviewCompletionSound([string]$Status) {
    switch ($Status) {
        'COMPLETE' { 'Asterisk' }
        'USER_DECISION_REQUIRED' { 'Question' }
        'BLOCKED_RULES_OR_SETTINGS' { 'Exclamation' }
        default { 'Hand' }
    }
}

$terminalStatus='FAILED'
try {
    $packetPath=Start-ContractReview @parameters -Approval $Approval
    $packetJsonPath=([string]$packetPath) -replace '\.md$','.json'
    $terminalStatus=[string](Get-Content -LiteralPath $packetJsonPath -Raw | ConvertFrom-Json -ErrorAction Stop).status
    Write-Output $packetPath
} finally {
    if (-not $NoSound) {
        $sound=Get-ContractReviewCompletionSound -Status $terminalStatus
        try { [System.Media.SystemSounds]::$sound.Play() } catch { Write-Warning "Could not play $sound completion sound: $($_.Exception.Message)" }
    }
}

$processExitCode = switch ($terminalStatus) {
    'COMPLETE' { 0 }
    'USER_DECISION_REQUIRED' { 2 }
    'BLOCKED_RULES_OR_SETTINGS' { 3 }
    default { 1 }
}
if ($processExitCode -ne 0) { exit $processExitCode }
