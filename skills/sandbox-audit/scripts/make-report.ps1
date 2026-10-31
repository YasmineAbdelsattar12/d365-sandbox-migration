<#
.SYNOPSIS
    Builds the Sandbox migration report (HTML + PDF) for one project.

.DESCRIPTION
    Inputs:
      -Data    report-data.json written by Claude at the end of the run (schema: references/report-schema.md)
      -Scan    the scanner JSON from scan.ps1 (optional - adds file lists and scan statistics)
      -Repo    git repository root (optional - adds the real code diff since -BaseCommit)
    Output:
      <OutDir>\<Project>-sandbox-migration-<yyyyMMdd-HHmm>.html and .pdf
    The PDF is produced with Microsoft Edge (or Chrome) in headless mode - both are
    already installed on Windows. If no browser is found the HTML is kept and can be
    printed to PDF manually.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File make-report.ps1 -Data "$env:TEMP\report-data.json" -Scan "$env:TEMP\sandbox-scan-X.json" -Repo "D:\Gea" -OutDir "D:\Gea\docs\sandbox-migration" -Open
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Data,
    [string]$Scan,
    [string]$Repo,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Browser,              # optional explicit path to msedge.exe / chrome.exe
    [int]$MaxDiffLinesPerFile = 400,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
function E([object]$s) { if ($null -eq $s) { return '' }; return [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Arr($x) { if ($null -eq $x) { return @() }; return @($x) }
function Has($x) { return (Arr $x).Count -gt 0 }

function Get-StatusInfo([object]$s) {
    $t = ([string]$s).Trim()
    switch -regex ($t) {
        '^(ok|ready|pass|success|yes|true|\u2705)'        { return @('ok', 'Ready') }
        '^(warn|check|needs|review|partial|\u26A0)'       { return @('warn', 'Needs work') }
        '^(fail|blocked|error|no|false|\u274C)'           { return @('fail', 'Blocked') }
        default                                           { return @('info', $t) }
    }
}
function Badge([object]$s, [string]$label) {
    $i = Get-StatusInfo $s
    $text = if ($label) { $label } else { $i[1] }
    return "<span class=""badge $($i[0])"">$(E $text)</span>"
}
function Table([string[]]$headers, $rows) {
    $rows = @($rows)
    if ($rows.Count -and -not ($rows[0] -is [array])) { $rows = , $rows }   # single row was unwrapped by PowerShell
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($h in $headers) { [void]$sb.Append("<th>$(E $h)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $rows) { [void]$sb.Append('<tr>'); foreach ($c in $r) { [void]$sb.Append("<td>$c</td>") }; [void]$sb.Append('</tr>') }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}
function List($items) {
    if (-not (Has $items)) { return '<p class="muted">None.</p>' }
    return '<ul>' + ((Arr $items | ForEach-Object { "<li>$(E $_)</li>" }) -join '') + '</ul>'
}
function Code([string]$s) { return "<code>$(E $s)</code>" }

# ---------------------------------------------------------------- load inputs
$d = Get-Content -LiteralPath $Data -Raw -Encoding UTF8 | ConvertFrom-Json
$scanJson = $null
if ($Scan -and (Test-Path -LiteralPath $Scan)) { $scanJson = Get-Content -LiteralPath $Scan -Raw -Encoding UTF8 | ConvertFrom-Json }
$project = if ($d.Project) { $d.Project } elseif ($scanJson) { $scanJson.Project } else { 'Project' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$base = Join-Path $OutDir ("{0}-sandbox-migration-{1}" -f ($project -replace '[^\w\.\-]', '_'), $stamp)
$htmlPath = "$base.html"; $pdfPath = "$base.pdf"
$s = $d.Summary

# ---------------------------------------------------------------- git diff
$diffBlocks = New-Object System.Collections.Generic.List[string]
$diffStat = $null
if ($Repo -and (Test-Path -LiteralPath $Repo) -and (Has $d.ChangedPaths)) {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
        $repoFull = (Resolve-Path -LiteralPath $Repo).Path
        $baseRef = if ($d.BaseCommit) { $d.BaseCommit } else { 'HEAD' }
        $paths = Arr $d.ChangedPaths
        try { $diffStat = (& git -C $Repo diff --no-color --stat $baseRef -- $paths 2>$null) -join "`n" } catch { }
        foreach ($p in $paths) {
            $tracked = $true
            & git -C $Repo ls-files --error-unmatch -- $p 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { $tracked = $false }
            $lines = @()
            if ($tracked) {
                try { $lines = @(& git -C $Repo diff --no-color -U3 $baseRef -- $p 2>$null) } catch { $lines = @() }
                $lines = @($lines | Where-Object { $_ -notmatch '^(diff --git|index |--- |\+\+\+ )' })
            } elseif (Test-Path -LiteralPath (Join-Path $Repo $p)) {
                $lines = @('@@ new file @@') + @([IO.File]::ReadAllLines((Join-Path $Repo $p)) | ForEach-Object { '+' + $_ })
            } elseif (Test-Path -LiteralPath $p) {
                $lines = @('@@ new file @@') + @([IO.File]::ReadAllLines($p) | ForEach-Object { '+' + $_ })
            }
            if (-not $lines.Count) { continue }
            $truncated = $false
            if ($lines.Count -gt $MaxDiffLinesPerFile) { $lines = $lines[0..($MaxDiffLinesPerFile - 1)]; $truncated = $true }
            $sb = New-Object System.Text.StringBuilder
            $shown = if ($p.StartsWith($repoFull, [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($repoFull.Length).TrimStart('\', '/') } else { $p }
            [void]$sb.Append("<div class=""diff""><div class=""diff-file"">$(E $shown)$(if (-not $tracked) { ' <span class="badge info">new file</span>' })</div><pre>")
            foreach ($l in $lines) {
                $cls = if ($l.StartsWith('@@')) { 'h' } elseif ($l.StartsWith('+')) { 'a' } elseif ($l.StartsWith('-')) { 'r' } else { 'c' }
                [void]$sb.Append("<span class=""$cls"">$(E $l)</span>")
            }
            [void]$sb.Append('</pre>')
            if ($truncated) { [void]$sb.Append("<div class=""muted small"">Diff truncated after $MaxDiffLinesPerFile lines - see git for the full change.</div>") }
            [void]$sb.Append('</div>')
            $diffBlocks.Add($sb.ToString())
        }
    }
}

# ---------------------------------------------------------------- sections
$sec = New-Object System.Collections.Generic.List[string]
$n = 0
function Add-Section([string]$title, [string]$body) { $script:n++; $script:sec.Add("<section><h2><span class=""num"">$($script:n)</span>$(E $title)</h2>$body</section>") }

# 1. Summary
$kv = @(
    @('Project', (E $project)),
    @('Assembly', (E $d.Assembly)),
    @('Target environment', (E $d.Target)),
    @('Files scanned', (E ("{0} ({1} local, {2} linked, {3} shared)" -f $s.FilesScanned, $s.Local, $s.Linked, $s.Shared))),
    @('Files modified', (E $s.FilesModified)),
    @('New files', $(if (Has $s.NewFiles) { E ((Arr $s.NewFiles) -join ', ') } else { 'None' })),
    @('Build', ((Badge $s.BuildResult $s.BuildResult) + ' ' + (E $s.DllPath))),
    @('Assembly size', (E $s.DllSize)),
    @('Version / signature', (E ("{0} - public key token {1}" -f $s.DllVersion, $s.PublicKeyToken))),
    @('Git baseline', (E $s.GitBaseline)),
    @('Online readiness', (Badge $s.OnlineVerdict $s.OnlineVerdictText))
)
$sumHtml = '<table class="kv"><tbody>' + (($kv | ForEach-Object { "<tr><th>$($_[0])</th><td>$($_[1])</td></tr>" }) -join '') + '</tbody></table>'
if ($scanJson) {
    $c = $scanJson.Counts
    $sumHtml += "<p class=""muted small"">Scanner: $($c.Hits) pattern hits in $($c.FilesWithHits) files - Blocked $($c.Blocked), Avoid $($c.Avoid), Review $($c.Review), HTTP $($c.Harden).</p>"
}
Add-Section 'Summary' $sumHtml

# 2. Changes made
if (Has $d.Changes) {
    $rows = foreach ($ch in (Arr $d.Changes)) {
        $tag = if ($ch.Tag) { " <span class=""badge info"">$(E $ch.Tag)</span>" } else { '' }
        $desc = '<ul>' + ((Arr $ch.Description | ForEach-Object { "<li>$(E $_)</li>" }) -join '') + '</ul>'
        , @(((Code $ch.File) + $tag), $desc, (E $ch.Lines))
    }
    Add-Section 'Changes made' (Table @('File', 'Change', 'Lines') $rows)
} else { Add-Section 'Changes made' '<p class="muted">No source changes were needed.</p>' }

# 3. Code diff
if ($diffBlocks.Count) {
    $intro = "<p class=""muted small"">Compared with commit $(Code $(if ($d.BaseCommit) { $d.BaseCommit } else { 'HEAD' })). Green = added, red = removed.</p>"
    if ($diffStat) { $intro += "<pre class=""stat"">$(E $diffStat)</pre>" }
    Add-Section 'Code changes (diff)' ($intro + ($diffBlocks -join ''))
}

# 4. Linked & shared files
if ($scanJson) {
    $lf = @(Arr $scanJson.Files | Where-Object { $_.Source -ne 'local' })
    if ($lf.Count) {
        $rootForRel = if ($Repo -and (Test-Path -LiteralPath $Repo)) { (Resolve-Path -LiteralPath $Repo).Path } else { $null }
        $rows = foreach ($f in $lf) {
            $fp = if ($rootForRel -and $f.Path.StartsWith($rootForRel, [StringComparison]::OrdinalIgnoreCase)) { $f.Path.Substring($rootForRel.Length).TrimStart('\', '/') } else { $f.Path }
            , @((E $f.Source.ToUpper()), (Code $fp), (E $(if ($f.SharedByProjects) { $f.SharedByProjects } else { '-' })), (E $f.Hits)) }
        Add-Section 'Linked & shared files scanned' (Table @('Type', 'File', 'Linked by (projects)', 'Hits') $rows)
    }
}

# 5. Blocked APIs left in place
if (Has $d.LeftInPlace) {
    $rows = foreach ($x in (Arr $d.LeftInPlace)) { , @((Code $x.Location), (Code $x.Api), (E $x.Evidence)) }
    Add-Section 'Blocked APIs left in place (never run in this assembly)' (Table @('Location', 'Blocked API', 'Evidence') $rows)
}

# 6. Review items
$rv = ''
if (Has $d.LeftOnPurpose) { $rv += '<h3>Left as-is on purpose</h3>' + (List $d.LeftOnPurpose) }
if (Has $d.NeedsVerification) { $rv += '<h3>Needs verification</h3>' + (List $d.NeedsVerification) }
if (Has $d.NeedsDecision) { $rv += '<h3>Needs decision</h3>' + (List $d.NeedsDecision) }
if (Has $d.ProjectsToRebuild) { $rv += '<h3>Projects to rebuild</h3>' + (List $d.ProjectsToRebuild) }
if ($rv) { Add-Section 'Items for the team' $rv }

# 7. References
if ($d.References) {
    $r = $d.References
    $kept = Arr $r.Kept | ForEach-Object { "$($_.Name) - $($_.Reason)" }
    Add-Section 'References & packages' ('<h3>Removed</h3>' + (List $r.Removed) + '<h3>Kept</h3>' + (List $kept) + '<h3>Added</h3>' + (List $r.Added))
}

# 8. Online readiness
if ($d.Online) {
    $o = $d.Online
    $body = "<p>Overall: $(Badge $s.OnlineVerdict $s.OnlineVerdictText)</p>"
    if (Has $o.Checks) {
        $rows = foreach ($x in (Arr $o.Checks)) { , @((E $x.Name), (Badge $x.Status), (E $x.Detail)) }
        $body += '<h3>Project checks</h3>' + (Table @('Check', 'Status', 'Detail') $rows)
    }
    if (Has $d.Dependencies) {
        $rows = foreach ($x in (Arr $d.Dependencies)) { , @((Code $x.Name), (E $x.Version), (Badge $x.Status), (E $x.Note)) }
        $body += '<h3>Runtime dependencies (compiled DLL)</h3>' + (Table @('Assembly', 'Version', 'Status', 'Note') $rows)
    }
    if (Has $o.HttpCalls) {
        $i = 0
        $rows = foreach ($x in (Arr $o.HttpCalls)) { $i++; , @((E $i), (E $x.Location), (E $x.Call), (E $x.UrlSource), (Badge $x.Status), (E $x.Note)) }
        $body += '<h3>HTTP endpoints</h3>' + (Table @('#', 'Class / method', 'Call', 'URL comes from', 'Status', 'Note') $rows)
    }
    if (Has $o.LoopRisks) {
        $rows = foreach ($x in (Arr $o.LoopRisks)) { , @((E $x.Location), (E $x.Call), (E $x.Note)) }
        $body += '<h3>Calls inside loops (2-minute limit risk)</h3>' + (Table @('Location', 'Call', 'Note') $rows)
    }
    if (Has $o.GoLiveActions) {
        $body += '<h3>What the team must do before go-live</h3><ol>' + ((Arr $o.GoLiveActions | ForEach-Object { "<li>$(E $_)</li>" }) -join '') + '</ol>'
    }
    Add-Section 'Dataverse Online readiness' $body
}

# 9. Next steps & tests
$ns = ''
if (Has $d.NextSteps) { $ns += '<h3>Next steps</h3><ol>' + ((Arr $d.NextSteps | ForEach-Object { "<li>$(E $_)</li>" }) -join '') + '</ol>' }
if (Has $d.Tests) { $ns += '<h3>Test checklist</h3><ul class="check">' + ((Arr $d.Tests | ForEach-Object { "<li>$(E $_)</li>" }) -join '') + '</ul>' }
if ($ns) { Add-Section 'Next steps & testing' $ns }

# Appendix: scanner hits
if ($scanJson -and (Has $scanJson.Hits)) {
    $rows = foreach ($h in (Arr $scanJson.Hits | Sort-Object Source, File, Line)) {
        , @((E ([IO.Path]::GetFileName($h.File) + ':' + $h.Line)), (E $h.Severity), (E $h.Category), (E $h.Api), (E $h.Member))
    }
    Add-Section 'Appendix - scanner findings' ('<p class="muted small">Raw pattern hits before analysis. Not every hit is a violation - see sections above for what was fixed and why.</p>' + (Table @('Location', 'Severity', 'Category', 'API', 'Method') $rows))
}

# ---------------------------------------------------------------- page
$verdictInfo = Get-StatusInfo $s.OnlineVerdict
$generated = Get-Date -Format 'dd MMM yyyy, HH:mm'
$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>$(E $project) - Sandbox Migration Report</title>
<style>
@page { size: A4; margin: 16mm 14mm 18mm 14mm; }
* { box-sizing: border-box; }
body { font-family: "Segoe UI", "Helvetica Neue", Arial, sans-serif; color: #1f2933; font-size: 10.5pt; line-height: 1.45; margin: 0; }
.cover { border-bottom: 3px solid #1d4e89; padding: 6mm 0 5mm; margin-bottom: 6mm; }
.cover .kicker { text-transform: uppercase; letter-spacing: .12em; font-size: 8.5pt; color: #52606d; font-weight: 600; }
.cover h1 { font-size: 22pt; margin: 2mm 0 1mm; color: #102a43; }
.cover .meta { color: #52606d; font-size: 9.5pt; }
.cover .verdict { margin-top: 4mm; font-size: 11pt; }
h2 { font-size: 13.5pt; color: #102a43; border-bottom: 1px solid #d9e2ec; padding-bottom: 1.5mm; margin: 8mm 0 3mm; break-after: avoid; }
h2 .num { display: inline-block; min-width: 7mm; color: #1d4e89; }
h3 { font-size: 11pt; color: #243b53; margin: 5mm 0 2mm; break-after: avoid; }
section { break-inside: auto; }
table { width: 99.6%; border-collapse: collapse; margin: 2mm 0 3mm; font-size: 9.5pt; }
th, td { border: 1px solid #d9e2ec; padding: 1.6mm 2.2mm; vertical-align: top; text-align: left; }
thead th { background: #f0f4f8; color: #243b53; font-weight: 600; }
tr { break-inside: avoid; }
table.kv th { width: 34%; background: #f8fafc; font-weight: 600; }
td ul { margin: 0; padding-left: 4.5mm; }
code { font-family: Consolas, "Cascadia Mono", Menlo, monospace; font-size: 8.8pt; background: #f0f4f8; padding: 0 1mm; border-radius: 1mm; word-break: break-all; }
.badge { display: inline-block; padding: .3mm 2mm; border-radius: 3mm; font-size: 8.5pt; font-weight: 600; white-space: nowrap; }
.badge.ok { background: #e3f9e5; color: #0e5c2f; border: 1px solid #a3d9a5; }
.badge.warn { background: #fff8e1; color: #8a5a00; border: 1px solid #f0d58c; }
.badge.fail { background: #ffe8e8; color: #9b1c1c; border: 1px solid #f5b5b5; }
.badge.info { background: #e6f0ff; color: #1d4e89; border: 1px solid #b3cdf5; }
.muted { color: #616e7c; } .small { font-size: 8.8pt; }
.diff { border: 1px solid #d9e2ec; border-radius: 1.5mm; margin: 3mm 0; break-inside: auto; }
.diff-file { background: #f0f4f8; padding: 1.5mm 2.5mm; font-family: Consolas, Menlo, monospace; font-size: 8.8pt; font-weight: 600; border-bottom: 1px solid #d9e2ec; }
pre { margin: 0; padding: 2mm 2.5mm; font-family: Consolas, "Cascadia Mono", Menlo, monospace; font-size: 7.8pt; line-height: 1.35; white-space: pre-wrap; word-break: break-all; }
pre span { display: block; } pre .a { background: #e6ffed; color: #0e5c2f; } pre .r { background: #ffeef0; color: #9b1c1c; } pre .h { color: #1d4e89; background: #f0f4ff; } pre .c { color: #3e4c59; }
pre.stat { background: #f8fafc; border: 1px solid #d9e2ec; border-radius: 1.5mm; margin-bottom: 3mm; }
ul.check { list-style: none; padding-left: 1mm; } ul.check li::before { content: "\2610  "; color: #52606d; }
.footer { margin-top: 10mm; padding-top: 2mm; border-top: 1px solid #d9e2ec; color: #7b8794; font-size: 8.5pt; }
</style></head>
<body>
<div class="cover">
  <div class="kicker">D365 Sandbox Migration Report</div>
  <h1>$(E $project)</h1>
  <div class="meta">Assembly $(E $d.Assembly) &nbsp;&middot;&nbsp; Target: $(E $d.Target) &nbsp;&middot;&nbsp; $(E $generated)$(if ($d.Author) { " &nbsp;&middot;&nbsp; Prepared by $(E $d.Author)" })</div>
  <div class="verdict">Build $(Badge $s.BuildResult $s.BuildResult) &nbsp; Online readiness $(Badge $s.OnlineVerdict $s.OnlineVerdictText)</div>
</div>
$($sec -join "`n")
<div class="footer">Generated by the d365-sandbox-migration plugin$(if ($d.SkillVersion) { " v$(E $d.SkillVersion)" }) on $(E $generated). Code changes are shown against commit $(E $(if ($d.BaseCommit) { $d.BaseCommit } else { 'HEAD' })).</div>
</body></html>
"@
[IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($true)))

# ---------------------------------------------------------------- PDF via headless Edge / Chrome
$candidates = @()
if ($Browser) { $candidates += $Browser }
$pf86 = ${env:ProgramFiles(x86)}
foreach ($root in @($pf86, $env:ProgramFiles, $env:LOCALAPPDATA)) {
    if (-not $root) { continue }
    $candidates += (Join-Path $root 'Microsoft\Edge\Application\msedge.exe')
    $candidates += (Join-Path $root 'Google\Chrome\Application\chrome.exe')
}
$exe = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
$pdfOk = $false
if ($exe) {
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) ("sandbox-report-browser-" + [guid]::NewGuid().ToString('N'))
    $uri = (New-Object System.Uri($htmlPath)).AbsoluteUri
    # Windows: Start-Process builds one command line, so values with spaces need quotes.
    # Other OSes (testing only): arguments are passed as-is, quotes would become part of the value.
    $q = if ([Environment]::OSVersion.Platform.ToString().StartsWith('Win')) { '"' } else { '' }
    $argList = @('--headless', '--disable-gpu', '--no-first-run', '--no-default-browser-check', '--disable-extensions',
        "--user-data-dir=$q$profileDir$q", '--no-pdf-header-footer', '--print-to-pdf-no-header',
        "--print-to-pdf=$q$pdfPath$q", "$q$uri$q")
    if (-not $q) { $argList += '--no-sandbox' }
    try {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
    } catch {
        $proc = Start-Process -FilePath $exe -ArgumentList $argList -Wait -PassThru -ErrorAction SilentlyContinue
    }
    for ($w = 0; $w -lt 20 -and -not (Test-Path -LiteralPath $pdfPath); $w++) { Start-Sleep -Milliseconds 500 }
    $pdfOk = Test-Path -LiteralPath $pdfPath
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "HTML: $htmlPath"
if ($pdfOk) {
    Write-Output "PDF:  $pdfPath"
    if ($Open) { Start-Process -FilePath $pdfPath }
} else {
    Write-Output "PDF:  not created (Edge/Chrome not found or failed) - open the HTML and use Print > Save as PDF"
    if ($Open) { Start-Process -FilePath $htmlPath }
}
