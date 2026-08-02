Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Fake-IsolationPreflight.ps1')
if(Complete-FakeIsolationPreflight){exit 0}
[Console]::Error.WriteLine('CONTRACT_REVIEW_PROVIDER_CONFIGURATION_BLOCKER: Fake provider rejected the isolated MCP configuration.')
exit 78
