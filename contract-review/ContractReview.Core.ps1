Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ContractReviewUtf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-ContractReviewSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing required file: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ContractReviewTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([Convert]::ToHexString($sha.ComputeHash($script:ContractReviewUtf8.GetBytes($Text)))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Write-ContractReviewAtomicText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = Join-Path $parent ('.{0}.tmp-{1}' -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, $Text, $script:ContractReviewUtf8)
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-ContractReviewAtomicJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][object]$Value, [int]$Depth = 64)
    Write-ContractReviewAtomicText -Path $Path -Text (($Value | ConvertTo-Json -Depth $Depth) + "`n")
}

function Read-ContractReviewJson {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Label = 'JSON file')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label does not exist: $Path" }
    try { return [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path), $script:ContractReviewUtf8) | ConvertFrom-Json -DateKind String -ErrorAction Stop }
    catch { throw "$Label is not valid UTF-8 JSON: $Path -- $($_.Exception.Message)" }
}

function Stop-ContractReviewProcessTree {
    param([Parameter(Mandatory = $true)][int]$ProcessId, [int]$WaitSeconds = 10)
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process) { return }
    if ($IsWindows) {
        $taskkillOutput = & taskkill.exe /PID $ProcessId /T /F 2>&1
        $taskkillExitCode = $LASTEXITCODE
    } else {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ((Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) { throw "Process tree rooted at PID $ProcessId did not terminate." }
    if ($IsWindows -and $taskkillExitCode -ne 0) {
        throw "Windows reported an incomplete process-tree termination for PID $ProcessId (taskkill exit $taskkillExitCode): $($taskkillOutput -join ' ')"
    }
}

function Select-ContractReviewProviderCommand {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('claude','codex')][string]$Provider,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Candidates
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($Candidates)) {
        if ([string]::IsNullOrWhiteSpace($candidate) -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $path = (Resolve-Path -LiteralPath $candidate).Path
        if (-not $seen.Add($path)) { continue }
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $global:LASTEXITCODE = 0
            $versionOutput = & $path '--version' 2>&1
            if ($LASTEXITCODE -ne 0) { continue }
            $version = ($versionOutput -join ' ').Trim()
            if ([string]::IsNullOrWhiteSpace($version)) { continue }
            return [ordered]@{ path=$path; sha256=Get-ContractReviewSha256 -Path $path; version=$version }
        } catch { Write-Verbose "Skipping unusable $Provider command '$path': $($_.Exception.Message)" }
        finally { $ErrorActionPreference = $previousErrorActionPreference }
    }
    throw "No runnable $Provider CLI command could be resolved from $($seen.Count) existing candidate(s)."
}

function Get-ContractReviewRecordedProcess {
    param([Parameter(Mandatory = $true)][string]$InvocationPath)
    $invocation = Read-ContractReviewJson -Path $InvocationPath -Label 'invocation receipt'
    $processId = [int]$invocation.adapterProcessId
    if ($processId -le 0) { return $null }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    $recordedText = [string]$invocation.adapterProcessStartTimeUtc
    if ([string]::IsNullOrWhiteSpace($recordedText)) {
        throw "Live PID $processId has no recorded start time; refusing unsafe process termination."
    }
    try {
        $recorded = ([DateTime]::Parse($recordedText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime()
    } catch {
        throw "Live PID $processId has an invalid recorded start time; refusing unsafe process termination."
    }
    if ($process.StartTime.ToUniversalTime().Ticks -ne $recorded.Ticks) {
        throw "Live PID $processId no longer matches its invocation receipt; refusing to terminate a reused PID."
    }
    return $process
}

function Stop-ContractReviewRecordedProcessTree {
    param([Parameter(Mandatory = $true)][string]$InvocationPath)
    $process = Get-ContractReviewRecordedProcess -InvocationPath $InvocationPath
    if (-not $process) { return $null }
    $processId = $process.Id
    Stop-ContractReviewProcessTree -ProcessId $processId
    return $processId
}

function Resolve-ContractReviewProviderCommand {
    param([Parameter(Mandatory = $true)][ValidateSet('claude','codex')][string]$Provider)
    $overrideName = if ($Provider -eq 'claude') { 'CONTRACT_REVIEW_CLAUDE_COMMAND' } else { 'CONTRACT_REVIEW_CODEX_COMMAND' }
    $override = [Environment]::GetEnvironmentVariable($overrideName, 'Process')
    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($override)) {
        return Select-ContractReviewProviderCommand -Provider $Provider -Candidates @($override)
    }
    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if ($Provider -eq 'claude') {
        $candidates.Add((Join-Path $appData 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'))
        foreach ($name in @('claude.exe','claude.cmd')) {
            $command = Get-Command $name -ErrorAction SilentlyContinue
            if ($command) { $candidates.Add($command.Path) }
        }
    } else {
        $managedBin = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'OpenAI\Codex\bin'
        if (Test-Path -LiteralPath $managedBin -PathType Container) {
            Get-ChildItem -LiteralPath $managedBin -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object {
                $managedCommand = Join-Path $_.FullName 'codex.exe'
                if (Test-Path -LiteralPath $managedCommand -PathType Leaf) { $candidates.Add($managedCommand) }
            }
        }
        $npmPackage = Join-Path $appData 'npm\node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor'
        if (Test-Path -LiteralPath $npmPackage -PathType Container) {
            Get-ChildItem -LiteralPath $npmPackage -Recurse -File -Filter codex.exe -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object { $candidates.Add($_.FullName) }
        }
        foreach ($name in @('codex.exe','codex.cmd')) {
            foreach ($command in @(Get-Command $name -All -ErrorAction SilentlyContinue)) { $candidates.Add($command.Path) }
        }
        $candidates.Add((Join-Path $appData 'npm\codex.cmd'))
    }
    return Select-ContractReviewProviderCommand -Provider $Provider -Candidates @($candidates)
}

function New-ContractReviewProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][hashtable]$Environment,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.Environment.Clear()
    $allowed = @('SystemRoot','WINDIR','COMSPEC','PATHEXT','PATH','TEMP','TMP','LOCALAPPDATA','APPDATA','USERPROFILE','HOMEDRIVE','HOMEPATH','USERNAME','USERDOMAIN','ProgramFiles','ProgramFiles(x86)','ProgramData','NUMBER_OF_PROCESSORS','PROCESSOR_ARCHITECTURE')
    foreach ($name in $allowed) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        if ($null -ne $value) { $info.Environment[$name] = $value }
    }
    foreach ($entry in $Environment.GetEnumerator()) {
        if ($null -ne $entry.Value) { $info.Environment[[string]$entry.Key] = [string]$entry.Value }
    }
    foreach ($argument in $Arguments) { [void]$info.ArgumentList.Add($argument) }
    return [pscustomobject]@{ Info = $info; StdoutPath = $StdoutPath; StderrPath = $StderrPath }
}

function Invoke-ContractReviewBoundedProcess {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.ProcessStartInfo]$StartInfo,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$Label,
        [int]$ProgressIntervalSeconds = 0,
        [scriptblock]$OnStarted
    )
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $StartInfo
    $process.EnableRaisingEvents = $true
    $processStarted = $false
    $stdoutTask = $null
    $stderrTask = $null
    try {
        if (-not $process.Start()) { throw "Could not start $Label." }
        $processStarted = $true
        if ($OnStarted) { & $OnStarted $process.Id }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $started = [DateTime]::UtcNow
        $deadline = $started.AddSeconds($TimeoutSeconds)
        $nextProgress = if ($ProgressIntervalSeconds -gt 0) { $started.AddSeconds($ProgressIntervalSeconds) } else { [DateTime]::MaxValue }
        while (-not $process.WaitForExit(1000)) {
            $now = [DateTime]::UtcNow
            if ($now -ge $deadline) {
                Stop-ContractReviewProcessTree -ProcessId $process.Id
                throw "$Label timed out after $TimeoutSeconds second(s); its full process tree was terminated."
            }
            if ($now -ge $nextProgress) {
                Write-Host ("[{0}] {1} still running ({2:N0}s elapsed; {3:N0}s limit)" -f [DateTime]::Now.ToString('HH:mm:ss'), $Label, ($now-$started).TotalSeconds, $TimeoutSeconds)
                $nextProgress = $now.AddSeconds($ProgressIntervalSeconds)
            }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        Write-ContractReviewAtomicText -Path $StdoutPath -Text $stdout
        Write-ContractReviewAtomicText -Path $StderrPath -Text $stderr
        if ($process.ExitCode -ne 0) { throw "$Label exited $($process.ExitCode); see $StderrPath" }
        return [pscustomobject]@{ ProcessId = $process.Id; ExitCode = $process.ExitCode; Stdout = $stdout; Stderr = $stderr }
    } catch {
        $failure = $_
        if ($processStarted -and -not $process.HasExited) { Stop-ContractReviewProcessTree -ProcessId $process.Id }
        if ($stdoutTask -and $stderrTask) {
            try { Write-ContractReviewAtomicText -Path $StdoutPath -Text $stdoutTask.GetAwaiter().GetResult(); Write-ContractReviewAtomicText -Path $StderrPath -Text $stderrTask.GetAwaiter().GetResult() } catch { }
        }
        throw $failure
    } finally { $process.Dispose() }
}

function Assert-ContractReviewProviderReadiness {
    param(
        [Parameter(Mandatory = $true)][object]$Manifest,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][string]$CodexAdapter
    )
    $checked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($role in $Manifest.providers.GetEnumerator()) {
        $configuration = $role.Value
        $provider = [string]$configuration.provider
        $commandPath = [string]$configuration.commandPath
        if (-not $checked.Add("$provider|$commandPath")) { continue }
        $arguments = if ($provider -eq 'claude') { @('auth','status') } else { @('login','status') }
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('contract-review-provider-status-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporary | Out-Null
        try {
            $extension = [IO.Path]::GetExtension($commandPath)
            if ($extension -ieq '.ps1') {
                $filePath = (Get-Command pwsh.exe -ErrorAction Stop).Path
                $processArguments = @('-NoLogo','-NoProfile','-NonInteractive','-File',$commandPath) + $arguments
            } elseif ($extension -iin @('.cmd','.bat')) {
                $filePath = [Environment]::GetEnvironmentVariable('COMSPEC','Process')
                $commandLine = '"{0}" {1}' -f $commandPath.Replace('"','""'), ($arguments -join ' ')
                $processArguments = @('/d','/s','/c',$commandLine)
            } else {
                $filePath = $commandPath
                $processArguments = $arguments
            }
            $stdoutPath = Join-Path $temporary 'stdout.log'
            $stderrPath = Join-Path $temporary 'stderr.log'
            $start = New-ContractReviewProcessStartInfo -FilePath $filePath -Arguments $processArguments -WorkingDirectory $temporary -Environment @{} -StdoutPath $stdoutPath -StderrPath $stderrPath
            try {
                $result = Invoke-ContractReviewBoundedProcess -StartInfo $start.Info -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds -Label "$provider authentication readiness"
            } catch {
                throw "Required provider '$provider' is not authenticated or its login status could not be verified. Authenticate that CLI and retry."
            }
            if ($provider -eq 'claude') {
                try { $status = $result.Stdout | ConvertFrom-Json -ErrorAction Stop } catch { throw "Required provider 'claude' is not authenticated or returned an unreadable login status. Authenticate that CLI and retry." }
                if ($status.loggedIn -ne $true) { throw "Required provider 'claude' is not authenticated. Authenticate the Claude CLI and retry." }
            } elseif ($result.Stdout -match '(?i)\bnot logged in\b') {
                throw "Required provider 'codex' is not authenticated. Authenticate the Codex CLI and retry."
            }
            if ($provider -eq 'codex') {
                Assert-ContractReviewCodexIsolation -Configuration $configuration -Adapter $CodexAdapter -TimeoutSeconds $TimeoutSeconds
            }
        } finally {
            Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-ContractReviewCodexIsolation {
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$Adapter,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )
    if (-not (Test-Path -LiteralPath $Adapter -PathType Leaf)) { throw "Codex isolation adapter does not exist: $Adapter" }
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('contract-review-codex-preflight-' + [guid]::NewGuid().ToString('N'))
    $providerCwd = Join-Path $temporary 'provider-cwd'
    New-Item -ItemType Directory -Path $temporary,$providerCwd | Out-Null
    try {
        $promptPath = Join-Path $temporary 'prompt.txt'
        $outputPath = Join-Path $temporary 'response.json'
        $metadataPath = Join-Path $temporary 'provider.json'
        $schemaPath = Join-Path $temporary 'response-schema.json'
        $stdoutPath = Join-Path $temporary 'stdout.log'
        $stderrPath = Join-Path $temporary 'stderr.log'
        $fileCanaryPath = Join-Path $temporary 'host-canary.txt'
        $fileCanary = 'file-' + [guid]::NewGuid().ToString('N')
        $environmentCanary = 'environment-' + [guid]::NewGuid().ToString('N')
        Write-ContractReviewAtomicText -Path $fileCanaryPath -Text $fileCanary
        Write-ContractReviewAtomicText -Path $promptPath -Text @'
This is a capability isolation preflight, not a contract review.
Return status "blocker" with a precise reason and every response array empty if any callable tool or tool namespace is available; any skill, plugin, MCP server, hook, memory, browser, computer-use, shell, app, or workspace capability is available; any project or user guidance beyond this prompt is present; or you can retrieve the value of environment variable UNRELATED_ENVIRONMENT_CANARY or read ..\host-canary.txt.
Do not guess either canary value. Attempt those reads only if a callable capability is actually available.
Return status "ok", reason null, and every response array empty only when none of those capabilities or context sources is available.
'@
        [void](New-ContractReviewRoleSchema -BaseSchemaPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas\agent-response.schema.json') -Role blind-reviewer -Path $schemaPath)
        $environment = @{
            CONTRACT_REVIEW_ROLE='blind-reviewer';CONTRACT_REVIEW_ARTIFACT_NAME='codex-isolation-preflight';CONTRACT_REVIEW_PROMPT_FILE=$promptPath
            CONTRACT_REVIEW_OUTPUT_PATH=$outputPath;CONTRACT_REVIEW_METADATA_PATH=$metadataPath;CONTRACT_REVIEW_MODEL=[string]$Configuration.model
            CONTRACT_REVIEW_REASONING_EFFORT=[string]$Configuration.reasoningEffort;CONTRACT_REVIEW_SCHEMA_PATH=$schemaPath
            CONTRACT_REVIEW_PROVIDER_COMMAND=[string]$Configuration.commandPath;CONTRACT_REVIEW_PROVIDER_CWD=$providerCwd
            CONTRACT_REVIEW_ISOLATION_PREFLIGHT='1';UNRELATED_ENVIRONMENT_CANARY=$environmentCanary
        }
        $start = New-ContractReviewProcessStartInfo -FilePath (Get-Command pwsh.exe -ErrorAction Stop).Path -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-File',$Adapter) -WorkingDirectory $providerCwd -Environment $environment -StdoutPath $stdoutPath -StderrPath $stderrPath
        try {
            [void](Invoke-ContractReviewBoundedProcess -StartInfo $start.Info -StdoutPath $stdoutPath -StderrPath $stderrPath -TimeoutSeconds $TimeoutSeconds -Label 'Codex capability isolation preflight')
        } catch {
            throw "Codex isolation preflight could not establish a clean session: $($_.Exception.Message)"
        }
        $response = Read-ContractReviewJson -Path $outputPath -Label 'Codex isolation preflight response'
        try { Assert-ContractReviewResponse -Response $response -Role blind-reviewer }
        catch { throw "Codex isolation preflight reported exposed context or capabilities: $($_.Exception.Message)" }
        $nonEmptyArrays = @('findings','classifications','proofs','resolutions','unresolved','stage1Manifest' | Where-Object { @($response.$_).Count -ne 0 })
        if ([string]$response.status -ne 'ok' -or $null -ne $response.reason -or $nonEmptyArrays.Count -ne 0) {
            throw "Codex isolation preflight reported exposed context or capabilities: $([string]$response.reason)"
        }
        $metadata = Read-ContractReviewJson -Path $metadataPath -Label 'Codex isolation preflight metadata'
        if ($metadata.isolatedWorkingDirectory -ne $true) { throw 'Codex isolation preflight did not use a fresh empty provider working directory.' }
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ContractReviewGit {
    param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string[]]$Arguments, [int]$TimeoutSeconds = 60)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('contract-review-git-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $environment = @{}
        $start = New-ContractReviewProcessStartInfo -FilePath (Get-Command git.exe -ErrorAction Stop).Path -Arguments (@('-C', $Repository) + $Arguments) -WorkingDirectory $Repository -Environment $environment -StdoutPath (Join-Path $tempRoot 'stdout') -StderrPath (Join-Path $tempRoot 'stderr')
        $result = Invoke-ContractReviewBoundedProcess -StartInfo $start.Info -StdoutPath $start.StdoutPath -StderrPath $start.StderrPath -TimeoutSeconds $TimeoutSeconds -Label "git $($Arguments -join ' ')"
        return $result.Stdout.Trim()
    } finally { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

function Assert-ContractReviewTarget {
    param([Parameter(Mandatory = $true)][string]$Repository, [int]$TimeoutSeconds = 60)
    $repositoryPath = (Resolve-Path -LiteralPath $Repository).Path
    if (Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('status','--porcelain') -TimeoutSeconds $TimeoutSeconds) { throw "Target checkout is dirty: $repositoryPath" }
    $branch = Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('branch','--show-current') -TimeoutSeconds $TimeoutSeconds
    $remotes = @((Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('remote') -TimeoutSeconds $TimeoutSeconds) -split "`n")
    if ($remotes -contains 'origin') {
        [void](Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('fetch','origin') -TimeoutSeconds $TimeoutSeconds)
        $revision = Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('rev-parse','origin/main') -TimeoutSeconds $TimeoutSeconds
        $head = Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('rev-parse','HEAD') -TimeoutSeconds $TimeoutSeconds
        if ($head -ne $revision) { throw "Target checkout is not exactly current origin/main ($head vs $revision)." }
        if ($branch -and $branch -ne 'main') { throw "Target checkout must be main or detached, found '$branch'." }
    } else {
        if ($branch -ne 'main') { throw "Target checkout without origin must be main, found '$branch'." }
        $revision = Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('rev-parse','HEAD') -TimeoutSeconds $TimeoutSeconds
    }
    if (Invoke-ContractReviewGit -Repository $repositoryPath -Arguments @('status','--porcelain') -TimeoutSeconds $TimeoutSeconds) { throw "Target checkout changed while resolving the revision: $repositoryPath" }
    return [pscustomobject]@{ Path = $repositoryPath; Revision = $revision }
}

function Get-ContractReviewGitObjectId {
    param([string]$Repository, [string]$Revision, [string]$RelativePath, [int]$TimeoutSeconds = 60)
    $normalized = $RelativePath.Replace('\','/')
    try { return Invoke-ContractReviewGit -Repository $Repository -Arguments @('rev-parse', "${Revision}:$normalized") -TimeoutSeconds $TimeoutSeconds }
    catch { throw "Pinned file is missing at $Revision`: $RelativePath" }
}

function Get-ContractReviewArtifactHashes {
    param([Parameter(Mandatory = $true)][string]$RunDirectory)
    $hashes = [ordered]@{}
    Get-ChildItem -LiteralPath $RunDirectory -Recurse -File | Where-Object { $_.Name -notin @('decision-packet.json','decision-packet.md') } | Sort-Object FullName | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($RunDirectory, $_.FullName).Replace('\','/')
        $hashes[$relative] = Get-ContractReviewSha256 -Path $_.FullName
    }
    return $hashes
}

function Test-ContractReviewPathWithin {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    $relative = [IO.Path]::GetRelativePath([IO.Path]::GetFullPath($Root), [IO.Path]::GetFullPath($Path))
    return -not ([IO.Path]::IsPathRooted($relative) -or $relative -eq '..' -or $relative.StartsWith("..$([IO.Path]::DirectorySeparatorChar)"))
}
