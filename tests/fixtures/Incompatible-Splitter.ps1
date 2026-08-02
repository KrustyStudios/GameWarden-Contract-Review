param([string]$Source,[string]$Manifest,[string]$OutDir,[switch]$CheckOnly)
$ErrorActionPreference='Stop'
foreach($raw in Get-Content -LiteralPath $Manifest){
    if([string]::IsNullOrWhiteSpace($raw)-or$raw.TrimStart().StartsWith('#')){continue}
    $destination=$raw.Split([char]9)[1].Split(',')[0]
    if($destination-notmatch'^[a-z0-9][a-z0-9-]{0,79}$'){throw "unsafe destination '$destination'"}
}
throw 'incompatible splitter unexpectedly accepted the canonical probe'
