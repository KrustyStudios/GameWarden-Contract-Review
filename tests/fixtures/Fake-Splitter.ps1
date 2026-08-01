param([string]$Source,[string]$Manifest,[string]$OutDir)
$ErrorActionPreference='Stop'
if(Test-Path $OutDir){throw 'output exists'}
New-Item -ItemType Directory -Path $OutDir|Out-Null
$bytes=[IO.File]::ReadAllBytes($Source)
$stream=[IO.File]::Open((Join-Path $OutDir 'stage1-sample-owner.md'),[IO.FileMode]::CreateNew)
try{$header=[Text.UTF8Encoding]::new($false).GetBytes("# fake staging`n```text`n");$stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$tail=[Text.UTF8Encoding]::new($false).GetBytes("`n``` `n");$stream.Write($tail,0,$tail.Length)}finally{$stream.Dispose()}
Copy-Item -LiteralPath $Manifest -Destination (Join-Path $OutDir 'manifest-used.tsv')
