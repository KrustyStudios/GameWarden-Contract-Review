[CmdletBinding()]
param(
    [string]$Manifest,
    [string]$OutputRoot,
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ApprovedContractCopyHash {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Test-ApprovedContractBytesEqual {
    param(
        [Parameter(Mandatory = $true)][byte[]]$First,
        [Parameter(Mandatory = $true)][byte[]]$Second
    )

    if ($First.Length -ne $Second.Length) { return $false }
    for ($index = 0; $index -lt $First.Length; $index++) {
        if ($First[$index] -ne $Second[$index]) { return $false }
    }
    $true
}

function Resolve-ApprovedContractOutputRoot {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.Path]::IsPathFullyQualified($Path)) {
        throw "Output root must be an exact full path: $Path"
    }
    $fullPath = [IO.Path]::GetFullPath($Path)
    if ($Path -cne $fullPath) {
        throw "Output root must already be canonical: $Path"
    }
    if (Test-Path -LiteralPath $fullPath) {
        throw "Output root already exists: $fullPath"
    }
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Output root parent does not exist: $parent"
    }
    $fullPath
}

function Read-ApprovedContractCopyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Phase 2 manifest not found: $ManifestPath"
    }
    $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
    if (-not [IO.Path]::IsPathFullyQualified($ManifestPath) -or $ManifestPath -cne $resolvedManifest) {
        throw "Phase 2 manifest must be an exact canonical full path: $ManifestPath"
    }

    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    $text = $strictUtf8.GetString([IO.File]::ReadAllBytes($resolvedManifest))
    $beginPattern = '(?m)^BEGIN PHASE2 COPY MANIFEST\r?$'
    $endPattern = '(?m)^END PHASE2 COPY MANIFEST\r?$'
    if ([regex]::Matches($text, $beginPattern).Count -ne 1 -or
        [regex]::Matches($text, $endPattern).Count -ne 1) {
        throw 'Phase 2 manifest must contain exactly one begin marker and one end marker.'
    }
    $block = [regex]::Match(
        $text,
        '(?ms)^BEGIN PHASE2 COPY MANIFEST\r?\n(.*?)^END PHASE2 COPY MANIFEST\r?$'
    )
    if (-not $block.Success) { throw 'Phase 2 manifest markers are malformed or out of order.' }

    $rows = [Collections.Generic.List[object]]::new()
    $stagingPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $destinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $lineNumber = 0
    $rowText = $block.Groups[1].Value
    if ($rowText.EndsWith("`r`n", [StringComparison]::Ordinal)) {
        $rowText = $rowText.Substring(0, $rowText.Length - 2)
    } elseif ($rowText.EndsWith("`n", [StringComparison]::Ordinal)) {
        $rowText = $rowText.Substring(0, $rowText.Length - 1)
    }
    foreach ($line in @($rowText -split '\r?\n')) {
        $lineNumber++
        if ([string]::IsNullOrEmpty($line)) {
            throw "Phase 2 manifest contains a blank row at row $lineNumber."
        }
        $fields = $line.Split([char]9)
        if ($fields.Count -ne 4) {
            throw "Phase 2 manifest row $lineNumber requires exactly 4 tab-separated fields."
        }
        if ($fields[0] -cne 'COPY') {
            throw "Phase 2 manifest row $lineNumber has unsupported operation: $($fields[0])"
        }

        $stagingPath = $fields[1]
        if (-not [IO.Path]::IsPathFullyQualified($stagingPath)) {
            throw "Staging path must be an exact full path at row ${lineNumber}: $stagingPath"
        }
        if (-not (Test-Path -LiteralPath $stagingPath -PathType Leaf)) {
            throw "Staging file not found at row ${lineNumber}: $stagingPath"
        }
        $resolvedStaging = (Resolve-Path -LiteralPath $stagingPath).Path
        if ($stagingPath -cne $resolvedStaging) {
            throw "Staging path must already be canonical at row ${lineNumber}: $stagingPath"
        }
        if (-not $stagingPaths.Add($resolvedStaging)) {
            throw "Duplicate staging path at row ${lineNumber}: $resolvedStaging"
        }

        $destination = $fields[2]
        if ($destination -match '[\x00-\x1f\x7f]' -or
            $destination -notmatch '^contracts/(?:[A-Za-z0-9][A-Za-z0-9._-]*/)*[A-Za-z0-9][A-Za-z0-9._-]*_CONTRACT\.md$') {
            throw "Unsafe Phase 2 destination at row ${lineNumber}: $destination"
        }
        if (-not $destinations.Add($destination)) {
            throw "Duplicate Phase 2 destination at row ${lineNumber}: $destination"
        }

        $approvedHash = $fields[3]
        if ($approvedHash -cnotmatch '^[a-f0-9]{64}$') {
            throw "Invalid lowercase SHA-256 at row ${lineNumber}: $approvedHash"
        }
        $actualHash = Get-ApprovedContractCopyHash ([IO.File]::ReadAllBytes($resolvedStaging))
        if ($actualHash -cne $approvedHash) {
            throw "Staging hash mismatch at row ${lineNumber}: $resolvedStaging"
        }
        $rows.Add([pscustomobject]@{
            Number = $lineNumber
            StagingPath = $resolvedStaging
            Destination = $destination
            Hash = $approvedHash
        })
    }
    if ($rows.Count -eq 0) { throw 'Phase 2 manifest contains no COPY rows.' }

    [pscustomobject]@{
        ManifestPath = $resolvedManifest
        Rows = $rows.ToArray()
    }
}

function Assert-ApprovedContractCopyPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$ResolvedOutputRoot,
        [switch]$VerifyOutput
    )

    $expectedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $Plan.Rows) {
        $stagingBytes = [IO.File]::ReadAllBytes($row.StagingPath)
        if ((Get-ApprovedContractCopyHash $stagingBytes) -cne $row.Hash) {
            throw "Staging file changed: $($row.StagingPath)"
        }
        if (-not $VerifyOutput) { continue }
        $relativePlatformPath = $row.Destination.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $destinationPath = [IO.Path]::GetFullPath((Join-Path $ResolvedOutputRoot $relativePlatformPath))
        $rootPrefix = $ResolvedOutputRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $destinationPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Destination escapes output root: $($row.Destination)"
        }
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            throw "Copied contract is missing: $destinationPath"
        }
        $outputBytes = [IO.File]::ReadAllBytes($destinationPath)
        if (-not (Test-ApprovedContractBytesEqual $stagingBytes $outputBytes)) {
            throw "Copied contract differs from approved staging bytes: $destinationPath"
        }
        [void]$expectedFiles.Add($row.Destination)
    }

    if ($VerifyOutput) {
        $actualFiles = @(Get-ChildItem -LiteralPath $ResolvedOutputRoot -Recurse -File | ForEach-Object {
            [IO.Path]::GetRelativePath($ResolvedOutputRoot, $_.FullName).Replace('\', '/')
        })
        if ($actualFiles.Count -ne $expectedFiles.Count) {
            throw 'Final contract tree contains an unexpected file count.'
        }
        foreach ($actualFile in $actualFiles) {
            if (-not $expectedFiles.Contains($actualFile)) {
                throw "Final contract tree contains an unexpected file: $actualFile"
            }
        }
    }
}

function Invoke-ApprovedContractCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)][string]$FinalOutputRoot,
        [switch]$CheckOnly
    )

    $resolvedOutputRoot = Resolve-ApprovedContractOutputRoot $FinalOutputRoot
    Assert-ApprovedContractCopyPlan $Plan $resolvedOutputRoot
    if ($CheckOnly) {
        return [pscustomobject]@{
            OutputRoot = $resolvedOutputRoot
            Rows = $Plan.Rows
            Message = "Phase 2 copy check passed for $($Plan.Rows.Count) contract(s)."
        }
    }

    $parent = Split-Path -Parent $resolvedOutputRoot
    $leaf = Split-Path -Leaf $resolvedOutputRoot
    $temporaryRoot = Join-Path $parent (".$leaf.tmp-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        foreach ($row in $Plan.Rows) {
            $stagingBytes = [IO.File]::ReadAllBytes($row.StagingPath)
            if ((Get-ApprovedContractCopyHash $stagingBytes) -cne $row.Hash) {
                throw "Staging file changed before copy: $($row.StagingPath)"
            }
            $relativePlatformPath = $row.Destination.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $temporaryDestination = [IO.Path]::GetFullPath((Join-Path $temporaryRoot $relativePlatformPath))
            $temporaryPrefix = $temporaryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $temporaryDestination.StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Destination escapes temporary output root: $($row.Destination)"
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $temporaryDestination) -Force | Out-Null
            [IO.File]::WriteAllBytes($temporaryDestination, $stagingBytes)
            if (-not (Test-ApprovedContractBytesEqual $stagingBytes ([IO.File]::ReadAllBytes($temporaryDestination)))) {
                throw "Temporary copy verification failed: $temporaryDestination"
            }
        }
        Assert-ApprovedContractCopyPlan $Plan $resolvedOutputRoot
        if (Test-Path -LiteralPath $resolvedOutputRoot) {
            throw "Output root appeared during copy: $resolvedOutputRoot"
        }
        [IO.Directory]::Move($temporaryRoot, $resolvedOutputRoot)
        Assert-ApprovedContractCopyPlan $Plan $resolvedOutputRoot -VerifyOutput
    } finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
        }
    }

    [pscustomobject]@{
        OutputRoot = $resolvedOutputRoot
        Rows = $Plan.Rows
        Message = "Copied $($Plan.Rows.Count) approved contract(s) exactly to $resolvedOutputRoot"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($Manifest)) { throw '-Manifest is required.' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { throw '-OutputRoot is required.' }
    $copyPlan = Read-ApprovedContractCopyPlan -ManifestPath $Manifest
    $copyResult = Invoke-ApprovedContractCopy -Plan $copyPlan -FinalOutputRoot $OutputRoot -CheckOnly:$CheckOnly
    Write-Output $copyResult.Message
}
