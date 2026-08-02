param([string]$Source,[string]$Manifest,[string]$OutDir,[switch]$CheckOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$bytes=[IO.File]::ReadAllBytes($Source);$starts=[Collections.Generic.List[int]]::new();if($bytes.Length-gt0){$starts.Add(0)}
for($i=0;$i-lt$bytes.Length;$i++){if($bytes[$i]-eq13){if($i+1-lt$bytes.Length-and$bytes[$i+1]-eq10){$i++};if($i+1-lt$bytes.Length){$starts.Add($i+1)}}elseif($bytes[$i]-eq10-and$i+1-lt$bytes.Length){$starts.Add($i+1)}}
$rows=@();$manifestLine=0
foreach($raw in [IO.File]::ReadAllLines($Manifest)){
    $manifestLine++;if([string]::IsNullOrWhiteSpace($raw)-or$raw.TrimStart().StartsWith('#')){continue}
    $parts=@($raw.Split([char]9));if($parts.Count-ne5){throw "manifest line ${manifestLine}: canonical manifest requires five fields"}
    if($parts[0]-notmatch'^(\d+)-(\d+)$'){throw "manifest line ${manifestLine}: invalid range"};$start=[int]$Matches[1];$end=[int]$Matches[2]
    $destinations=@($parts[1].Split(','));foreach($destination in $destinations){if($destination-notmatch'^contracts/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+_CONTRACT\.md$'){throw "manifest line ${manifestLine}: unsafe destination '$destination'"}}
    $names=@();if($parts[4]-ne'-'){$names=@($parts[4]-split ',(?![^\[]*\])')};$kind=$parts[3]
    if($kind-eq'MOVE'-and($destinations.Count-ne1-or$names.Count-gt1)){throw "manifest line ${manifestLine}: invalid MOVE shape"}
    if($kind-eq'SPLIT'-and($destinations.Count-lt2-or$names.Count-ne$destinations.Count)){throw "manifest line ${manifestLine}: invalid SPLIT shape"}
    if($kind-eq'PHASE-2'-and($destinations.Count-ne1-or$names.Count-ne0-or$parts[2]-ne'-')){throw "manifest line ${manifestLine}: invalid PHASE-2 shape"}
    $rows+=,[pscustomobject]@{Start=$start;End=$end;Destinations=$destinations}
}
$cursor=1;foreach($row in @($rows|Sort-Object Start)){if($row.Start-ne$cursor){throw "coverage mismatch at $cursor"};$cursor=$row.End+1};if($cursor-ne$starts.Count+1){throw 'coverage does not tile source'}
if($CheckOnly){Write-Output 'fake splitter compatibility check passed';return}
if(Test-Path $OutDir){throw 'output exists'};New-Item -ItemType Directory -Path $OutDir|Out-Null
$buckets=@{};foreach($row in $rows){foreach($destination in $row.Destinations){if(-not$buckets.ContainsKey($destination)){$buckets[$destination]=[Collections.Generic.List[object]]::new()};$buckets[$destination].Add($row)}}
foreach($destination in $buckets.Keys){$path=Join-Path $OutDir $destination.Replace('/',[IO.Path]::DirectorySeparatorChar);New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force|Out-Null;$stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew);try{foreach($row in $buckets[$destination]){$offset=$starts[$row.Start-1];$exclusive=if($row.End-lt$starts.Count){$starts[$row.End]}else{$bytes.Length};$stream.Write($bytes,$offset,$exclusive-$offset)}}finally{$stream.Dispose()}}
Copy-Item -LiteralPath $Manifest -Destination (Join-Path $OutDir 'manifest-used.tsv')
