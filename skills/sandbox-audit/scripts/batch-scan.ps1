<#
.SYNOPSIS
    Scans every plug-in / workflow activity project under a folder and builds a batch overview.

.DESCRIPTION
    Runs scan.ps1 on each .csproj under -Folder (no code is changed) and combines the results:
      - one row per project: kind, framework, files (local / linked / shared), findings by severity,
        HTTP calls, URL problems, calls in loops, dependency candidates, signing,
        a rough effort estimate and an online-readiness estimate
      - shared files with blocked APIs that several projects in the batch compile
        ("fix these first" - one decision instead of one per project)
      - a recommended order (easy projects first, projects that depend on the shared fixes after them)
    Projects with no plug-ins / workflow activities, projects matched by skipProjects in
    sandbox-audit.json, and projects that look like full trust (API / Portal / web / test / console)
    are listed as skipped, with the reason.

    Numbers are raw scanner findings: they are an estimate of scope, not a verified result.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File batch-scan.ps1 -Folder "D:\Repo\Crm\Cs" -OutFile "$env:TEMP\sandbox-batch.json"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Folder,
    [string]$OutFile,
    [string]$Config,
    [string]$WorkDir,             # where per-project scan JSON files go (default: next to -OutFile)
    [switch]$IncludeAll           # also scan projects that would be skipped
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$Folder = (Resolve-Path -LiteralPath $Folder).Path.TrimEnd('\', '/')
$scanScript = Join-Path $PSScriptRoot 'scan.ps1'
if (-not (Test-Path -LiteralPath $scanScript)) { throw "scan.ps1 not found next to batch-scan.ps1" }
if (-not $OutFile) { $OutFile = Join-Path ([IO.Path]::GetTempPath()) ("sandbox-batch-" + (Split-Path -Leaf $Folder) + ".json") }
if (-not $WorkDir) { $WorkDir = Join-Path (Split-Path -Parent $OutFile) ('sandbox-batch-' + [IO.Path]::GetFileNameWithoutExtension($OutFile)) }
if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
$excludeDirs = '[\\/](bin|obj|packages|node_modules|\.git|\.vs)[\\/]'
$script:repoRoot = $null
function Get-Rel([string]$p) {
    foreach ($root in @($Folder, $script:repoRoot)) { if ($root -and $p -and $p.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($root.Length).TrimStart('\', '/') } }
    return $p
}

$projects = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter *.csproj -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch $excludeDirs } | Sort-Object FullName)
if (-not $projects.Count) { throw "No .csproj files found under $Folder" }

$rows = New-Object System.Collections.Generic.List[object]
$sharedHits = @{}     # shared file path -> @{ Apis; Projects }
$settingsInfo = $null
$i = 0
foreach ($pf in $projects) {
    $i++
    Write-Progress -Activity 'Sandbox batch scan' -Status $pf.BaseName -PercentComplete ([int](100 * $i / $projects.Count))
    $scanOut = Join-Path $WorkDir ($pf.BaseName + '.scan.json')
    $row = [ordered]@{ Name = $pf.BaseName; Path = $pf.FullName; RelativePath = (Get-Rel $pf.FullName); ScanFile = $scanOut; Status = 'scanned'; SkipReason = $null; Error = $null }
    try {
        $scanArgs = @{ Project = $pf.FullName; OutFile = $scanOut }
        if ($Config) { $scanArgs.Config = $Config }
        & $scanScript @scanArgs | Out-Null
        $j = Get-Content -LiteralPath $scanOut -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $settingsInfo) { $settingsInfo = $j.Settings }
        if (-not $script:repoRoot -and $j.VersionControl.Root) { $script:repoRoot = ([string]$j.VersionControl.Root).TrimEnd('\', '/') }
        $o = $j.OnlineReadiness
        $nPlugins = @($o.EntryPoints.Plugins).Count; $nWorkflows = @($o.EntryPoints.WorkflowActivities).Count
        $kind = if ($nPlugins -and $nWorkflows) { 'Plugins+WorkflowActivities' } elseif ($nPlugins) { 'Plugins' } elseif ($nWorkflows) { 'WorkflowActivities' } else { 'Other' }
        $live = @($j.Hits | Where-Object { -not $_.Accepted -and -not $_.InDebug -and $_.Severity -ne 'Using' })
        $localLive = @($live | Where-Object { $_.Source -eq 'local' })
        $sharedLive = @($live | Where-Object { $_.Source -ne 'local' })
        $sevCount = { param($list, $sev) @($list | Where-Object { $_.Severity -eq $sev }).Count }
        $urlProblems = @($o.UrlLiterals | Where-Object { -not $_.Accepted -and ($_.Class -eq 'Blocked' -or $_.Class -eq 'Internal') } | ForEach-Object { "$($_.Url) [$($_.Class): $($_.Detail)]" } | Sort-Object -Unique)
        $configUrls = @($o.HttpCalls | Where-Object { -not $_.Accepted -and $_.UrlSource -ne 'Hardcoded' })
        $deps = @($o.DependencyCandidates)
        $serializerHits = @($localLive | Where-Object { $_.Api -match 'JavaScriptSerializer|JsonConvert|JObject|Newtonsoft|ScriptIgnore' }).Count

        foreach ($h in ($sharedLive | Where-Object { $_.Severity -eq 'Blocked' -or $_.Severity -eq 'Avoid' })) {
            if (-not $sharedHits.ContainsKey($h.File)) { $sharedHits[$h.File] = @{ Apis = New-Object System.Collections.Generic.List[string]; Projects = New-Object System.Collections.Generic.List[string]; Members = New-Object System.Collections.Generic.List[string] } }
            $e = $sharedHits[$h.File]
            if (-not $e.Apis.Contains($h.Api)) { $e.Apis.Add($h.Api) }
            if (-not $e.Projects.Contains($pf.BaseName)) { $e.Projects.Add($pf.BaseName) }
            $mem = "$($h.Member):$($h.Line)"; if ($h.Member -and -not $e.Members.Contains($mem)) { $e.Members.Add($mem) }
        }

        # rough estimates (scanner data only - verified per project during migration)
        $work = (& $sevCount $localLive 'Blocked') + (& $sevCount $localLive 'Avoid') + [math]::Ceiling((& $sevCount $localLive 'Review') / 2)
        $online = 'ok'; $onlineWhy = New-Object System.Collections.Generic.List[string]
        if ($urlProblems.Count) { $online = 'fail'; $onlineWhy.Add("$($urlProblems.Count) IP / internal URL(s)") }
        if ($o.ContainsWorkflowActivities -and $deps.Count) { $online = 'fail'; $onlineWhy.Add('workflow activities with DLL dependencies: ' + (($deps | ForEach-Object { $_.Name }) -join ', ')) }
        if ($o.TargetFramework.Status -eq 'Blocked') { $online = 'fail'; $onlineWhy.Add("framework $($o.TargetFramework.Value)") }
        if (@($live | Where-Object { $_.Category -eq 'Auth' -and $_.Severity -eq 'Blocked' }).Count) { $online = 'fail'; $onlineWhy.Add('Windows credentials') }
        if ($online -ne 'fail') {
            if ($configUrls.Count) { $online = 'warn'; $onlineWhy.Add("$($configUrls.Count) URL(s) from configuration / inputs to confirm") }
            if (@($o.LoopRisks).Count) { $online = 'warn'; $onlineWhy.Add("$(@($o.LoopRisks).Count) call(s) inside loops") }
            if ($o.TargetFramework.Status -eq 'Check') { $online = 'warn'; $onlineWhy.Add("framework $($o.TargetFramework.Value)") }
            if ($o.Signing.Status -ne 'Ready') { $online = 'warn'; $onlineWhy.Add('not signed') }
            if (-not $o.ContainsWorkflowActivities -and $deps.Count) { $online = 'warn'; $onlineWhy.Add('DLL dependencies (plug-in package or remove)') }
        }
        $effort = if ($online -eq 'fail' -or $work -gt 10) { 'High' } elseif ($work -gt 0 -or $serializerHits -or $configUrls.Count -or @($o.HttpCalls).Count -gt 3) { 'Medium' } else { 'Low' }

        $skip = $null
        $hintFullTrust = $pf.BaseName -match '(?i)(\bApi\b|\.Api$|Portal|\bWeb\b|\.Web$|Tests?$|UnitTest|Console)'
        if (@($j.Settings.SkipProjects | Where-Object { $pf.BaseName -like $_ }).Count) { $skip = 'listed in skipProjects (sandbox-audit.json)' }
        elseif ($kind -eq 'Other') { $skip = 'no plug-in or workflow activity classes' }
        elseif ($hintFullTrust) { $skip = 'looks like a full-trust project (API / Portal / web / test / console)' }
        if ($skip -and -not $IncludeAll) { $row.Status = 'skipped'; $row.SkipReason = $skip }

        $row.Kind = $kind; $row.Plugins = $nPlugins; $row.WorkflowActivities = $nWorkflows
        $row.Framework = $o.TargetFramework.Value; $row.FrameworkStatus = $o.TargetFramework.Status
        $row.Files = $j.Counts.Files; $row.Local = $j.Counts.Local; $row.Linked = $j.Counts.Linked; $row.Shared = $j.Counts.Shared
        $row.Blocked = (& $sevCount $localLive 'Blocked'); $row.Avoid = (& $sevCount $localLive 'Avoid'); $row.Review = (& $sevCount $localLive 'Review')
        $row.HttpCalls = @($o.HttpCalls).Count; $row.SharedFileFindings = $sharedLive.Count; $row.Accepted = $j.Counts.Accepted
        $row.SerializerFindings = $serializerHits; $row.UrlProblems = $urlProblems; $row.UrlsToConfirm = $configUrls.Count
        $row.LoopRisks = @($o.LoopRisks).Count; $row.DependencyCandidates = @($deps | ForEach-Object { $_.Name })
        $row.Signing = $o.Signing.Status; $row.Version = $o.AssemblyVersion.Value
        $row.Effort = $effort; $row.OnlineEstimate = $online; $row.OnlineWhy = $onlineWhy.ToArray()
        $row.VersionControl = $j.VersionControl.Type
    } catch {
        $row.Status = 'error'; $row.Error = $_.Exception.Message
    }
    $rows.Add([pscustomobject]$row)
}
Write-Progress -Activity 'Sandbox batch scan' -Completed

$inBatch = @($rows | Where-Object { $_.Status -eq 'scanned' })
$batchNames = @($inBatch | ForEach-Object { $_.Name })
$shared = @($sharedHits.GetEnumerator() | ForEach-Object {
    $usedInBatch = @($_.Value.Projects | Where-Object { $batchNames -contains $_ })
    [pscustomobject]@{ File = $_.Key; RelativePath = (Get-Rel $_.Key); Apis = $_.Value.Apis.ToArray(); Members = $_.Value.Members.ToArray(); Projects = $usedInBatch; ProjectCount = $usedInBatch.Count }
} | Where-Object { $_.ProjectCount -gt 0 } | Sort-Object ProjectCount -Descending)

$rank = @{ Low = 0; Medium = 1; High = 2 }
$order = @($inBatch | Sort-Object @{ Expression = { $rank[$_.Effort] } }, @{ Expression = { $_.SharedFileFindings } }, Name | ForEach-Object { $_.Name })

$result = [pscustomobject]@{
    Mode = 'batch-scan'; Folder = $Folder; RepoRoot = $script:repoRoot; Generated = (Get-Date).ToString('s'); WorkDir = $WorkDir
    Settings = $settingsInfo
    Counts = [pscustomobject]@{
        Projects = $rows.Count; InBatch = $inBatch.Count; Skipped = @($rows | Where-Object { $_.Status -eq 'skipped' }).Count; Errors = @($rows | Where-Object { $_.Status -eq 'error' }).Count
        Low = @($inBatch | Where-Object { $_.Effort -eq 'Low' }).Count; Medium = @($inBatch | Where-Object { $_.Effort -eq 'Medium' }).Count; High = @($inBatch | Where-Object { $_.Effort -eq 'High' }).Count
        OnlineOk = @($inBatch | Where-Object { $_.OnlineEstimate -eq 'ok' }).Count; OnlineWarn = @($inBatch | Where-Object { $_.OnlineEstimate -eq 'warn' }).Count; OnlineFail = @($inBatch | Where-Object { $_.OnlineEstimate -eq 'fail' }).Count
        SharedProblemFiles = $shared.Count
    }
    Projects = $rows.ToArray()
    SharedProblems = $shared
    RecommendedOrder = $order
    ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
$od = Split-Path -Parent $OutFile; if ($od -and -not (Test-Path -LiteralPath $od)) { New-Item -ItemType Directory -Path $od | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8

$c = $result.Counts
Write-Output ("Batch: {0} - {1} projects, {2} in batch, {3} skipped, {4} errors" -f $Folder, $c.Projects, $c.InBatch, $c.Skipped, $c.Errors)
Write-Output ("Effort: {0} low, {1} medium, {2} high | Online estimate: {3} ready, {4} needs work, {5} blocked" -f $c.Low, $c.Medium, $c.High, $c.OnlineOk, $c.OnlineWarn, $c.OnlineFail)
Write-Output '--- projects (effort / online | blocked avoid review http | linked) ---'
foreach ($r in ($inBatch | Sort-Object @{ Expression = { $rank[$_.Effort] } }, Name)) {
    Write-Output ("  {0,-6} {1,-4} {2}  | {3} {4} {5} {6} | {7} linked{8}" -f $r.Effort, $r.OnlineEstimate, $r.Name, $r.Blocked, $r.Avoid, $r.Review, $r.HttpCalls, $r.Linked, $(if ($r.OnlineWhy.Count) { ' - ' + ($r.OnlineWhy -join '; ') } else { '' }))
}
if ($shared.Count) {
    Write-Output '--- shared files with blocked APIs (decide once, before the projects) ---'
    foreach ($s in $shared) { Write-Output ("  {0} - {1} - used by {2} project(s) in this batch" -f $s.RelativePath, ($s.Apis -join ', '), $s.ProjectCount) }
}
$sk = @($rows | Where-Object { $_.Status -ne 'scanned' })
if ($sk.Count) {
    Write-Output '--- skipped / errors ---'
    foreach ($r in $sk) { Write-Output ("  {0}: {1}" -f $r.Name, $(if ($r.Error) { 'ERROR ' + $r.Error } else { $r.SkipReason })) }
}
Write-Output ("Recommended order: {0}" -f ($order -join ' -> '))
Write-Output "JSON: $OutFile  ($($result.ElapsedSeconds)s)"
