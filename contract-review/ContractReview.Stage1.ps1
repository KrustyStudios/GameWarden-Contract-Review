Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ContractReviewContractDestination {
    param([string]$Value, [string]$Label)
    Assert-ContractReviewSafeRelativePath -Value $Value -Label $Label
    if ($Value -notmatch '^contracts/(?:[A-Za-z0-9._-]+/)*[A-Za-z0-9._-]+_CONTRACT\.md$') {
        throw "$Label must be a repository-relative contracts/**/*_CONTRACT.md path."
    }
}
function Assert-ContractReviewTagMetadata {
    param([string]$Value, [string]$Label)
    if ($Value -notmatch '^\[[^\]\r\n\t]+\]$') { throw "$Label must be one bracketed tag." }
}

function Get-ContractReviewStage1AssignmentKey {
    param([int]$Start, [int]$End, [string]$Destination, [AllowNull()][string]$ProposedTag)
    return "$Start`t$End`t$Destination`t$(if($null-eq$ProposedTag){'-'}else{$ProposedTag})"
}

function Assert-ContractReviewStage1Row {
    param([object]$Row, [string]$Label = 'Stage 1 row')
    Assert-ContractReviewExactProperties -Value $Row -Required @('start','end','destinations','name','disposition','perDestinationNames','findingIds') -Label $Label
    if ([int]$Row.start -lt 1 -or [int]$Row.end -lt [int]$Row.start) { throw "$Label has an invalid source range." }
    $destinations = @($Row.destinations)
    Assert-ContractReviewUniqueStrings -Values $destinations -Label "$Label destinations"
    foreach ($destination in $destinations) { Assert-ContractReviewContractDestination -Value ([string]$destination) -Label "$Label destination" }
    $names = @()
    if ($null -ne $Row.perDestinationNames) { $names = @($Row.perDestinationNames) }
    Assert-ContractReviewUniqueStrings -Values $names -Label "$Label perDestinationNames"
    foreach ($name in $names) { Assert-ContractReviewTagMetadata -Value ([string]$name) -Label "$Label proposed destination name" }
    Assert-ContractReviewUniqueStrings -Values @($Row.findingIds) -Label "$Label findingIds"
    if (@($Row.findingIds).Count -eq 0) { throw "$Label must cite at least one accepted finding." }
    Assert-ContractReviewNoControlCharacters -Text ([string]$Row.name) -Label "$Label name"
    switch ([string]$Row.disposition) {
        'MOVE' {
            if ($destinations.Count -ne 1) { throw "$Label MOVE requires exactly one destination." }
            if ($names.Count -gt 1) { throw "$Label MOVE permits at most one proposed destination name." }
            if ([string]::IsNullOrWhiteSpace([string]$Row.name) -or [string]$Row.name -eq '-') { throw "$Label MOVE requires a source tag or descriptive label." }
        }
        'SPLIT' {
            if ($destinations.Count -lt 2) { throw "$Label SPLIT requires at least two destinations." }
            if ($names.Count -ne $destinations.Count) { throw "$Label SPLIT requires one proposed destination name per destination." }
            if ([string]::IsNullOrWhiteSpace([string]$Row.name) -or [string]$Row.name -eq '-') { throw "$Label SPLIT requires a source tag or descriptive label." }
        }
        'PHASE-2' {
            if ($destinations.Count -ne 1 -or $names.Count -ne 0 -or [string]$Row.name -ne '-') { throw "$Label PHASE-2 requires one destination, name '-', and no proposed destination names." }
        }
        default { throw "Unsupported Stage 1 disposition '$($Row.disposition)'." }
    }
}

function Assert-ContractReviewStage1ManifestAccounting {
    param([object]$ReviewerA, [object]$ReviewerB, [object]$Validation, [object]$Request, [string]$InputRoot)
    if ([string]$Request.reviewKind -ne 'stage1') { return }
    $sourcePath = Join-Path $InputRoot ([string]$Request.stage1.sourceContract)
    $sourceLineCount = [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $sourcePath)).Count
    $allFindings = @($ReviewerA.findings) + @($ReviewerB.findings)
    $acceptedIds = @($Validation.resolutions | ForEach-Object { @($_.acceptedFindingIds) } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $eligible = @{}
    foreach ($finding in $allFindings) {
        if ([string]$finding.id -notin $acceptedIds -or [string]$finding.placement.disposition -notin @('MOVE','SPLIT','PHASE-2')) { continue }
        $fragments = @($finding.placement.fragments)
        if ($fragments.Count -eq 0) { throw "Accepted Stage 1 finding '$($finding.id)' has no destination fragment assignments." }
        if ([string]$finding.placement.disposition -eq 'MOVE' -and ($fragments.Count -ne 1 -or @($finding.placement.destinations).Count -ne 1)) {
            throw "Accepted Stage 1 MOVE finding '$($finding.id)' must have exactly one destination fragment assignment."
        }
        if ([string]$finding.placement.disposition -eq 'SPLIT' -and @($finding.placement.destinations).Count -lt 2) {
            throw "Accepted Stage 1 SPLIT finding '$($finding.id)' must name at least two destinations."
        }
        foreach ($fragment in $fragments) {
            if ([int]$fragment.end -gt $sourceLineCount) { throw "Finding $($finding.id) fragment range exceeds source line $sourceLineCount." }
        }
        $fragmentDestinations = @($fragments | ForEach-Object { [string]$_.destination } | Sort-Object -Unique)
        if (-not (Test-ContractReviewSameStringSet -Left @($finding.placement.destinations) -Right $fragmentDestinations)) {
            throw "Finding $($finding.id) placement destinations differ from its fragment assignments."
        }
        $fragmentTags = @($fragments | Where-Object { $null -ne $_.proposedTag } | ForEach-Object { [string]$_.proposedTag })
        if (-not (Test-ContractReviewSameStringSet -Left @($finding.placement.proposedTags) -Right $fragmentTags)) {
            throw "Finding $($finding.id) proposed tags differ from its fragment assignments."
        }
        $eligible[[string]$finding.id] = $finding
    }

    $actualByFinding = @{}
    foreach ($row in @($Validation.stage1Manifest)) {
        Assert-ContractReviewStage1Row -Row $row
        $linked = @($row.findingIds)
        foreach ($id in $linked) {
            if (-not $eligible.ContainsKey([string]$id)) { throw "Stage 1 row cites finding '$id' without an accepted placement fragment assignment." }
            if (-not $actualByFinding.ContainsKey([string]$id)) { $actualByFinding[[string]$id] = [Collections.Generic.List[string]]::new() }
        }
        $existingTags = @($linked | ForEach-Object { $eligible[[string]$_].placement.existingTag } | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        if ($existingTags.Count -gt 1 -or ($existingTags.Count -eq 1 -and [string]$row.name -cne $existingTags[0])) {
            throw "Stage 1 row name does not match the accepted finding source tag."
        }
        $names = @()
        if ($null -ne $row.perDestinationNames) { $names = @($row.perDestinationNames) }
        for ($index = 0; $index -lt @($row.destinations).Count; $index++) {
            $tag = if ($names.Count -gt $index) { [string]$names[$index] } else { $null }
            $key = Get-ContractReviewStage1AssignmentKey -Start $row.start -End $row.end -Destination ([string]$row.destinations[$index]) -ProposedTag $tag
            foreach ($id in $linked) { $actualByFinding[[string]$id].Add($key) }
        }
    }

    foreach ($entry in $eligible.GetEnumerator()) {
        $expected = @($entry.Value.placement.fragments | ForEach-Object { Get-ContractReviewStage1AssignmentKey -Start $_.start -End $_.end -Destination ([string]$_.destination) -ProposedTag $_.proposedTag })
        $actual = if ($actualByFinding.ContainsKey($entry.Key)) { @($actualByFinding[$entry.Key]) } else { @() }
        if (-not (Test-ContractReviewSameStringSet -Left $expected -Right $actual)) {
            throw "Stage 1 manifest fragment assignments differ from accepted finding '$($entry.Key)'."
        }
    }
}

function Write-ContractReviewStage1Manifest {
    param([object[]]$Rows, [string]$Path)
    if (@($Rows).Count -eq 0) { throw 'Completed Stage 1 validation supplied no manifest rows.' }
    $lines = @('# Generated from validated Stage 1 resolutions. Proposed tags are metadata outside copied source bytes.')
    foreach ($row in @($Rows)) {
        Assert-ContractReviewStage1Row -Row $row
        $lines += "# findings: $(@($row.findingIds) -join ',')"
        $line = "$($row.start)-$($row.end)`t$(@($row.destinations) -join ',')`t$($row.name)`t$($row.disposition)"
        $line += if ($null -eq $row.perDestinationNames -or @($row.perDestinationNames).Count -eq 0) { "`t-" } else { "`t$(@($row.perDestinationNames) -join ',')" }
        $lines += $line
    }
    Write-ContractReviewAtomicText -Path $Path -Text ([string]::Join("`n", $lines) + "`n")
}
