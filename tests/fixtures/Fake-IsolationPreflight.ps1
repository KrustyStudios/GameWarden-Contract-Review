function Complete-FakeIsolationPreflight {
    if ($env:CONTRACT_REVIEW_ISOLATION_PREFLIGHT -ne '1') { return $false }
    $response = [ordered]@{status='ok';reason=$null;findings=@();classifications=@();proofs=@();resolutions=@();unresolved=@();stage1Manifest=@()}
    if(Test-Path -LiteralPath (Join-Path $PSScriptRoot 'provider-isolation-exposed.flag')){$response.status='blocker';$response.reason='callable tool exposure detected'}
    [ordered]@{isolatedWorkingDirectory=$true}|ConvertTo-Json|Set-Content $env:CONTRACT_REVIEW_METADATA_PATH -Encoding utf8
    $response|ConvertTo-Json -Depth 8|Set-Content $env:CONTRACT_REVIEW_OUTPUT_PATH -Encoding utf8
    return $true
}
