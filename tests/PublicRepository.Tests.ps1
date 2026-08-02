Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = [System.Collections.Generic.List[string]]::new()

function Add-PublicRepositoryFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $failures.Add($Message)
}

$tracked = @(& git -C $repoRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
    throw 'Unable to enumerate tracked repository files.'
}

$forbiddenFiles = @(
    'AGENTS.md'
    'AI_GUARDRAILS.md'
    'AI_RULES.md'
    'CLAUDE_NOTES.md'
    'CODEX_WORK.md'
    'NEEDS-ATTENTION.txt'
    'README.contract-review.md'
    'baton.md'
    'loop.state'
)
$forbiddenDirectories = @(
    '.beads/'
    '.design/'
    'approval-receipts/'
    'boards/'
    'launcher-receipts/'
    'logs/'
    'requests/'
    'runs/'
)

foreach ($path in $tracked) {
    $normalized = $path.Replace('\', '/')
    if ($normalized -in $forbiddenFiles) {
        Add-PublicRepositoryFailure "Private or runtime file is tracked: $normalized"
    }
    foreach ($directory in $forbiddenDirectories) {
        if ($normalized.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase)) {
            Add-PublicRepositoryFailure "Private or runtime directory is tracked: $normalized"
        }
    }
    if ($normalized.EndsWith('.log', [StringComparison]::OrdinalIgnoreCase)) {
        Add-PublicRepositoryFailure "Runtime log is tracked: $normalized"
    }
}

$privateFragments = @(
    [pscustomobject]@{ Name = 'GameWarden source path'; Value = ('D:' + '\ark-server-manager') }
    [pscustomobject]@{ Name = 'legacy loop path'; Value = ('D:' + '\gamewarden-loop') }
    [pscustomobject]@{ Name = 'standalone local runner path'; Value = ('D:' + '\gamewarden-loop-contract-review') }
    [pscustomobject]@{ Name = 'review target path'; Value = ('D:' + '\ark-server-manager-contract-review-main') }
    [pscustomobject]@{ Name = 'user profile path'; Value = ('C:' + '\Users\' + 'bruci') }
)

$strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
foreach ($path in $tracked) {
    $fullPath = Join-Path $repoRoot $path
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    if ($bytes -contains 0) { continue }
    try {
        $text = $strictUtf8.GetString($bytes)
    } catch {
        continue
    }
    foreach ($fragment in $privateFragments) {
        if ($text.IndexOf($fragment.Value, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Add-PublicRepositoryFailure "$($fragment.Name) appears in tracked file: $path"
        }
    }
}

$requiredFiles = @(
    '.github/CODEOWNERS'
    '.github/PSScriptAnalyzerSettings.psd1'
    '.github/dependabot.yml'
    '.github/workflows/ci.yml'
    '.github/workflows/dependency-review.yml'
    'SECURITY.md'
)
foreach ($required in $requiredFiles) {
    if ($required -notin $tracked) {
        Add-PublicRepositoryFailure "Required repository-security file is not tracked: $required"
    }
}

$workflowPaths = @($tracked | Where-Object { $_ -match '^\.github/workflows/.+\.ya?ml$' })
foreach ($workflowPath in $workflowPaths) {
    $workflowText = [IO.File]::ReadAllText((Join-Path $repoRoot $workflowPath), $strictUtf8)
    if ($workflowText -match '(?m)^\s*pull_request_target\s*:') {
        Add-PublicRepositoryFailure "Unsafe pull_request_target trigger is used: $workflowPath"
    }
    if ($workflowText -match '(?im)^\s*runs-on\s*:\s*.*self-hosted') {
        Add-PublicRepositoryFailure "A public workflow uses a self-hosted runner: $workflowPath"
    }
    if ($workflowText -match '(?i)\bsecrets\.') {
        Add-PublicRepositoryFailure "A public workflow references repository secrets: $workflowPath"
    }
    if ($workflowText -notmatch '(?m)^permissions:\s*$' -or
        $workflowText -notmatch '(?m)^  contents:\s*read\s*$') {
        Add-PublicRepositoryFailure "Workflow does not declare read-only contents permission: $workflowPath"
    }
    if ($workflowText -match '(?m)^\s+[A-Za-z0-9_-]+:\s*write\s*$') {
        Add-PublicRepositoryFailure "Workflow declares a write permission: $workflowPath"
    }
    foreach ($match in [regex]::Matches($workflowText, '(?m)^\s*-?\s*uses:\s*([^\s#]+)')) {
        $reference = $match.Groups[1].Value
        if ($reference.StartsWith('./', [StringComparison]::Ordinal)) { continue }
        if ($reference -notmatch '^actions/[^@]+@[0-9a-f]{40}$') {
            Add-PublicRepositoryFailure "Action is not GitHub-owned and pinned to a full SHA in ${workflowPath}: $reference"
        }
    }
}

$gitignore = Get-Content -LiteralPath (Join-Path $repoRoot '.gitignore')
foreach ($requiredIgnore in @('.env', '.env.*', '*.key', '*.pem', '*.pfx', 'runs/', 'approval-receipts/', 'requests/', 'launcher-receipts/')) {
    if ($requiredIgnore -notin $gitignore) {
        Add-PublicRepositoryFailure "Required ignore rule is missing: $requiredIgnore"
    }
}

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { [Console]::Error.WriteLine("FAIL: $_") }
    throw "Public repository validation found $($failures.Count) issue(s)."
}

Write-Host "Public repository validation passed for $($tracked.Count) tracked files and $($workflowPaths.Count) workflows."
