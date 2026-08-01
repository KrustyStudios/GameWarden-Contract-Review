Set-StrictMode -Version Latest
$child=Start-Process -FilePath (Get-Command pwsh.exe).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 300') -PassThru
[ordered]@{childProcessId=$child.Id}|ConvertTo-Json|Set-Content (Join-Path (Split-Path $env:CONTRACT_REVIEW_OUTPUT_PATH) 'hanging-child.json') -Encoding utf8
Start-Sleep -Seconds 300
