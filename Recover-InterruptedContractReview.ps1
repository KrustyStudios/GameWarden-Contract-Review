[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDirectory,
    [Parameter(Mandatory = $true)][string]$Reason,
    [string]$RunnerRoot = $PSScriptRoot,
    [ValidateRange(1,3600)][int]$GitTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'contract-review\ContractRecovery.psm1') -Force
Repair-InterruptedContractReview -RunDirectory $RunDirectory -Reason $Reason -RunnerRoot $RunnerRoot -GitTimeoutSeconds $GitTimeoutSeconds
