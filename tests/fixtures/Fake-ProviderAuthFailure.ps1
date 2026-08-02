Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Fake-IsolationPreflight.ps1')
if(Complete-FakeIsolationPreflight){exit 0}
[Console]::Error.WriteLine('CONTRACT_REVIEW_PROVIDER_AUTHENTICATION_BLOCKER: Fake provider authentication became unavailable after readiness validation.')
exit 79
