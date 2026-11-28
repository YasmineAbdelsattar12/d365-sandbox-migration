<#
.SYNOPSIS
    Fast, deterministic Sandbox pre-scan for a D365 plugin / workflow activity project.

.DESCRIPTION
    1. Parses the .csproj (legacy or SDK-style) and resolves EVERY compiled .cs file:
       local files, linked files (<Compile Include="..\x.cs"><Link>), wildcards,
       and shared projects (<Import Project="*.projitems">).
    2. Scans each compiled file once for Sandbox-blocked / risky API patterns.
    3. Optionally (-SolutionRoot) finds how many other projects link the same files,
       and where an AppSerializer class already exists in the solution.
    4. Online readiness inputs: every HTTP call and where its URL comes from
       (hard-coded / configuration / workflow input / step config / parameter),
       hard-coded URL classification (IP, internal host, port), service or HTTP
       calls inside loops, plug-in vs workflow-activity entry points, target
       framework, signing, assembly version, and dependency candidates.
    5. Writes the full result as JSON (-OutFile) and prints a compact summary.

    The scanner only FINDS candidates. Claude still reads each hit in context,
    verifies callers, and decides what to fix.

    6. Team settings: reads sandbox-audit.json (found next to the project or in any parent
       folder up to -SolutionRoot, or given with -Config) - accepted findings, serializer
       strategy, shared helper folder, projects to skip, defaults. Inline
       "// sandbox-ignore: reason" comments (same line or line above) also accept a finding.
    7. -ListProjects: lists every project under -SolutionRoot (plug-ins / workflow activities /
       other, framework, shared folders it links from) - used by setup mode.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -Project "D:\Repo\Cs\My.Plugin" -SolutionRoot "D:\Repo" -OutFile "$env:TEMP\scan.json"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -ListProjects -SolutionRoot "D:\Repo" -OutFile "$env:TEMP\projects.json"
#>
[CmdletBinding()]
param(
    [string]$Project,                                    # .csproj path or folder containing one (not needed with -ListProjects)
    [string]$OutFile,                                    # JSON output path (default: %TEMP%\sandbox-scan-<project>.json)
    [string]$SolutionRoot,                               # optional: folder to search for other projects / serializers
    [string]$Config,                                     # optional: explicit path to sandbox-audit.json
    [switch]$ListProjects                                # list all projects under -SolutionRoot and exit
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$isWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
$sep = [IO.Path]::DirectorySeparatorChar
$cmp = if ($isWin) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$excludeDirs = '[\\/](bin|obj|packages|node_modules|\.git|\.vs)[\\/]'

# ---------------------------------------------------------------- project path
if ($ListProjects) {
    if (-not $SolutionRoot) { throw '-ListProjects needs -SolutionRoot' }
    $Project = $null
}
elseif (-not $Project) { throw 'Pass -Project (a .csproj or its folder), or -ListProjects with -SolutionRoot' }
if ($ListProjects) { $csproj = $null; $projDir = (Resolve-Path -LiteralPath $SolutionRoot).Path; $projName = 'projects' }
elseif (Test-Path -LiteralPath $Project -PathType Container) {
    $found = @(Get-ChildItem -LiteralPath $Project -Filter *.csproj -File)
    if ($found.Count -eq 0) { throw "No .csproj found in $Project" }
    if ($found.Count -gt 1) { throw "Multiple .csproj files in $Project - pass one explicitly: $($found.Name -join ', ')" }
    $csproj = $found[0].FullName
} else {
    $csproj = (Resolve-Path -LiteralPath $Project).Path
}
if (-not $ListProjects) {
    $projDir = Split-Path -Parent $csproj
    $projName = [IO.Path]::GetFileNameWithoutExtension($csproj)
}
if (-not $OutFile) { $OutFile = Join-Path ([IO.Path]::GetTempPath()) "sandbox-scan-$projName.json" }
if ($SolutionRoot) { $SolutionRoot = (Resolve-Path -LiteralPath $SolutionRoot).Path }

# ---------------------------------------------------------------- team settings (sandbox-audit.json) + version control
function Get-Prop($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value) { return $p.Value } else { return $default }
}
function Resolve-CfgPath([string]$p, [string]$baseDir) {
    if (-not $p) { return $null }
    $p = $p -replace '[\\/]', $sep
    if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p) }
    return [IO.Path]::GetFullPath((Join-Path $baseDir $p))
}
$cfgErrors = New-Object System.Collections.Generic.List[string]
$cfgWarnings = New-Object System.Collections.Generic.List[string]
$cfgPath = $null
if ($Config) {
    if (Test-Path -LiteralPath $Config) { $cfgPath = (Resolve-Path -LiteralPath $Config).Path } else { $cfgErrors.Add("Config file not found: $Config") }
} else {
    $dir = $projDir
    while ($dir) {
        $candidate = Join-Path $dir 'sandbox-audit.json'
        if (Test-Path -LiteralPath $candidate) { $cfgPath = $candidate; break }
        if ($SolutionRoot -and $dir.TrimEnd('\', '/') -eq $SolutionRoot.TrimEnd('\', '/')) { break }
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
}
$raw = $null
if ($cfgPath) {
    try { $raw = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { $cfgErrors.Add("sandbox-audit.json is not valid JSON: $($_.Exception.Message)") }
}
$cfgDir = if ($cfgPath) { Split-Path -Parent $cfgPath } else { $null }
$target = ([string](Get-Prop $raw 'target' 'ask')).ToLowerInvariant()
if ($target -notin @('online', 'onprem', 'ask')) { $cfgErrors.Add("target must be online, onprem or ask (got '$target')"); $target = 'ask' }
$rep = Get-Prop $raw 'report' $null
$repEnabled = ([string](Get-Prop $rep 'enabled' 'ask')).ToLowerInvariant()
if ($repEnabled -notin @('true', 'false', 'ask')) { $cfgErrors.Add("report.enabled must be true, false or ask (got '$repEnabled')"); $repEnabled = 'ask' }
$repLocation = [string](Get-Prop $rep 'location' 'ask')
$ser = Get-Prop $raw 'serializer' $null
$serStrategy = ([string](Get-Prop $ser 'strategy' 'builtin')).ToLowerInvariant()
if ($serStrategy -notin @('builtin', 'existing')) { $cfgErrors.Add("serializer.strategy must be builtin or existing (got '$serStrategy')"); $serStrategy = 'builtin' }
$serClass = [string](Get-Prop $ser 'className' 'AppSerializer')
if ($serClass -notmatch '^[A-Za-z_]\w*$') { $cfgErrors.Add("serializer.className is not a valid C# name: '$serClass'"); $serClass = 'AppSerializer' }
$serFiles = @()
foreach ($sf in @(Get-Prop $ser 'files' @())) { if ($sf) { $serFiles += (Resolve-CfgPath $sf $cfgDir) } }
$serFile = Resolve-CfgPath ([string](Get-Prop $ser 'file' '')) $cfgDir
if ($serStrategy -eq 'existing') {
    if (-not $serFiles.Count) { $cfgErrors.Add('serializer.strategy is existing but serializer.files is empty') }
    if (-not (Get-Prop $ser 'serializeCall' $null) -or -not (Get-Prop $ser 'deserializeCall' $null)) { $cfgErrors.Add('serializer.strategy is existing but serializeCall / deserializeCall are missing') }
}
$suppressions = New-Object System.Collections.Generic.List[object]
foreach ($sp in @(Get-Prop $raw 'acceptedFindings' @())) {
    $f = [string](Get-Prop $sp 'file' ''); $r = [string](Get-Prop $sp 'reason' '')
    if (-not $f) { $cfgErrors.Add('acceptedFindings entry without "file"'); continue }
    if (-not $r) { $cfgWarnings.Add("acceptedFindings entry for '$f' has no reason - add one so reviewers know why") }
    $isPattern = $f -match '[\*\?]'
    $suppressions.Add([pscustomobject]@{
        File = $(if ($isPattern) { $f -replace '[\\/]', $sep } else { Resolve-CfgPath $f $cfgDir }); IsPattern = $isPattern
        Api = [string](Get-Prop $sp 'api' ''); Line = [int](Get-Prop $sp 'line' 0); Reason = $r
    })
}
$skipProjects = @(Get-Prop $raw 'skipProjects' @())
$httpTimeout = [int](Get-Prop (Get-Prop $raw 'http' $null) 'timeoutSeconds' 90)
if ($httpTimeout -lt 1 -or $httpTimeout -gt 110) { $cfgWarnings.Add("http.timeoutSeconds $httpTimeout is outside 1-110; plug-ins are stopped at 120 s - using 90"); $httpTimeout = 90 }
$knownKeys = @('$schema', 'version', 'target', 'report', 'serializer', 'sharedHelperFolder', 'sharedHelperNamespace', 'skipProjects', 'http', 'acceptedFindings', 'crm', 'notes')
$sharedHelperNs = [string](Get-Prop $raw 'sharedHelperNamespace' '')
$crmSet = Get-Prop $raw 'crm' $null
if ($crmSet) {
    $ce = [string](Get-Prop $crmSet 'environment' ''); $ca = [string](Get-Prop $crmSet 'auth' ''); $cu = [string](Get-Prop $crmSet 'url' '')
    if ($ce -and $ce -notin @('onprem', 'online')) { $cfgErrors.Add("crm.environment must be onprem or online, not '$ce'") }
    if ($ca -and $ca -notin @('windows', 'credential', 'interactive', 'azcli')) { $cfgErrors.Add("crm.auth must be windows, credential, interactive or azcli, not '$ca'") }
    if ($ce -eq 'online' -and $ca -in @('windows', 'credential')) { $cfgErrors.Add("crm.auth '$ca' does not work with Dataverse Online - use interactive or azcli") }
    if ($cu -and $cu -notmatch '^https?://[^/\s]+') { $cfgWarnings.Add("crm.url should start with https:// ('$cu')") }
    foreach ($pn in $crmSet.PSObject.Properties.Name) {
        if ($pn -match 'password|secret|token|key') { $cfgErrors.Add("crm.$pn must not be in the settings file - never store passwords, secrets or tokens") }
        elseif ($pn -notin @('environment', 'url', 'auth')) { $cfgWarnings.Add("Unknown setting 'crm.$pn' (ignored)") }
    }
}
if ($sharedHelperNs -and $sharedHelperNs -notmatch '^[A-Za-z_][\w]*(\.[A-Za-z_][\w]*)*$') { $cfgErrors.Add("sharedHelperNamespace is not a valid C# namespace: '$sharedHelperNs'"); $sharedHelperNs = '' }
if ($raw) { foreach ($pn in $raw.PSObject.Properties.Name) { if ($knownKeys -notcontains $pn) { $cfgWarnings.Add("Unknown setting '$pn' (ignored)") } } }
$sharedHelper = Resolve-CfgPath ([string](Get-Prop $raw 'sharedHelperFolder' '')) $cfgDir
if ($sharedHelper -and -not (Test-Path -LiteralPath $sharedHelper)) { $cfgWarnings.Add("sharedHelperFolder does not exist yet: $sharedHelper") }

function Test-Accepted($hitFile, $hitApi, $hitCategory, [int]$hitLine) {
    foreach ($sp in $suppressions) {
        $fileOk = if ($sp.IsPattern) { $hitFile -like ('*' + $sp.File.TrimStart('*')) -or $hitFile -like $sp.File } else { [string]::Equals($hitFile, $sp.File, [StringComparison]::OrdinalIgnoreCase) }
        if (-not $fileOk) { continue }
        if ($sp.Api -and -not ($hitApi -like $sp.Api -or $hitCategory -eq $sp.Api)) { continue }
        if ($sp.Line -and $sp.Line -ne $hitLine) { continue }
        return $(if ($sp.Reason) { $sp.Reason } else { 'accepted in sandbox-audit.json' })
    }
    return $null
}

function Get-Vcs([string]$start) {
    $d = $start
    while ($d) {
        if (Test-Path -LiteralPath (Join-Path $d '.git')) { return [pscustomobject]@{ Type = 'git'; Root = $d } }
        if ((Test-Path -LiteralPath (Join-Path $d '$tf')) -or (Test-Path -LiteralPath (Join-Path $d '$TF'))) { return [pscustomobject]@{ Type = 'tfvc'; Root = $d } }
        $parent = Split-Path -Parent $d
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    return [pscustomobject]@{ Type = 'none'; Root = $null }
}
$vcs = Get-Vcs $projDir

# ---------------------------------------------------------------- helpers
function Expand-MsBuildPath([string]$value, [string]$thisFileDir) {
    $v = [Uri]::UnescapeDataString($value.Trim())
    $v = $v -replace '\$\(MSBuildThisFileDirectory\)', ($thisFileDir.TrimEnd('\', '/') + $sep)
    $v = $v -replace '\$\(MSBuildProjectDirectory\)', $projDir
    if ($SolutionRoot) { $v = $v -replace '\$\(SolutionDir\)', ($SolutionRoot.TrimEnd('\', '/') + $sep) }
    return ($v -replace '[\\/]', $sep)
}

function Resolve-Items([string]$include, [string]$baseDir) {
    # Returns absolute paths for one Include value (handles ; lists and * / ** wildcards).
    $results = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($include -split ';')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        if ($p -match '\$\(') { $results.Add("UNRESOLVED:" + $p); continue }
        $full = if ([IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $baseDir $p }
        if ($full -notmatch '[\*\?]') { $results.Add([IO.Path]::GetFullPath($full)); continue }
        # wildcard: fixed prefix directory + glob -> regex
        $segments = $full -split [regex]::Escape([string]$sep)
        $fixed = New-Object System.Collections.Generic.List[string]
        foreach ($s in $segments) { if ($s -match '[\*\?]') { break }; $fixed.Add($s) }
        $root = ($fixed -join $sep); if (-not $root) { $root = $sep }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $rest = $full.Substring($root.Length).TrimStart('\', '/')
        # escape, normalise separators to a token FIRST, then translate wildcards
        $rx = [regex]::Escape($rest) -replace '\\\\|/', '__SEP__'
        $rx = $rx -replace '\\\*\\\*(__SEP__)?', '__DS__'          # **  /  **/
        $rx = $rx -replace '\\\*', '__STAR__' -replace '\\\?', '__ONE__'
        $rx = $rx -replace '__DS__', '(?:.*__SEP__)?' -replace '__STAR__', '[^\\/]*' -replace '__ONE__', '[^\\/]'
        $rx = '^' + ($rx -replace '__SEP__', '[\\/]') + '$'
        $opts = if ($isWin) { 'IgnoreCase' } else { 'None' }
        Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\', '/')
            if ($_.FullName -notmatch $excludeDirs -and [regex]::IsMatch($rel, $rx, $opts)) { $results.Add($_.FullName) }
        }
    }
    return $results
}

function Get-XmlNodes([xml]$doc, [string]$name) {
    return @($doc.SelectNodes("//*[local-name()='$name']"))
}

function Get-NonAssemblyReason([xml]$px, [string]$name) {
    # $null for plug-in / workflow / class-library projects; otherwise why the project runs in full trust outside CRM
    if (@($skipProjects | Where-Object { $name -like $_ }).Count) { return 'in skipProjects' }
    $sdkA = $px.DocumentElement.GetAttribute('Sdk')
    $guids = (@(Get-XmlNodes $px 'ProjectTypeGuids') | ForEach-Object { $_.InnerText }) -join ';'
    if ($sdkA -match '(?i)\.Web' -or $guids -match '(?i)349C5851-65DF-11DA-9384-00065B846F21|E3E379DF-F4C6-4180-9B81-6769533ABE47|E53F8FEA-EAE0-44A6-8774-FFD645390401') { return 'web project (API / Portal / site)' }
    $outT = (@(Get-XmlNodes $px 'OutputType') | Select-Object -First 1).InnerText
    if ($outT -match '(?i)exe') { return 'application (console / service / job)' }
    $refsTxt = (@(Get-XmlNodes $px 'Reference') + @(Get-XmlNodes $px 'PackageReference') | ForEach-Object { $_.GetAttribute('Include') }) -join ';'
    if ($name -match '(?i)(Tests?$|UnitTest)' -or $refsTxt -match '(?i)UnitTestFramework|MSTest\.TestFramework|\bxunit\b|\bnunit\b' -or (@(Get-XmlNodes $px 'IsTestProject') | Where-Object { $_.InnerText -eq 'true' }).Count) { return 'test project' }
    if ($name -match '(?i)(\bApi\b|\.Api$|Portal|\bWeb\b|\.Web$|Console)') { return 'name looks like API / Portal / web / console' }
    return $null
}

function Get-CompileFiles([string]$file, [bool]$isSdk) {
    # Returns list of @{ Path; Include; Link; Source } for one .csproj or .projitems
    [xml]$doc = Get-Content -LiteralPath $file -Raw
    $dir = Split-Path -Parent $file
    $isProjitems = $file -like '*.projitems'
    $map = New-Object 'System.Collections.Generic.Dictionary[string,object]' $cmp
    $removed = New-Object 'System.Collections.Generic.HashSet[string]' $cmp

    if ($isSdk) {
        $disableDefault = Get-XmlNodes $doc 'EnableDefaultCompileItems' | Where-Object { $_.InnerText -eq 'false' }
        if (-not $disableDefault) {
            foreach ($f in (Resolve-Items '**/*.cs' $dir)) {
                $map[$f] = @{ Path = $f; Include = $f.Substring($dir.Length).TrimStart('\', '/'); Link = $null; Source = 'local' }
            }
        }
    }
    foreach ($c in (Get-XmlNodes $doc 'Compile')) {
        $inc = $c.GetAttribute('Include'); $rem = $c.GetAttribute('Remove')
        if ($rem) { foreach ($f in (Resolve-Items (Expand-MsBuildPath $rem $dir) $dir)) { [void]$removed.Add($f) } }
        if (-not $inc) { continue }
        $link = $null
        foreach ($ch in $c.ChildNodes) { if ($ch.LocalName -eq 'Link') { $link = $ch.InnerText } }
        foreach ($f in (Resolve-Items (Expand-MsBuildPath $inc $dir) $dir)) {
            $src = if ($isProjitems) { 'shared' }
                   elseif ($link -or $inc -match '^\.\.|[\\/]\.\.[\\/]' -or -not $f.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { 'linked' }
                   else { 'local' }
            $map[$f] = @{ Path = $f; Include = $inc; Link = $link; Source = $src }
        }
    }
    foreach ($r in $removed) { [void]$map.Remove($r) }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($v in $map.Values) { $out.Add($v) }

    # shared projects
    foreach ($imp in (Get-XmlNodes $doc 'Import')) {
        $ip = $imp.GetAttribute('Project')
        if ($ip -notlike '*.projitems') { continue }
        $resolved = Resolve-Items (Expand-MsBuildPath $ip $dir) $dir
        foreach ($pi in $resolved) {
            if (Test-Path -LiteralPath $pi) { foreach ($x in (Get-CompileFiles $pi $false)) { $x.Source = 'shared'; $x.Projitems = $pi; $out.Add($x) } }
        }
    }
    return $out
}

# ---------------------------------------------------------------- class declarations / entry points
function Get-ClassDecls([string]$text, [string]$file) {
    # every "class X : bases" in a file, with the namespace it sits in (base list may continue on the next lines)
    $list = New-Object System.Collections.Generic.List[object]
    if (-not $text) { return , $list }
    $t = [regex]::Replace($text, '(?s)/\*.*?\*/', { param($m) $m.Value -replace '[^\r\n]', ' ' })
    $nsList = @([regex]::Matches($t, '(?m)^[ \t]*namespace\s+([\w\.]+)'))
    foreach ($m in [regex]::Matches($t, '(?m)^(?<pre>[^/\r\n]*?)\bclass\s+(?<n>\w+)(?:\s*<[^>{;]*>)?\s*:\s*(?<b>[^{;]+)\{')) {
        $baseText = ($m.Groups['b'].Value -split '\bwhere\b')[0]
        $bases = @($baseText -split ',' | ForEach-Object { (($_.Trim() -split '<')[0] -split '\.')[-1].Trim() } | Where-Object { $_ })
        if (-not $bases.Count) { continue }
        $ns = ''
        foreach ($n in $nsList) { if ($n.Index -lt $m.Groups['n'].Index) { $ns = $n.Groups[1].Value } else { break } }
        $name = $m.Groups['n'].Value
        $list.Add([pscustomobject]@{
            Name = $name; Namespace = $ns; FullName = $(if ($ns) { "$ns.$name" } else { $name }); Bases = $bases
            Abstract = [bool]($m.Groups['pre'].Value -match '\babstract\b'); File = $file
            Line = ($t.Substring(0, $m.Groups['n'].Index) -split "`n").Count
        })
    }
    return , $list
}
function Get-EntryTypes($decls) {
    # plug-in / workflow activity classes: derive from IPlugin / CodeActivity directly or through base classes in the source.
    # A base class that is not in the source (it comes from a referenced DLL) counts when its name looks like a plug-in / activity base - marked Assumed.
    $bySimple = @{}
    foreach ($d in $decls) { if (-not $bySimple.ContainsKey($d.Name)) { $bySimple[$d.Name] = New-Object System.Collections.Generic.List[object] }; $bySimple[$d.Name].Add($d) }
    $resolve = $null
    $resolve = {
        param($d, [int]$depth)
        if ($depth -gt 12) { return $null }
        if ($d.Bases -contains 'IPlugin') { return @{ Kind = 'Plugin'; Assumed = $null } }
        if ($d.Bases[0] -match '^(CodeActivity|AsyncCodeActivity|NativeActivity)$') { return @{ Kind = 'WorkflowActivity'; Assumed = $null } }
        foreach ($b in $d.Bases) {
            if ($bySimple.ContainsKey($b)) {
                $cands = @($bySimple[$b] | Sort-Object @{ Expression = { if ($_.Namespace -eq $d.Namespace) { 0 } else { 1 } } })
                foreach ($c in $cands) { if ($c.FullName -eq $d.FullName) { continue }; $k = & $resolve $c ($depth + 1); if ($k) { return $k } }
            }
            elseif ($b -match '(?i)^(plugin|\w*plugin\w*base\w*|base\w*plugin\w*)$') { return @{ Kind = 'Plugin'; Assumed = $b } }
            elseif ($b -match '(?i)^(\w*(workflow|codeactivity|activity)\w*base\w*|base\w*(workflow|codeactivity|activity)\w*)$') { return @{ Kind = 'WorkflowActivity'; Assumed = $b } }
        }
        return $null
    }
    $out = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($d in $decls) {
        if ($d.Abstract -or $seen.ContainsKey($d.FullName)) { continue }
        $k = & $resolve $d 0
        if ($k) { $seen[$d.FullName] = $true; $out.Add([pscustomobject]@{ FullName = $d.FullName; Name = $d.Name; Kind = $k.Kind; AssumedFromBase = $k.Assumed; File = $d.File; Line = $d.Line }) }
    }
    return , $out
}
function Get-CodeParts([string]$line) {
    # NoComment = the line without a trailing // comment (strings kept); Code = the same with string contents blanked
    $inStr = $false; $verb = $false; $cut = $line.Length
    for ($k = 0; $k -lt $line.Length; $k++) {
        $ch = $line[$k]
        if ($inStr) {
            if ($verb) { if ($ch -eq '"') { if ($k + 1 -lt $line.Length -and $line[$k + 1] -eq '"') { $k++ } else { $inStr = $false } } }
            elseif ($ch -eq '\') { $k++ }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true; $verb = ($k -gt 0 -and $line[$k - 1] -eq '@') -or ($k -gt 1 -and $line[$k - 1] -eq '$' -and $line[$k - 2] -eq '@'); continue }
        if ($ch -eq "'") { if ($k + 2 -lt $line.Length -and $line[$k + 1] -eq '\') { $k += 3 } else { $k += 2 }; continue }
        if ($ch -eq '/' -and $k + 1 -lt $line.Length -and $line[$k + 1] -eq '/') { $cut = $k; break }
    }
    $nc = $line.Substring(0, $cut)
    $code = $nc -replace '@"(?:[^"]|"")*"', '""' -replace '"(?:[^"\\]|\\.)*"', '""' -replace "'(?:[^'\\]|\\.)'", "''"
    return @{ NoComment = $nc; Code = $code }
}

# ---------------------------------------------------------------- patterns
# Severity: Blocked = fails in Sandbox if executed | Avoid = unsupported/unreliable in plug-ins
#           Review  = depends on usage | Harden = allowed, apply HTTP hardening | Using = namespace import only
$patterns = @(
    # File system
    @('FileSystem', 'Blocked', 'File.*',              '\bFile\.[A-Z]\w*\s*\('),
    @('FileSystem', 'Blocked', 'Directory.*',         '\bDirectory\.[A-Z]\w*\s*\('),
    @('FileSystem', 'Blocked', 'FileStream/FileInfo/DirectoryInfo/FileSystemWatcher', '\bnew\s+(FileStream|FileInfo|DirectoryInfo|FileSystemWatcher)\b'),
    @('FileSystem', 'Review',  'StreamReader/Writer on a path', '\bnew\s+Stream(Reader|Writer)\s*\(\s*(@?"|\w*(Path|File|FileName)\b)'),
    @('FileSystem', 'Blocked', 'IsolatedStorage',     '\bIsolatedStorage\w*'),
    # Database
    @('Database',   'Blocked', 'ADO.NET connection/command', '\bnew\s+(SqlConnection|SqlCommand|SqlDataAdapter|OleDb\w+|Odbc\w+)\b'),
    @('Database',   'Blocked', 'SqlDataReader',       '\bSqlDataReader\b'),
    @('Database',   'Blocked', 'Entity Framework',    '\b(DbContext|DbSet<)'),
    # Configuration
    @('Config',     'Blocked', 'ConfigurationManager', '\bConfigurationManager\.(AppSettings|ConnectionStrings|GetSection|OpenExeConfiguration)'),
    @('Config',     'Blocked', 'WebConfigurationManager', '\bWebConfigurationManager\b'),
    @('Config',     'Blocked', 'Environment.GetEnvironmentVariable', '\bEnvironment\.GetEnvironmentVariables?\b'),
    @('Config',     'Blocked', 'Settings.Default (app.config)', '\b(Properties\.)?Settings\.Default\b'),
    # Caching
    @('Caching',    'Blocked', 'MemoryCache / ObjectCache', '\b(MemoryCache|ObjectCache|CacheItemPolicy)\b'),
    # System.Web
    @('SystemWeb',  'Blocked', 'HttpContext.Current', '\bHttpContext\.Current\b'),
    @('SystemWeb',  'Blocked', 'HttpUtility',         '\bHttpUtility\.\w+'),
    @('SystemWeb',  'Blocked', 'MimeMapping',         '\bMimeMapping\.'),
    @('SystemWeb',  'Blocked', 'JavaScriptSerializer', '\bJavaScriptSerializer\b'),
    @('SystemWeb',  'Blocked', '[ScriptIgnore]',      '\[ScriptIgnore'),
    @('SystemWeb',  'Blocked', 'MapPath / HttpRuntime.Cache', '(\bServer\.MapPath|\bHttpServerUtility\b|\bHttpRuntime\.Cache)'),
    # Serialization
    @('Serialization', 'Blocked', 'JsonConvert',      '\bJsonConvert\.\w+'),
    @('Serialization', 'Blocked', 'JObject/JArray/JToken', '\b(JObject|JArray|JToken)\b'),
    @('Serialization', 'Blocked', 'Newtonsoft attribute', '\[Json(Property|Ignore|Converter|Constructor|Required)\b'),
    # Networking
    @('Network',    'Blocked', 'FTP/SMTP/Sockets/WebSockets', '\b(FtpWebRequest|SmtpClient|TcpClient|TcpListener|UdpClient|ClientWebSocket)\b'),
    @('Network',    'Blocked', 'Socket / Ping',       '\bnew\s+(Socket|Ping)\s*\('),
    @('Network',    'Blocked', 'localhost URL',       '(?i)https?://(localhost|127\.0\.0\.1)\b'),
    @('Network',    'Avoid',   'Non-80/443 port in URL', '(?i)https?://[^/"\s:]+:(?!80\b|443\b)\d+'),
    @('Network',    'Blocked', 'IP-address URL',      '(?i)https?://(\d{1,3}(\.\d{1,3}){3}|\[[0-9a-f:]+\])'),
    @('Auth',       'Blocked', 'Windows credentials', '(\bUseDefaultCredentials\s*=\s*true|\bCredentialCache\.Default(Network)?Credentials\b)'),
    @('Auth',       'Review',  'NetworkCredential',   '\bnew\s+(System\.Net\.)?NetworkCredential\s*\('),
    # HTTP hardening targets
    @('HTTP',       'Harden',  'HttpClient',          '\bnew\s+HttpClient\s*\('),
    @('HTTP',       'Harden',  'WebRequest',          '\b(Http)?WebRequest\.Create(Http)?\s*\('),
    @('HTTP',       'Harden',  'WebClient',           '\bnew\s+WebClient\s*\('),
    @('HTTP',       'Review',  '.Result / .Wait() on a task', '(\)\s*\.Result\b|\.Wait\(\s*\))'),
    # Threading
    @('Threading',  'Avoid',   'new Thread',          '\bnew\s+(System\.Threading\.)?Thread\s*\('),
    @('Threading',  'Avoid',   'ThreadPool',          '\bThreadPool\.QueueUserWorkItem'),
    @('Threading',  'Avoid',   'Task.Run / StartNew', '\b(Task\.Run|Task\.Factory\.StartNew)\s*\('),
    @('Threading',  'Avoid',   'Parallel.*',          '\bParallel\.(For|ForEach|Invoke)\b'),
    @('Threading',  'Avoid',   'Timer',               '\bnew\s+(System\.Timers\.|System\.Threading\.)?Timer\s*\('),
    # Process & OS
    @('ProcessOS',  'Blocked', 'Process.Start',       '\bProcess\.Start\s*\('),
    @('ProcessOS',  'Blocked', 'EventLog',            '\bEventLog\b'),
    @('ProcessOS',  'Blocked', 'Registry',            '\bRegistry(Key)?\.\w+'),
    @('ProcessOS',  'Blocked', 'Environment machine/user/exit', '\bEnvironment\.(MachineName|UserName|UserDomainName|Exit|GetFolderPath|CurrentDirectory)\b'),
    # Interop
    @('Interop',    'Blocked', 'DllImport / extern',  '(\[DllImport|\bstatic\s+extern\b)'),
    @('Interop',    'Blocked', 'Marshal / GCHandle',  '\b(Marshal\.\w+|GCHandle\.Alloc)'),
    @('Interop',    'Review',  'unsafe / fixed',      '(\bunsafe\b|\bfixed\s*\()'),
    @('Interop',    'Blocked', 'COM interop',         '\bGetTypeFromProgID\b'),
    # Reflection
    @('Reflection', 'Blocked', 'Assembly.Load*',      '\bAssembly\.(LoadFrom|LoadFile|Load)\s*\('),
    @('Reflection', 'Blocked', 'AppDomain',           '\bAppDomain\.(CreateDomain|CurrentDomain\.AssemblyResolve)'),
    @('Reflection', 'Blocked', 'Runtime compilation / Emit', '\b(CSharpCodeProvider|CompileAssemblyFromSource|DynamicMethod|TypeBuilder|AssemblyBuilder|ILGenerator)\b'),
    @('Reflection', 'Review',  'Non-public reflection', '\bBindingFlags\.NonPublic\b'),
    # Graphics
    @('Graphics',   'Blocked', 'System.Drawing',      '(\bnew\s+(Bitmap|Icon|Pen|SolidBrush)\s*\(|\b(Graphics|Image)\.From\w+|\bImageConverter\b)'),
    # Crypto
    @('Crypto',     'Blocked', 'CspParameters / X509Store / DPAPI', '\b(CspParameters|X509Store|ProtectedData\.)'),
    # XML
    @('XML',        'Review',  'XmlTextReader',       '\bnew\s+XmlTextReader\b'),
    @('XML',        'Review',  'DTD / XSLT script',   '(DtdProcessing\.Parse|enableScript\s*:\s*true|new\s+XsltSettings\s*\(\s*true)'),
    # Logging
    @('Logging',    'Blocked', 'log4net/NLog/Serilog', '(\b(log4net|NLog|Serilog)\b|\bLogManager\.GetLogger)'),
    # Misc assemblies
    @('Misc',       'Blocked', 'LDAP / DirectoryServices', '\b(DirectoryEntry|DirectorySearcher|PrincipalContext)\b'),
    @('Misc',       'Blocked', 'WCF non-HTTP binding', '\b(NetTcpBinding|NetNamedPipeBinding)\b'),
    # Third-party library features that use blocked APIs inside the library (see references/third-party-libraries.md)
    @('ThirdParty', 'Blocked', 'QRCoder image class (System.Drawing)', '(\b(Base64QRCode|ArtQRCode)\b|\bnew\s+(QRCoder\.)?QRCode\s*\()'),
    @('ThirdParty', 'Blocked', 'ZXing bitmap writer (System.Drawing)', '(\bnew\s+(ZXing\.)?BarcodeWriter\s*(\(|<\s*(System\.Drawing\.)?Bitmap\b)|\bBarcodeWriter<\s*(System\.Drawing\.)?Bitmap\b)'),
    @('ThirdParty', 'Review',  'Auto-fit columns (System.Drawing text measuring)', '\.(AutoFitColumns|AdjustToContents)\s*\('),
    @('ThirdParty', 'Blocked', 'Fonts loaded from disk', '\bFontFactory\.Register(Directories|Directory)?\s*\('),
    # Report rendering
    @('Reporting',  'Blocked', 'ReportViewer local report', '\b(LocalReport|ReportViewer)\b'),
    @('Reporting',  'Review',  'SSRS Report Server web service', '\b(ReportExecutionService|ReportExecution2005|ReportingService2010|ReportService2010)\b'),
    @('Misc',       'Blocked', 'Blocked namespace',   '\b(Microsoft\.VisualBasic|System\.Windows\.Forms|System\.Management|System\.ServiceProcess|System\.Printing|System\.Speech|System\.Drawing|System\.Windows\.Media)\b')
)
$compiled = foreach ($p in $patterns) {
    [pscustomobject]@{ Category = $p[0]; Severity = $p[1]; Api = $p[2]; Regex = New-Object regex($p[3], 'Compiled') }
}
$prefilter = New-Object regex((($patterns | ForEach-Object { '(?:' + $_[3] + ')' }) -join '|'), 'Compiled')
$methodRx = New-Object regex('^\s*(?:\[[^\]]*\]\s*)*(?:(?:public|private|protected|internal|static|override|virtual|abstract|sealed|async|new|extern|unsafe|partial)\s+)+[\w<>\[\],\.\?\s]+?\s+(\w+)\s*(?:<[^>]*>)?\s*\(', 'Compiled')
$typeRx = New-Object regex('\b(class|struct|interface)\s+(\w+)', 'Compiled')

# ---------------------------------------------------------------- online-readiness helpers
$httpCallRx = New-Object regex('(?:\.(?<m>PostAsync|GetAsync|PutAsync|DeleteAsync|PatchAsync|SendAsync|GetStringAsync|GetByteArrayAsync|GetStreamAsync|DownloadString|DownloadData|DownloadFile|UploadString|UploadData|UploadValues|OpenRead)|\b(?<m>WebRequest\.Create(?:Http)?))\s*\(', 'Compiled')
$baseAddrRx = New-Object regex('(?<o>\w+)\s*\.\s*BaseAddress\s*=\s*(?<rhs>[^;]+);', 'Compiled')
$svcCallRx = New-Object regex('\b\w*(?:[Ss]ervice|[Ss]vc|[Pp]roxy)\w*\s*\.\s*(?:RetrieveMultiple|Retrieve|Create|Update|Delete|Execute|Associate|Disassociate)\s*\(', 'Compiled')
$urlLiteralRx = New-Object regex('"(?<u>(?:https?|ftp|net\.tcp)://[^"\s]*)"', 'Compiled')
$classDeclRx = New-Object regex('\bclass\s+(?<n>\w+)(?:<[^>]*>)?\s*:\s*(?<b>[^{]+)', 'Compiled')
$nsHosts = '^(schemas\.microsoft\.com|www\.w3\.org|schemas\.xmlsoap\.org|tempuri\.org|purl\.org|json-schema\.org|schemas\.openxmlformats\.org|docs\.oasis-open\.org|ns\.adobe\.com)$'
$configRx = '(?i)(config\w*\s*[\.\[\(]|setting\w*\s*[\.\[\(]|environmentvariable|appsettings|\bGetValue\s*\(|keys?\.\w)'
$stepCfgRx = '(?i)\b_?(un)?secure\w*config\w*\b'
$idKeywords = @('new', 'string', 'String', 'var', 'null', 'true', 'false', 'this', 'base', 'typeof', 'nameof', 'HttpMethod', 'UriKind', 'Encoding', 'Uri', 'System', 'Convert', 'Environment', 'StringComparison', 'CultureInfo', 'await', 'Path')
$classRank = @{ 'Blocked' = 5; 'Internal' = 4; 'Avoid' = 3; 'Review' = 2; 'Unknown' = 1; 'LooksPublic' = 0 }

function Get-UrlClass([string]$url) {
    $m = [regex]::Match($url, '^(?<s>[A-Za-z\.]+)://(?<h>\[[^\]]*\]|[^/:?#]*)(?::(?<p>[^/?#]*))?')
    if (-not $m.Success) { return [pscustomobject]@{ Class = 'Unknown'; Detail = 'not a URL'; Host = $null } }
    $s = $m.Groups['s'].Value.ToLowerInvariant(); $h = $m.Groups['h'].Value; $port = $m.Groups['p'].Value
    $cls = 'LooksPublic'; $notes = New-Object System.Collections.Generic.List[string]
    $raise = { param($c, $n) if ($classRank[$c] -gt $classRank[$script:cls]) { $script:cls = $c }; $notes.Add($n) }
    $script:cls = $cls
    if (-not $h -or $h -match '[{}]') { & $raise 'Unknown' 'host is built at runtime' }
    elseif ($s -ne 'http' -and $s -ne 'https') { & $raise 'Blocked' "protocol $s (only http/https allowed)" }
    elseif ($h -match '^(?i)localhost$' -or $h -match '^127\.' -or $h -eq '[::1]') { & $raise 'Blocked' 'localhost' }
    elseif ($h -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $private = $h -match '^(10\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.)'
        & $raise 'Blocked' $(if ($private) { 'private IP address - use a public DNS name' } else { 'IP address - Microsoft requires a DNS name' })
    }
    elseif ($h.StartsWith('[')) { & $raise 'Blocked' 'IPv6 address - use a DNS name' }
    elseif ($h -notmatch '\.') { & $raise 'Internal' 'single-label host name (internal network)' }
    elseif ($h -match '(?i)\.(local|lan|corp|internal|intranet|ad|localdomain|home)$') { & $raise 'Internal' ('internal suffix .' + ($h -split '\.')[-1]) }
    if ($port -and $port -notmatch '^(80|443)$' -and $port -notmatch '[{}]') { & $raise 'Avoid' "port $port (prefer 443)" }
    if ($s -eq 'http' -and $script:cls -ne 'Blocked') { & $raise 'Review' 'plain HTTP - use HTTPS' }
    if ($script:cls -eq 'LooksPublic') { $notes.Add('looks public - confirm it resolves on the internet') }
    return [pscustomobject]@{ Class = $script:cls; Detail = ($notes -join '; '); Host = $h }
}

function Get-CallArgs([string]$text, [int]$start) {
    # top-level arguments of a call whose '(' is just before $start
    $list = New-Object System.Collections.Generic.List[string]
    $depth = 0; $inStr = $false; $sb = New-Object System.Text.StringBuilder
    for ($k = $start; $k -lt $text.Length; $k++) {
        $ch = $text[$k]
        if ($inStr) {
            [void]$sb.Append($ch)
            if ($ch -eq '\' -and $k + 1 -lt $text.Length) { $k++; [void]$sb.Append($text[$k]) }
            elseif ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '"') { $inStr = $true; [void]$sb.Append($ch); continue }
        if ('([{'.IndexOf($ch) -ge 0) { $depth++ }
        elseif (')]}'.IndexOf($ch) -ge 0) {
            if ($depth -eq 0) { $list.Add($sb.ToString().Trim()); return , $list }
            $depth--
        }
        elseif ($ch -eq ',' -and $depth -eq 0) { $list.Add($sb.ToString().Trim()); [void]$sb.Clear(); continue }
        [void]$sb.Append($ch)
    }
    $list.Add($sb.ToString().Trim())   # call continues on the next line
    return , $list
}

function Get-UnwrappedUrlExpr([string]$e) {
    for ($n = 0; $n -lt 5; $n++) {
        $e = $e.Trim()
        $e = $e -replace '^\((?:\w+\.)*\w+\)\s*', ''
        $e = $e -replace '\.(ToString|Trim|TrimEnd)\([^)]*\)\s*$', ''
        $m = [regex]::Match($e, '^new\s+(?:System\.)?Uri\s*\(')
        if ($m.Success) { $e = (Get-CallArgs $e $m.Length)[0]; continue }
        $m = [regex]::Match($e, '^new\s+(?:System\.Net\.Http\.)?HttpRequestMessage\s*\(')
        if ($m.Success) { $a = Get-CallArgs $e $m.Length; if ($a.Count -gt 1) { $e = $a[1] }; continue }
        $m = [regex]::Match($e, '^(?:System\.Net\.)?(?:Http)?WebRequest\.Create(?:Http)?\s*\(')
        if ($m.Success) { $e = (Get-CallArgs $e $m.Length)[0]; continue }
        break
    }
    return $e
}

function Get-Identifiers([string]$e) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($im in [regex]::Matches($e, '\$@?"(?:[^"\\]|\\.)*"')) {
        foreach ($b in [regex]::Matches($im.Value, '\{([^}:]+)')) { $parts.Add($b.Groups[1].Value) }
    }
    $parts.Add(($e -replace '@?"(?:[^"\\]|\\.)*"', ' ' -replace '\$', ' '))
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        foreach ($m in [regex]::Matches($p, '(?<![\w\.])(?:this\.)?([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)(?!\s*[\(\w])')) {
            $id = $m.Groups[1].Value
            if ($idKeywords -contains ($id -split '\.')[0]) { continue }
            if (-not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
    return , $ids
}

function Resolve-UrlSource([string]$expr, $lines, [int]$memberStart, [int]$lineIdx, [string]$fileText, [int]$hops) {
    # Best-effort trace of where a URL expression comes from. Claude confirms by reading the code.
    $e = Get-UnwrappedUrlExpr $expr
    $lit = [regex]::Match($e, '"(?<u>(?:https?|ftp|net\.tcp)://[^"]*)"')
    if ($lit.Success) { return @{ Source = 'Hardcoded'; Key = $null; Url = $lit.Groups['u'].Value; Expr = $e } }
    if ($e -match '^\$?@?"[^"{]*"$') { return @{ Source = 'Relative'; Key = $e; Url = $null; Expr = $e } }
    if ($e -match $stepCfgRx) { return @{ Source = 'StepConfig'; Key = $e; Url = $null; Expr = $e } }
    $wf = [regex]::Match($e, '\b(\w+)\s*\.\s*Get\s*(?:<[^>]*>)?\s*\(')
    if ($wf.Success -and $fileText -match ('\b(In|InOut)Argument<[^>]+>\s+' + [regex]::Escape($wf.Groups[1].Value) + '\b')) {
        return @{ Source = 'WorkflowInput'; Key = $wf.Groups[1].Value; Url = $null; Expr = $e }
    }
    if ($e -match $configRx) {
        $k = [regex]::Match($e, '"([^"]+)"')
        $key = if ($k.Success) { $k.Groups[1].Value } else { ([regex]::Match($e, '\b\w*Keys?\.\w+')).Value }
        if (-not $key) { $key = $e }
        return @{ Source = 'Configuration'; Key = $key; Url = $null; Expr = $e }
    }
    if ($hops -lt 4) {
        foreach ($id in (Get-Identifiers $e)) {
            $simple = ($id -split '\.')[-1]
            $esc = [regex]::Escape($simple)
            for ($k = $lineIdx - 1; $k -ge $memberStart -and $k -ge 0; $k--) {
                $am = [regex]::Match($lines[$k], '(?<![\w\.=!<>])' + $esc + '\s*=\s*(?![=>])(?<rhs>.+?);')
                if ($am.Success) { $r = Resolve-UrlSource $am.Groups['rhs'].Value $lines $memberStart $k $fileText ($hops + 1); if (-not $r.Via) { $r.Via = $simple }; return $r }
            }
            if ($memberStart -ge 0 -and $lines[$memberStart] -match ('[\(,]\s*(?:this\s+)?[\w<>\[\]\.\?]+\s+' + $esc + '\s*(?:=[^,)]*)?[,)]')) {
                return @{ Source = 'Parameter'; Key = $simple; Url = $null; Expr = $e }
            }
            if ($fileText -match ('\b(In|InOut)Argument<[^>]+>\s+' + $esc + '\b')) {
                return @{ Source = 'WorkflowInput'; Key = $simple; Url = $null; Expr = $e }
            }
            $fm = [regex]::Match($fileText, '(?<![\w\.=!<>])' + $esc + '\s*(?:=>|=(?![=>]))\s*(?<rhs>[^;{]+);')
            if ($fm.Success) { $r = Resolve-UrlSource $fm.Groups['rhs'].Value $lines -1 -1 $fileText ($hops + 1); if (-not $r.Via) { $r.Via = $simple }; return $r }
        }
    }
    return @{ Source = 'Unknown'; Key = $e; Url = $null; Expr = $e }
}

# ---------------------------------------------------------------- resolve files
$files = New-Object 'System.Collections.Generic.Dictionary[string,object]' $cmp
$unresolved = New-Object System.Collections.Generic.List[string]
$notCompiled = @()
if (-not $ListProjects) {
[xml]$projXml = Get-Content -LiteralPath $csproj -Raw
$isSdk = [bool]$projXml.DocumentElement.GetAttribute('Sdk')
$assemblyName = (Get-XmlNodes $projXml 'AssemblyName' | Select-Object -First 1).InnerText
if (-not $assemblyName) { $assemblyName = $projName }
$targetFw = (Get-XmlNodes $projXml 'TargetFrameworkVersion' | Select-Object -First 1).InnerText
if (-not $targetFw) { $targetFw = (Get-XmlNodes $projXml 'TargetFramework' | Select-Object -First 1).InnerText }

$all = Get-CompileFiles $csproj $isSdk
foreach ($f in $all) {
    if ($f.Path -like 'UNRESOLVED:*') { $unresolved.Add($f.Path.Substring(11)); continue }
    if ($f.Path -notlike '*.cs') { continue }
    if (-not $files.ContainsKey($f.Path)) { $files[$f.Path] = $f }
}

if (-not $isSdk) {
    $notCompiled = @(Get-ChildItem -LiteralPath $projDir -Recurse -Filter *.cs -File |
        Where-Object { $_.FullName -notmatch $excludeDirs -and -not $files.ContainsKey($_.FullName) } |
        ForEach-Object { $_.FullName.Substring($projDir.Length).TrimStart('\', '/') })
}

# ---- referenced projects (<ProjectReference>): their code runs inside this plug-in too, in Sandbox, but in another DLL.
# Followed recursively (a referenced project's own references run as well). Files get Source = 'referenced'.
$referencedProjects = New-Object System.Collections.Generic.List[object]
$refQueue = New-Object System.Collections.Generic.Queue[object]
$visitedRefs = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
[void]$visitedRefs.Add([IO.Path]::GetFullPath($csproj))
function Get-ProjRefPaths([xml]$doc, [string]$baseDir) {
    $out = @()
    foreach ($pr in (Get-XmlNodes $doc 'ProjectReference')) {
        $inc = $pr.GetAttribute('Include'); if (-not $inc) { continue }
        $inc = Expand-MsBuildPath $inc $baseDir
        $full = if ([IO.Path]::IsPathRooted($inc)) { $inc } else { Join-Path $baseDir $inc }
        $out += [IO.Path]::GetFullPath(($full -replace '[\\/]', $sep))
    }
    return $out
}
foreach ($rp in (Get-ProjRefPaths $projXml $projDir)) { $refQueue.Enqueue(@{ Path = $rp; Via = $projName; Depth = 1 }) }
$savedProjDir = $projDir
while ($refQueue.Count) {
    $r = $refQueue.Dequeue()
    if (-not $visitedRefs.Add($r.Path)) { continue }
    $rName = [IO.Path]::GetFileNameWithoutExtension($r.Path)
    if (-not (Test-Path -LiteralPath $r.Path)) {
        $referencedProjects.Add([pscustomobject]@{ Name = $rName; Path = $r.Path; Exists = $false; AssemblyName = $null; Via = $r.Via; Depth = $r.Depth; Files = 0; ReferencedBy = @() })
        continue
    }
    try {
        [xml]$rx = Get-Content -LiteralPath $r.Path -Raw
        $rSdk = [bool]$rx.DocumentElement.GetAttribute('Sdk')
        $script:projDir = Split-Path -Parent $r.Path
        $rFiles = @(Get-CompileFiles $r.Path $rSdk)
        $rAsm = (Get-XmlNodes $rx 'AssemblyName' | Select-Object -First 1).InnerText; if (-not $rAsm) { $rAsm = $rName }
        $n = 0
        foreach ($x in $rFiles) {
            if ($x.Path -like 'UNRESOLVED:*' -or $x.Path -notlike '*.cs') { continue }
            if ($x.Include -match '(?i)(^|[\\/])(Properties[\\/])?AssemblyInfo\.cs$') { continue }
            if ($files.ContainsKey($x.Path)) { continue }      # already compiled into this DLL (linked) - stays as it is
            $x.Source = 'referenced'; $x.ReferencedProject = $rName
            $files[$x.Path] = $x; $n++
        }
        $referencedProjects.Add([pscustomobject]@{ Name = $rName; Path = $r.Path; Exists = $true; AssemblyName = $rAsm; Via = $r.Via; Depth = $r.Depth; Files = $n; ReferencedBy = @() })
        if ($r.Depth -lt 6) { foreach ($rp in (Get-ProjRefPaths $rx (Split-Path -Parent $r.Path))) { $refQueue.Enqueue(@{ Path = $rp; Via = $rName; Depth = $r.Depth + 1 }) } }
    } catch {
        $referencedProjects.Add([pscustomobject]@{ Name = $rName; Path = $r.Path; Exists = $true; AssemblyName = $null; Via = $r.Via; Depth = $r.Depth; Files = 0; ReferencedBy = @(); Error = $_.Exception.Message })
    } finally { $script:projDir = $savedProjDir }
}
}

# ---------------------------------------------------------------- solution-wide info (optional)
$linkCount = New-Object 'System.Collections.Generic.Dictionary[string,object]' $cmp
$appSerializers = @()
$existingHelpers = New-Object System.Collections.Generic.List[object]
$helperNames = @('MimeTypeHelper', 'QueryStringHelper', 'EnvironmentVariableHelper')
$helperApi = @{ MimeTypeHelper = '\bstatic\s+string\s+GetMimeType\s*\('; QueryStringHelper = '\bstatic\s+[\w<>,\.\s]+?\s+ParseQueryString\s*\('; EnvironmentVariableHelper = '\bstatic\s+string\s+Get\s*\(' }
function New-HelperInfo([string]$path, [string]$name) {
    $content = [IO.File]::ReadAllText($path) -replace '(?s)/\*.*?\*/', '' -replace '(?m)//.*$', ''
    $decl = [regex]::Match($content, '\bclass\s+' + $name + '\b\s*(?::\s*(?<b>[^{]+))?')
    $blocked = New-Object System.Collections.Generic.List[string]
    foreach ($ln in ($content -split "`n")) {
        if ($ln.Trim() -match '^using\s' -or -not $prefilter.IsMatch($ln)) { continue }
        foreach ($pt in $compiled) { if (($pt.Severity -eq 'Blocked' -or $pt.Severity -eq 'Avoid') -and $pt.Regex.IsMatch($ln)) { $blocked.Add($pt.Api) } }
    }
    return [pscustomobject]@{
        Name = $name; Path = $path
        Namespace = [regex]::Match($content, '\bnamespace\s+([\w\.]+)').Groups[1].Value
        Visibility = $(if ($content -match ('\bpublic\s+(sealed\s+|static\s+)*class\s+' + $name + '\b')) { 'public' } else { 'internal' })
        IsStatic = [bool]($content -match ('\bstatic\s+class\s+' + $name + '\b'))
        HasExpectedApi = [bool]($content -match $helperApi[$name])
        ReturnsDictionary = [bool]($name -eq 'QueryStringHelper' -and $content -match 'Dictionary\s*<\s*string\s*,\s*string\s*>\s+ParseQueryString')
        Implements = $(if ($decl.Groups['b'].Success) { $decl.Groups['b'].Value.Trim() } else { $null })
        ExternalUsings = @([regex]::Matches($content, '(?m)^\s*using\s+(?!System\b)(?!Microsoft\.Xrm\.Sdk\b)(?!Microsoft\.Crm\.Sdk\b)(?!static\s+System\b)([\w\.]+)\s*;') | ForEach-Object { $_.Groups[1].Value })
        BlockedApis = @($blocked | Sort-Object -Unique)
        OwnedBy = @(); LinkedBy = @(); CompiledIntoThisProject = $false; Reusable = $false; Reasons = @()
    }
}
$solutionProjects = 0
$nonAssembly = @{}     # project name -> why it is not a plug-in / workflow assembly (API, Portal, exe, tests, skipProjects)
if (-not $SolutionRoot) {
    # no solution root: only helpers already compiled into this project can be found
    foreach ($fp in $files.Keys) {
        if (-not (Test-Path -LiteralPath $fp)) { continue }
        $txt = [IO.File]::ReadAllText($fp)
        foreach ($hn in $helperNames) { if ($txt -match ('\bclass\s+' + $hn + '\b')) { $existingHelpers.Add((New-HelperInfo $fp $hn)) } }
    }
}
if ($SolutionRoot) {
    $projFiles = @(Get-ChildItem -LiteralPath $SolutionRoot -Recurse -Filter *.csproj -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludeDirs })
    $solutionProjects = $projFiles.Count
    $allCs = @(Get-ChildItem -LiteralPath $SolutionRoot -Recurse -Filter *.cs -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludeDirs })
    foreach ($m in @($allCs | Select-String -Pattern ('\bclass\s+(' + ($helperNames -join '|') + ')\b') -AllMatches)) {
        foreach ($mm in $m.Matches) {
            $hn = $mm.Groups[1].Value
            if (-not ($existingHelpers | Where-Object { $_.Path -eq $m.Path -and $_.Name -eq $hn })) { $existingHelpers.Add((New-HelperInfo $m.Path $hn)) }
        }
    }
    $appSerializers = @($allCs |
        Select-String -Pattern ('\bclass\s+' + $serClass + '\b') -List |
        ForEach-Object {
            $content = [IO.File]::ReadAllText($_.Path)
            $content = $content -replace '(?s)/\*.*?\*/', '' -replace '(?m)//.*$', ''   # ignore comments
            $ns = [regex]::Match($content, '\bnamespace\s+([\w\.]+)').Groups[1].Value
            $decl = [regex]::Match($content, '\bclass\s+' + $serClass + '\b\s*(?::\s*(?<b>[^{]+))?')
            $extUsings = @([regex]::Matches($content, '(?m)^\s*using\s+(?!System\b)(?!static\s+System\b)([\w\.]+)\s*;') | ForEach-Object { $_.Groups[1].Value })
            [pscustomobject]@{
                Path = $_.Path
                Namespace = $ns
                Visibility = if ($content -match ('\bpublic\s+(sealed\s+|static\s+)?class\s+' + $serClass + '\b')) { 'public' } else { 'internal' }
                IsStatic = [bool]($content -match ('\bstatic\s+class\s+' + $serClass + '\b'))
                HasGenericApi = [bool](($content -match '\bstatic\s+string\s+Serialize\s*<') -and ($content -match '\bstatic\s+T\s+Deserialize\s*<'))
                HasDateStyle = [bool]($content -match '\bJsonDateStyle\b')
                UsesBlockedSerializer = [bool]($content -match '\b(JavaScriptSerializer|JsonConvert|Newtonsoft)\b')
                Implements = $(if ($decl.Groups['b'].Success) { $decl.Groups['b'].Value.Trim() } else { $null })
                ExternalUsings = $extUsings
                OldDateFormat = [bool]($content -match 'fffZ')
                OwnedBy = @()
                LinkedBy = @()
                CompiledIntoThisProject = $false
                Reusable = $false
                Upgrade = $false
                Reasons = @()
            }
        })
    $appSet = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
    foreach ($a in $appSerializers) { [void]$appSet.Add($a.Path) }
    foreach ($h in $existingHelpers) { [void]$appSet.Add($h.Path) }
    $appOwners = New-Object 'System.Collections.Generic.Dictionary[string,object]' $cmp
    $refBy = New-Object 'System.Collections.Generic.Dictionary[string,object]' $cmp
    foreach ($pf in $projFiles) {
        try {
            [xml]$px = Get-Content -LiteralPath $pf.FullName -Raw
            $sdk = [bool]$px.DocumentElement.GetAttribute('Sdk')
            $why = Get-NonAssemblyReason $px $pf.BaseName
            if ($why -and -not $nonAssembly.ContainsKey($pf.BaseName)) { $nonAssembly[$pf.BaseName] = $why }
            if ($referencedProjects.Count) {
                foreach ($rp in (Get-ProjRefPaths $px $pf.DirectoryName)) {
                    if (-not $refBy.ContainsKey($rp)) { $refBy[$rp] = New-Object System.Collections.Generic.List[string] }
                    if (-not $refBy[$rp].Contains($pf.BaseName)) { $refBy[$rp].Add($pf.BaseName) }
                }
            }
            foreach ($cf in (Get-CompileFiles $pf.FullName $sdk)) {
                if (-not $files.ContainsKey($cf.Path) -and -not $appSet.Contains($cf.Path)) { continue }
                if (-not $linkCount.ContainsKey($cf.Path)) { $linkCount[$cf.Path] = New-Object System.Collections.Generic.List[string] }
                if (-not $linkCount[$cf.Path].Contains($pf.BaseName)) { $linkCount[$cf.Path].Add($pf.BaseName) }
                if ($appSet.Contains($cf.Path) -and $cf.Source -eq 'local') {
                    if (-not $appOwners.ContainsKey($cf.Path)) { $appOwners[$cf.Path] = New-Object System.Collections.Generic.List[string] }
                    $appOwners[$cf.Path].Add($pf.BaseName)
                }
            }
        } catch { Write-Warning "Could not parse $($pf.FullName): $($_.Exception.Message)" }
    }
}

# referenced projects: which projects in the solution reference each one (the projects an edit there affects)
# direct and indirect: a project that references Bll also runs Common when Bll references Common
if ($refBy -and $referencedProjects.Count) {
    $pathByName = @{}
    foreach ($pf in $projFiles) { if (-not $pathByName.ContainsKey($pf.BaseName)) { $pathByName[$pf.BaseName] = $pf.FullName } }
    foreach ($rpj in $referencedProjects) {
        $users = New-Object System.Collections.Generic.List[string]
        $todo = New-Object System.Collections.Generic.Queue[string]; $todo.Enqueue($rpj.Path)
        $seenP = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
        while ($todo.Count) {
            $cur = $todo.Dequeue(); if (-not $seenP.Add($cur)) { continue }
            if (-not $refBy.ContainsKey($cur)) { continue }
            foreach ($u in $refBy[$cur]) { if (-not $users.Contains($u)) { $users.Add($u) }; if ($pathByName.ContainsKey($u)) { $todo.Enqueue($pathByName[$u]) } }
        }
        $rpj.ReferencedBy = $users.ToArray()
    }
}
foreach ($rpj in $referencedProjects) {
    $rpj | Add-Member -NotePropertyName UsedByNonAssembly -NotePropertyValue @(@($rpj.ReferencedBy) | Where-Object { $nonAssembly.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ Project = $_; Reason = $nonAssembly[$_] } }) -Force
}
foreach ($a in $appSerializers) {
    if ($linkCount.ContainsKey($a.Path)) { $a.LinkedBy = $linkCount[$a.Path].ToArray() }
    if ($appOwners.ContainsKey($a.Path)) { $a.OwnedBy = $appOwners[$a.Path].ToArray() }
    $a.CompiledIntoThisProject = ($files.ContainsKey($a.Path) -and $files[$a.Path].Source -ne 'referenced')
    # Reusable = can be linked as one self-contained source file with the static AppSerializer API
    $blockers = New-Object System.Collections.Generic.List[string]
    if ($a.UsesBlockedSerializer) { $blockers.Add('uses JavaScriptSerializer / Newtonsoft (blocked in Sandbox)') }
    if (-not $a.IsStatic -or -not $a.HasGenericApi) { $blockers.Add('instance / interface style API (e.g. AppSerializer.Instance.Serialize), not the static Serialize<T> / Deserialize<T> helper') }
    if ($a.Implements) { $blockers.Add("implements $($a.Implements) - cannot be linked as a single file") }
    if (@($a.ExternalUsings).Count) { $blockers.Add("depends on $((@($a.ExternalUsings)) -join ', ') - cannot be linked as a single file") }
    $notes = New-Object System.Collections.Generic.List[string]
    if (@($a.OwnedBy).Count) { $notes.Add("part of project $((@($a.OwnedBy)) -join ', ') (its own DLL) - plug-ins must link the file, never reference that DLL") }
    if ($a.OldDateFormat) { $notes.Add('old date format ...fffZ - replace with the current AppSerializer version') }
    elseif (-not $a.HasDateStyle -and $blockers.Count -eq 0) { $notes.Add('no JsonDateStyle option - replace with the current AppSerializer version (same API, adds the option)') }
    $a.Reusable = ($blockers.Count -eq 0)
    $a.Upgrade = ($blockers.Count -eq 0) -and ($a.OldDateFormat -or -not $a.HasDateStyle)
    $a.Reasons = @($blockers) + @($notes)
}

foreach ($h in $existingHelpers) {
    if ($linkCount.ContainsKey($h.Path)) { $h.LinkedBy = $linkCount[$h.Path].ToArray() }
    if ($SolutionRoot -and $appOwners.ContainsKey($h.Path)) { $h.OwnedBy = $appOwners[$h.Path].ToArray() }
    $h.CompiledIntoThisProject = ($files.ContainsKey($h.Path) -and $files[$h.Path].Source -ne 'referenced')
    $blockers = New-Object System.Collections.Generic.List[string]
    if (@($h.BlockedApis).Count) { $blockers.Add("uses $((@($h.BlockedApis)) -join ', ') (not Sandbox-safe)") }
    if (-not $h.IsStatic) { $blockers.Add('not a static class') }
    if (-not $h.HasExpectedApi) { $blockers.Add('different API than the shared helper (see shared-helpers.md)') }
    if ($h.ReturnsDictionary) { $blockers.Add('returns Dictionary<string,string> - not a drop-in replacement for HttpUtility.ParseQueryString (a missing key throws instead of returning null)') }
    if ($h.Implements) { $blockers.Add("implements / inherits $($h.Implements) - cannot be linked as a single file") }
    if (@($h.ExternalUsings).Count) { $blockers.Add("depends on $((@($h.ExternalUsings)) -join ', ') - cannot be linked as a single file") }
    $notes = New-Object System.Collections.Generic.List[string]
    if (@($h.OwnedBy).Count) { $notes.Add("part of project $((@($h.OwnedBy)) -join ', ') (its own DLL) - plug-ins must link the file, never reference that DLL") }
    $h.Reusable = ($blockers.Count -eq 0)
    $h.Reasons = @($blockers) + @($notes)
}

# ---------------------------------------------------------------- -ListProjects (setup mode)
if ($ListProjects) {
    $rootFull = $SolutionRoot.TrimEnd('\', '/')
    function Get-RelToRoot([string]$p) { if ($p.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($rootFull.Length).TrimStart('\', '/') } else { $p } }
    $declCache = @{}
    $rows = New-Object System.Collections.Generic.List[object]
    $folderUse = @{}
    foreach ($pf in $projFiles) {
        try {
            [xml]$px = Get-Content -LiteralPath $pf.FullName -Raw
            $sdkAttr = $px.DocumentElement.GetAttribute('Sdk')
            $script:projDir = $pf.DirectoryName
            $cfs = @(Get-CompileFiles $pf.FullName ([bool]$sdkAttr) | Where-Object { $_.Path -like '*.cs' -and $_.Path -notlike 'UNRESOLVED:*' })
            $classes = New-Object System.Collections.Generic.List[object]
            foreach ($cf in $cfs) {
                if (-not $declCache.ContainsKey($cf.Path)) {
                    $list = New-Object System.Collections.Generic.List[object]; $ver = $null
                    if (Test-Path -LiteralPath $cf.Path) {
                        $txt = [IO.File]::ReadAllText($cf.Path)
                        $list = Get-ClassDecls $txt $cf.Path
                        $vm = [regex]::Match($txt, '(?m)^\s*\[\s*assembly\s*:\s*AssemblyVersion(?:Attribute)?\s*\(\s*"([^"]+)"')
                        if ($vm.Success) { $ver = $vm.Groups[1].Value }
                    }
                    $declCache[$cf.Path] = [pscustomobject]@{ Classes = $list; Version = $ver }
                }
                foreach ($dcl in $declCache[$cf.Path].Classes) { $classes.Add($dcl) }
            }
            $entries = Get-EntryTypes $classes
            $np = @($entries | Where-Object { $_.Kind -eq 'Plugin' }).Count; $nw = @($entries | Where-Object { $_.Kind -eq 'WorkflowActivity' }).Count
            $entryTypes = @($entries | ForEach-Object { $_.FullName })
            $assumed = @($entries | Where-Object { $_.AssumedFromBase } | ForEach-Object { "$($_.FullName) (base class $($_.AssumedFromBase) is not in the source)" })
            $asmName = (Get-XmlNodes $px 'AssemblyName' | Select-Object -First 1).InnerText
            if (-not $asmName) { $asmName = $pf.BaseName }
            $asmVer = $null
            foreach ($cf in $cfs) { if ($declCache[$cf.Path].Version) { $asmVer = $declCache[$cf.Path].Version; break } }
            if (-not $asmVer) { $vn = Get-XmlNodes $px 'AssemblyVersion' | Select-Object -First 1; if (-not $vn) { $vn = Get-XmlNodes $px 'Version' | Select-Object -First 1 }; if ($vn) { $asmVer = $vn.InnerText.Trim() } }
            $fw = (Get-XmlNodes $px 'TargetFrameworkVersion' | Select-Object -First 1).InnerText
            if (-not $fw) { $fw = (Get-XmlNodes $px 'TargetFramework' | Select-Object -First 1).InnerText }
            if (-not $fw) { $fw = (Get-XmlNodes $px 'TargetFrameworks' | Select-Object -First 1).InnerText }
            $outType = (Get-XmlNodes $px 'OutputType' | Select-Object -First 1).InnerText
            $linkedDirs = @($cfs | Where-Object { $_.Source -ne 'local' } | ForEach-Object { Get-RelToRoot (Split-Path -Parent $_.Path) } | Sort-Object -Unique)
            $kind = if ($np -and $nw) { 'Plugins+WorkflowActivities' } elseif ($np) { 'Plugins' } elseif ($nw) { 'WorkflowActivities' } else { 'Other' }
            if ($kind -ne 'Other') { foreach ($ld in $linkedDirs) { if ($folderUse.ContainsKey($ld)) { $folderUse[$ld]++ } else { $folderUse[$ld] = 1 } } }
            $hint = $null
            if ($sdkAttr -match 'Web' -or $pf.BaseName -match '(?i)(\bApi\b|\.Api$|Portal|\bWeb\b|\.Web$|Tests?$|UnitTest|Console)' -or $outType -match '(?i)exe') { $hint = 'likely full trust (API / Portal / web / test / console) - suggest skipProjects' }
            $skipped = [bool]($skipProjects | Where-Object { $pf.BaseName -like $_ })
            $rows.Add([pscustomobject]@{
                Name = $pf.BaseName; Path = (Get-RelToRoot $pf.FullName); FullPath = $pf.FullName; Style = $(if ($sdkAttr) { 'sdk' } else { 'legacy' })
                AssemblyName = $asmName; AssemblyVersion = $asmVer; EntryTypes = @($entryTypes | Sort-Object); AssumedEntryTypes = $assumed
                TargetFramework = $fw; Kind = $kind; Plugins = $np; WorkflowActivities = $nw
                CompiledFiles = $cfs.Count; LinkedFiles = @($cfs | Where-Object { $_.Source -ne 'local' }).Count
                LinkedFromFolders = $linkedDirs; Hint = $hint; Skipped = $skipped
            })
        } catch { Write-Warning "Could not read $($pf.FullName): $($_.Exception.Message)" }
    }
    $topFolders = @($folderUse.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8 | ForEach-Object { [pscustomobject]@{ Folder = $_.Key; UsedByPluginProjects = $_.Value } })
    $out = [pscustomobject]@{
        SolutionRoot = $SolutionRoot; Settings = [pscustomobject]@{ Path = $cfgPath; Errors = $cfgErrors.ToArray(); Warnings = $cfgWarnings.ToArray() }
        VersionControl = (Get-Vcs $SolutionRoot); SerializerClassName = $serClass
        Projects = $rows.ToArray(); SharedFolderCandidates = $topFolders; ExistingSerializers = @($appSerializers); ExistingHelpers = $existingHelpers.ToArray()
        Counts = [pscustomobject]@{ Projects = $rows.Count; PluginOrWorkflow = @($rows | Where-Object { $_.Kind -ne 'Other' }).Count; LikelyFullTrust = @($rows | Where-Object { $_.Hint }).Count; Skipped = @($rows | Where-Object { $_.Skipped }).Count }
        ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
    $od = Split-Path -Parent $OutFile; if ($od -and -not (Test-Path -LiteralPath $od)) { New-Item -ItemType Directory -Path $od | Out-Null }
    $out | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    Write-Output ("Projects under {0}: {1} ({2} with plug-ins / workflow activities, {3} likely full trust, {4} skipped by settings)" -f $SolutionRoot, $out.Counts.Projects, $out.Counts.PluginOrWorkflow, $out.Counts.LikelyFullTrust, $out.Counts.Skipped)
    Write-Output ("Version control: {0}" -f $out.VersionControl.Type)
    foreach ($r in ($rows | Sort-Object Kind, Name)) {
        Write-Output ("  [{0}] {1}  ({2}, {3}; {4} plug-ins, {5} workflow activities; {6} files, {7} linked){8}{9}" -f $r.Kind, $r.Path, $r.Style, $r.TargetFramework, $r.Plugins, $r.WorkflowActivities, $r.CompiledFiles, $r.LinkedFiles, $(if ($r.Hint) { ' - ' + $r.Hint } else { '' }), $(if ($r.Skipped) { ' [SKIPPED]' } else { '' }))
    }
    Write-Output 'Shared folders most linked by plug-in / workflow projects:'
    foreach ($t in $topFolders) { Write-Output ("  {0} ({1} projects)" -f $t.Folder, $t.UsedByPluginProjects) }
    Write-Output ("Existing {0} classes: {1}" -f $serClass, @($appSerializers).Count)
    foreach ($a in $appSerializers) { Write-Output ("  {0} - {1}" -f (Get-RelToRoot $a.Path), $(if ($a.Reusable) { 'reusable' } else { 'not reusable: ' + (@($a.Reasons) -join '; ') })) }
    Write-Output ("Existing shared helpers: {0}" -f $existingHelpers.Count)
    foreach ($h in $existingHelpers) { Write-Output ("  {0} {1} - {2}" -f $h.Name, (Get-RelToRoot $h.Path), $(if ($h.Reusable) { 'reusable' } else { 'not reusable: ' + (@($h.Reasons) -join '; ') })) }
    Write-Output "JSON: $OutFile  ($($out.ElapsedSeconds)s)"
    return
}

# ---------------------------------------------------------------- scan
$hits = New-Object System.Collections.Generic.List[object]
$fileRows = New-Object System.Collections.Generic.List[object]
$httpCalls = New-Object System.Collections.Generic.List[object]
$urlLiterals = New-Object System.Collections.Generic.List[object]
$loopRisks = New-Object System.Collections.Generic.List[object]
$allDecls = New-Object System.Collections.Generic.List[object]
$asmVersion = $null; $asmKeyAttr = $null
foreach ($f in $files.Values) {
    $exists = Test-Path -LiteralPath $f.Path
    $count = 0; $types = @()
    if ($exists) {
        $lines = [IO.File]::ReadAllLines($f.Path)
        $fileText = [string]::Join("`n", $lines)
        foreach ($dcl in (Get-ClassDecls $fileText $f.Path)) { $allDecls.Add($dcl) }
        $inBlock = $false; $ppStack = New-Object System.Collections.Generic.List[string]
        $member = $null; $memberStart = -1; $memberBase = @{}
        $typeNames = New-Object System.Collections.Generic.List[string]
        $depth = 0; $loops = New-Object System.Collections.Generic.List[object]
        $pendingIgnore = $null
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $line = $lines[$i]; $t = $line.Trim()
            # block comments (line-level approximation)
            if ($inBlock) { if ($t.Contains('*/')) { $inBlock = $false }; continue }
            if ($t.StartsWith('/*')) { if (-not $t.Contains('*/')) { $inBlock = $true }; continue }
            if ($t.StartsWith('//')) {
                $ig = [regex]::Match($t, '^//+\s*sandbox-ignore\b[:\s-]*(?<r>.*)$')
                if ($ig.Success) { $pendingIgnore = $(if ($ig.Groups['r'].Value.Trim()) { $ig.Groups['r'].Value.Trim() } else { 'sandbox-ignore comment' }) }
                continue
            }
            # accepted for this line: "// sandbox-ignore: reason" on the same line or the line above
            $lineIgnore = $pendingIgnore; $pendingIgnore = $null
            $igSame = [regex]::Match($line, '//+\s*sandbox-ignore\b[:\s-]*(?<r>.*)$')
            if ($igSame.Success) { $lineIgnore = $(if ($igSame.Groups['r'].Value.Trim()) { $igSame.Groups['r'].Value.Trim() } else { 'sandbox-ignore comment' }) }
            # preprocessor tracking for #if DEBUG
            if ($t -match '^#if\s+(.*)') { $ppStack.Add($(if ($matches[1] -match '^\s*DEBUG\b') { 'debug' } else { 'other' })); continue }
            if ($t -match '^#else' -and $ppStack.Count) { if ($ppStack[$ppStack.Count - 1] -eq 'debug') { $ppStack[$ppStack.Count - 1] = 'notdebug' }; continue }
            if ($t -match '^#endif' -and $ppStack.Count) { $ppStack.RemoveAt($ppStack.Count - 1); continue }
            $tm = $typeRx.Match($line); if ($tm.Success -and -not $t.StartsWith('using')) { if (-not $typeNames.Contains($tm.Groups[2].Value)) { $typeNames.Add($tm.Groups[2].Value) } }
            if ($t -notmatch '^(if|for|foreach|while|switch|catch|using|return|throw|else|lock)\b') {
                $mm = $methodRx.Match($line); if ($mm.Success -and -not $t.EndsWith(';')) { $member = $mm.Groups[1].Value; $memberStart = $i; $memberBase = @{} }
            }

            # ---- online readiness: structure, loops, URLs, HTTP calls
            $parts = Get-CodeParts $line
            $code = $parts.Code; $noComment = $parts.NoComment
            $ct = $code.Trim()
            $inLoop = $false; $loopLine = $null
            foreach ($lp in $loops) { if ($lp.Entered -or ($i -gt $lp.Line -and $ct)) { $inLoop = $true; $loopLine = $lp.Line + 1 } }
            $av = [regex]::Match($line, '^\s*\[\s*assembly\s*:\s*AssemblyVersion(?:Attribute)?\s*\(\s*"([^"]+)"')
            if ($av.Success -and -not $ppStack.Contains('debug')) { $asmVersion = [pscustomobject]@{ Value = $av.Groups[1].Value; File = $f.Path; Line = $i + 1 } }
            $ak = [regex]::Match($line, '^\s*\[\s*assembly\s*:\s*AssemblyKeyFile(?:Attribute)?\s*\(\s*@?"([^"]*)"')
            if ($ak.Success -and $ak.Groups[1].Value) { $asmKeyAttr = $ak.Groups[1].Value }
            if (-not $ppStack.Contains('debug')) {
                foreach ($um in $urlLiteralRx.Matches($line)) {
                    $u = $um.Groups['u'].Value; $uc = Get-UrlClass $u
                    if ($uc.Host -and $uc.Host -match $nsHosts) { continue }
                    $acc = if ($lineIgnore) { $lineIgnore } else { Test-Accepted $f.Path 'URL' 'Network' ($i + 1) }
                    $urlLiterals.Add([pscustomobject]@{ File = $f.Path; Source = $f.Source; Line = $i + 1; Member = $member; Url = $u; Class = $uc.Class; Detail = $uc.Detail; Accepted = $acc })
                }
                $ba = $baseAddrRx.Match($line)
                if ($ba.Success) { $memberBase[$ba.Groups['o'].Value] = Resolve-UrlSource $ba.Groups['rhs'].Value $lines $memberStart $i $fileText 0 }
                $callsHere = @($httpCallRx.Matches($line))
                foreach ($hm in $callsHere) {
                    $argList = Get-CallArgs $line ($hm.Index + $hm.Length)
                    $argExpr = if ($argList.Count) { $argList[0] } else { '' }
                    $res = Resolve-UrlSource $argExpr $lines $memberStart $i $fileText 0
                    $recv = [regex]::Match($line.Substring(0, $hm.Index), '(\w+)\s*$').Groups[1].Value
                    if (($res.Source -eq 'Relative' -or -not $argExpr) -and $recv -and $memberBase.ContainsKey($recv)) { $res = $memberBase[$recv].Clone(); $res.Via = "$recv.BaseAddress" }
                    $uc = if ($res.Url) { Get-UrlClass $res.Url } else { $null }
                    $httpCalls.Add([pscustomobject]@{
                        File = $f.Path; Source = $f.Source; Line = $i + 1; Member = $member
                        Call = $hm.Groups['m'].Value; UrlExpr = $argExpr
                        UrlSource = $res.Source; UrlKey = $res.Key; Via = $res.Via; Url = $res.Url
                        UrlClass = $(if ($uc) { $uc.Class } else { $null }); UrlDetail = $(if ($uc) { $uc.Detail } else { $null })
                        InLoop = $inLoop; LoopLine = $loopLine
                        Accepted = $(if ($lineIgnore) { $lineIgnore } else { Test-Accepted $f.Path 'HTTP call' 'HTTP' ($i + 1) })
                    })
                }
                if ($inLoop) {
                    $sv = $svcCallRx.Match($code)
                    if ($sv.Success -or $callsHere.Count) {
                        $what = if ($callsHere.Count) { 'HTTP ' + $callsHere[0].Groups['m'].Value } else { 'Service ' + ($sv.Value -replace '\s', '' -replace '\($', '') }
                        $loopRisks.Add([pscustomobject]@{ File = $f.Path; Source = $f.Source; Line = $i + 1; Member = $member; LoopLine = $loopLine; Call = $what })
                    }
                }
            }
            # brace depth + loop stack
            $opens = ([regex]::Matches($code, '\{')).Count; $closes = ([regex]::Matches($code, '\}')).Count
            $depthBefore = $depth; $depth += $opens - $closes
            $done = New-Object System.Collections.Generic.List[object]
            foreach ($lp in $loops) {
                if ($lp.Entered) { if ($depth -le $lp.Depth) { $done.Add($lp) } }
                elseif ($depth -gt $lp.Depth) { $lp.Entered = $true }
                elseif ($i -gt $lp.Line -and $ct) { $done.Add($lp) }
            }
            foreach ($d in $done) { [void]$loops.Remove($d) }
            $wholeLoopOnLine = ($opens -gt 0 -and $depth -le $depthBefore) -or $ct.EndsWith(';')
            if ($ct -match '^(foreach|for|while|do)\b' -and -not $wholeLoopOnLine) {
                $loops.Add([pscustomobject]@{ Line = $i; Depth = $depthBefore; Entered = ($depth -gt $depthBefore) })
            }

            if (-not $prefilter.IsMatch($noComment)) { continue }
            $isUsing = $t -match '^using\s+[\w\.]+\s*;'
            foreach ($p in $compiled) {
                # URL / attribute-argument patterns need the string contents; everything else is matched with strings blanked
                $subject = if ($p.Category -eq 'Network' -or $p.Api -match 'DllImport|COM interop') { $noComment } else { $code }
                if (-not $p.Regex.IsMatch($subject)) { continue }
                $count++
                $acc = if ($lineIgnore) { $lineIgnore } else { Test-Accepted $f.Path $p.Api $p.Category ($i + 1) }
                $hits.Add([pscustomobject]@{
                    File     = $f.Path
                    Source   = $f.Source
                    ReferencedProject = $f.ReferencedProject
                    Line     = $i + 1
                    Category = $p.Category
                    Severity = $(if ($isUsing) { 'Using' } else { $p.Severity })
                    Api      = $p.Api
                    Member   = $(if ($isUsing) { $null } else { $member })
                    InDebug  = $ppStack.Contains('debug')
                    Text     = $(if ($t.Length -gt 200) { $t.Substring(0, 200) + '...' } else { $t })
                    Accepted = $acc
                })
            }
        }
        $types = $typeNames.ToArray()
    }
    $sharedBy = $null
    if ($f.Source -eq 'referenced') {
        # projects that reference the owning project, plus projects that link this file directly
        $own = $referencedProjects | Where-Object { $_.Name -eq $f.ReferencedProject } | Select-Object -First 1
        $u = New-Object System.Collections.Generic.List[string]
        if ($own) { foreach ($x in @($own.ReferencedBy)) { if ($x -and -not $u.Contains($x)) { $u.Add($x) } } }
        if ($linkCount.ContainsKey($f.Path)) { foreach ($x in $linkCount[$f.Path]) { if ($x -ne $f.ReferencedProject -and -not $u.Contains($x)) { $u.Add($x) } } }
        if ($u.Count) { $sharedBy = $u.ToArray() }
    }
    elseif ($linkCount.ContainsKey($f.Path)) { $sharedBy = $linkCount[$f.Path].ToArray() }
    $outsideUsers = @()
    if ($f.Source -ne 'local' -and $sharedBy) { $outsideUsers = @(@($sharedBy) | Where-Object { $nonAssembly.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ Project = $_; Reason = $nonAssembly[$_] } }) }
    $fileRows.Add([pscustomobject]@{
        SharedByNonAssembly = $outsideUsers
        Path = $f.Path; Source = $f.Source; Include = $f.Include; Link = $f.Link; ReferencedProject = $f.ReferencedProject
        Exists = $exists; Hits = $count; Types = $types
        SharedByProjects = $(if ($sharedBy) { $sharedBy.Count } else { $null })
        SharedBy = $sharedBy
    })
}

# ---------------------------------------------------------------- references
$refs = @(Get-XmlNodes $projXml 'Reference' | ForEach-Object { ($_.GetAttribute('Include') -split ',')[0] })
$pkgRefs = @(Get-XmlNodes $projXml 'PackageReference' | ForEach-Object { $_.GetAttribute('Include') + ' ' + $_.GetAttribute('Version') })
$projRefs = @(Get-XmlNodes $projXml 'ProjectReference' | ForEach-Object { $_.GetAttribute('Include') })
$pkgConfig = Join-Path $projDir 'packages.config'
$packages = @()
if (Test-Path -LiteralPath $pkgConfig) {
    [xml]$pc = Get-Content -LiteralPath $pkgConfig -Raw
    $packages = @(Get-XmlNodes $pc 'package' | ForEach-Object { $_.GetAttribute('id') + ' ' + $_.GetAttribute('version') })
}

# ---------------------------------------------------------------- online readiness: project checks
function Get-FwInfo([string]$fw) {
    $v = "$fw"
    if ($v -match '^v(\d+(\.\d+)*)$') { $v = $matches[1] }
    elseif ($v -match '^net(\d)(\d)(\d)?$') { $v = $matches[1] + '.' + $matches[2] + $(if ($matches[3]) { '.' + $matches[3] } else { '' }) }
    $status = 'Blocked'; $note = 'Plug-ins must target .NET Framework 4.6.2 (or 4.8 where supported)'
    if ($v -eq '4.6.2') { $status = 'Ready'; $note = 'Supported' }
    elseif ($v -eq '4.8') { $status = 'Check'; $note = '4.8 works only on environments with service update 9.2.26092 or later (MC1515315) - check Settings > About, or retarget to 4.6.2' }
    elseif ($v -match '^4\.8\.\d') { $status = 'Blocked'; $note = '4.8.1 and later are not supported - retarget to 4.6.2 (or 4.8 where supported)' }
    elseif ($v -match '^4\.7') { $status = 'Check'; $note = '4.7.x is not named as supported - retarget to 4.6.2 (or 4.8 where supported)' }
    elseif ($v -match '^4\.[0-6]') { $status = 'Check'; $note = 'Below 4.6.2 - retarget to 4.6.2 (current CRM SDK packages need it)' }
    return [pscustomobject]@{ Value = $fw; Version = $v; Status = $status; Note = $note }
}
$fwInfo = Get-FwInfo $targetFw

$signNode = Get-XmlNodes $projXml 'SignAssembly' | Select-Object -First 1
$keyNode = Get-XmlNodes $projXml 'AssemblyOriginatorKeyFile' | Select-Object -First 1
$keyFile = if ($keyNode) { Expand-MsBuildPath $keyNode.InnerText $projDir } elseif ($asmKeyAttr) { Expand-MsBuildPath $asmKeyAttr $projDir } else { $null }
$keyFull = $null
if ($keyFile) { $keyFull = if ([IO.Path]::IsPathRooted($keyFile)) { $keyFile } else { [IO.Path]::GetFullPath((Join-Path $projDir $keyFile)) } }
$signOn = ($signNode -and $signNode.InnerText.Trim() -eq 'true') -or [bool]$asmKeyAttr
$keyExists = [bool]($keyFull -and (Test-Path -LiteralPath $keyFull))
$signing = [pscustomobject]@{
    SignAssembly = $signOn; KeyFile = $keyFile; KeyFileExists = $keyExists
    Status = $(if ($signOn -and $keyExists) { 'Ready' } else { 'Check' })
    Note = $(if ($signOn -and $keyExists) { 'Strong-name signed' } elseif ($signOn) { 'Signing is on but the key file was not found' } else { 'Not signed - required unless the assembly is deployed in a plug-in package (plug-ins only)' })
}

if (-not $asmVersion) {
    $vn = Get-XmlNodes $projXml 'AssemblyVersion' | Select-Object -First 1
    if (-not $vn) { $vn = Get-XmlNodes $projXml 'Version' | Select-Object -First 1 }
    if ($vn) { $asmVersion = [pscustomobject]@{ Value = $vn.InnerText.Trim(); File = $csproj; Line = $null } }
}
$versionInfo = [pscustomobject]@{
    Value = $(if ($asmVersion) { $asmVersion.Value } else { $null })
    File  = $(if ($asmVersion) { $asmVersion.File } else { $null })
    Line  = $(if ($asmVersion) { $asmVersion.Line } else { $null })
    Note  = $(if (-not $asmVersion) { 'No AssemblyVersion found - defaults to 0.0.0.0' } elseif ($asmVersion.Value -match '\*') { 'Wildcard version - build/revision change on every build (fine); keep major.minor fixed' } else { 'Keep major.minor equal to the registered assembly; change only build/revision' })
}

# entry points: classes deriving (directly or through base classes) from IPlugin / CodeActivity
$ownFileSet = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
foreach ($f in $files.Values) { if ($f.Source -ne 'referenced') { [void]$ownFileSet.Add($f.Path) } }
$entries = New-Object System.Collections.Generic.List[object]
foreach ($en in (Get-EntryTypes $allDecls)) { if ($ownFileSet.Contains([string]$en.File)) { $entries.Add($en) } }
$plugins = New-Object System.Collections.Generic.List[string]; $workflows = New-Object System.Collections.Generic.List[string]
foreach ($en in $entries) { if ($en.Kind -eq 'Plugin') { $plugins.Add($en.FullName) } else { $workflows.Add($en.FullName) } }
$assumedEntries = @($entries | Where-Object { $_.AssumedFromBase } | ForEach-Object { [pscustomobject]@{ Class = $_.FullName; Kind = $_.Kind; Base = $_.AssumedFromBase; Note = 'base class is not in the source (referenced DLL) - confirm it is a plug-in / workflow activity base' } })

# dependency candidates (confirm against the compiled DLL after the build)
$fwRefRx = '^(mscorlib|netstandard|System(\..+)?|Microsoft\.CSharp|Microsoft\.Xrm\.Sdk(\..+)?|Microsoft\.Crm\.Sdk\.Proxy|Microsoft\.IdentityModel|WindowsBase|PresentationCore|PresentationFramework(\..+)?|ReachFramework|UIAutomation\w*|Microsoft\.VisualBasic)$'
$fwPkgRx = '^(Microsoft\.CrmSdk\..+|Microsoft\.IdentityModel|System\..+|Microsoft\.NETFramework\.ReferenceAssemblies.*|Microsoft\.PowerApps\.MSBuild\..+)$'
# build-time tools - not runtime dependencies (merge tools are reported separately below)
$toolPkgRx = '^(ILMerge|ILMerge\.Tools|MSBuild\.ILMerge\.Task|ILMerge\.MSBuild\.Task|ILRepack|ILRepack\.Lib\.MSBuild\.Task|ILRepack\.MSBuild\.Task|Costura\.Fody|Fody|Microsoft\.Net\.Compilers.*|Microsoft\.CodeDom\.Providers\..+|StyleCop\..+|.+\.Analyzers)$'
$deps = New-Object System.Collections.Generic.List[object]
foreach ($r in (Get-XmlNodes $projXml 'Reference')) {
    $nm = ($r.GetAttribute('Include') -split ',')[0].Trim()
    if ($nm -match $fwRefRx) { continue }
    $hp = $null; foreach ($ch in $r.ChildNodes) { if ($ch.LocalName -eq 'HintPath') { $hp = $ch.InnerText } }
    $deps.Add([pscustomobject]@{ Name = $nm; Kind = 'Reference'; Detail = $hp })
}
foreach ($pr in (Get-XmlNodes $projXml 'PackageReference')) {
    $nm = $pr.GetAttribute('Include'); if ($nm -match $fwPkgRx -or $nm -match $toolPkgRx) { continue }
    $deps.Add([pscustomobject]@{ Name = $nm; Kind = 'PackageReference'; Detail = $pr.GetAttribute('Version') })
}
foreach ($pk in $packages) {
    $nm = ($pk -split ' ')[0]; if ($nm -match $fwPkgRx -or $nm -match $toolPkgRx -or ($deps | Where-Object { $_.Name -eq $nm })) { continue }
    $deps.Add([pscustomobject]@{ Name = $nm; Kind = 'packages.config'; Detail = ($pk -split ' ')[1] })
}
foreach ($pj in $projRefs) { $deps.Add([pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension(($pj -replace '[\\/]', $sep)); Kind = 'ProjectReference'; Detail = $pj }) }
foreach ($rpj in ($referencedProjects | Where-Object { $_.Depth -gt 1 })) {
    if (-not ($deps | Where-Object { $_.Name -eq $rpj.Name })) { $deps.Add([pscustomobject]@{ Name = $rpj.Name; Kind = 'ProjectReference (indirect)'; Detail = "through $($rpj.Via)" }) }
}

# ---- merge tools (ILMerge / ILRepack / Costura): the merged libraries are runtime dependencies even though the built DLL hides them
$mergeEvidence = New-Object System.Collections.Generic.List[string]
$mergeTool = $null
$allPkgIds = @(@($packages | ForEach-Object { ($_ -split ' ')[0] }) + @(Get-XmlNodes $projXml 'PackageReference' | ForEach-Object { $_.GetAttribute('Include') }))
foreach ($id in $allPkgIds) {
    if ($id -match '^(ILMerge|MSBuild\.ILMerge\.Task|ILMerge\.MSBuild\.Task|ILMerge\.Tools)$') { $mergeTool = 'ILMerge'; $mergeEvidence.Add("package $id") }
    elseif ($id -match '^ILRepack') { $mergeTool = 'ILRepack'; $mergeEvidence.Add("package $id") }
    elseif ($id -eq 'Costura.Fody') { $mergeTool = 'Costura'; $mergeEvidence.Add("package $id") }
}
foreach ($imp in (Get-XmlNodes $projXml 'Import')) {
    $ip = $imp.GetAttribute('Project')
    if ($ip -match '(?i)ILMerge') { if (-not $mergeTool) { $mergeTool = 'ILMerge' }; $mergeEvidence.Add("import $ip") }
    elseif ($ip -match '(?i)ILRepack') { if (-not $mergeTool) { $mergeTool = 'ILRepack' }; $mergeEvidence.Add("import $ip") }
    elseif ($ip -match '(?i)Costura|Fody') { if (-not $mergeTool) { $mergeTool = 'Costura' }; $mergeEvidence.Add("import $ip") }
}
foreach ($evName in @('PostBuildEvent', 'PreBuildEvent')) {
    foreach ($ev in (Get-XmlNodes $projXml $evName)) {
        if ($ev.InnerText -match '(?i)\bilmerge') { if (-not $mergeTool) { $mergeTool = 'ILMerge' }; $mergeEvidence.Add("$evName runs ILMerge") }
        elseif ($ev.InnerText -match '(?i)\bilrepack') { if (-not $mergeTool) { $mergeTool = 'ILRepack' }; $mergeEvidence.Add("$evName runs ILRepack") }
    }
}
foreach ($ex in (Get-XmlNodes $projXml 'Exec')) {
    $cmd = $ex.GetAttribute('Command')
    if ($cmd -match '(?i)\bilmerge') { if (-not $mergeTool) { $mergeTool = 'ILMerge' }; $mergeEvidence.Add('build target runs ILMerge') }
    elseif ($cmd -match '(?i)\bilrepack') { if (-not $mergeTool) { $mergeTool = 'ILRepack' }; $mergeEvidence.Add('build target runs ILRepack') }
}
foreach ($mf in @('ILMergeConfig.json', 'ILMerge.props', 'ILMergeOrder.txt', 'ILRepack.targets', 'FodyWeavers.xml')) {
    if (Test-Path -LiteralPath (Join-Path $projDir $mf)) {
        $t = if ($mf -like 'ILRepack*') { 'ILRepack' } elseif ($mf -like 'Fody*') { 'Costura' } else { 'ILMerge' }
        if ($mf -ne 'FodyWeavers.xml' -or ((Get-Content -LiteralPath (Join-Path $projDir $mf) -Raw) -match '(?i)Costura')) {
            if (-not $mergeTool) { $mergeTool = $t }; $mergeEvidence.Add("file $mf")
        }
    }
}
$merge = $null
if ($mergeTool) {
    $mergedLibs = New-Object System.Collections.Generic.List[string]; $mergedFrom = $null
    $cfgJson = Join-Path $projDir 'ILMergeConfig.json'
    if (Test-Path -LiteralPath $cfgJson) {
        try {
            $mc = Get-Content -LiteralPath $cfgJson -Raw | ConvertFrom-Json
            $inputs = @(); if ($mc.General -and $mc.General.InputAssemblies) { $inputs = @($mc.General.InputAssemblies) } elseif ($mc.InputAssemblies) { $inputs = @($mc.InputAssemblies) }
            foreach ($i in $inputs) { $mergedLibs.Add(([IO.Path]::GetFileName([string]$i)) -replace '(?i)\.dll$', '') }
            if ($mergedLibs.Count) { $mergedFrom = 'ILMergeConfig.json (InputAssemblies)' }
        } catch { }
    }
    $fody = Join-Path $projDir 'FodyWeavers.xml'
    if (-not $mergedLibs.Count -and $mergeTool -eq 'Costura' -and (Test-Path -LiteralPath $fody)) {
        $fm = [regex]::Match((Get-Content -LiteralPath $fody -Raw), '(?i)IncludeAssemblies\s*=\s*"([^"]+)"')
        if ($fm.Success) { foreach ($i in ($fm.Groups[1].Value -split '[|\r\n]')) { if ($i.Trim()) { $mergedLibs.Add($i.Trim()) } }; $mergedFrom = 'FodyWeavers.xml (IncludeAssemblies)' }
    }
    if (-not $mergedLibs.Count) {
        foreach ($d in $deps) { $mergedLibs.Add($d.Name) }
        $mergedFrom = 'all referenced libraries (the tool merges copy-local references by default)'
    }
    $merge = [pscustomobject]@{
        Tool = $mergeTool; Evidence = @($mergeEvidence | Select-Object -Unique); MergedLibraries = @($mergedLibs | Select-Object -Unique); MergedFrom = $mergedFrom
        Note = "The built DLL contains these libraries, so it shows no runtime dependencies - treat them as real dependencies. $mergeTool is not supported by Microsoft for plug-ins: on-premises Sandbox it is the usual workaround; for Dataverse Online use a plug-in package (plug-ins only) or replace / include the library code. Merging does not make a library Sandbox-safe."
    }
}

# ---- known third-party libraries (status inside Sandbox) - references/third-party-libraries.md has the details
$knownLibs = @(
    @{ Rx = '^QRCoder$'; Name = 'QRCoder'; Status = 'Review'; Why = 'The QR encoder is plain C#, but the image classes QRCode, Base64QRCode and ArtQRCode draw with System.Drawing (blocked).'; Fix = 'Use PngByteQRCode (or SvgQRCode): Convert.ToBase64String(new PngByteQRCode(data).GetGraphic(20)) gives the same base64 PNG without System.Drawing.' },
    @{ Rx = '^System\.Drawing(\.Common)?$'; Name = 'System.Drawing'; Status = 'Review'; Why = 'Referenced by the project. Any code that uses it (GDI+ graphics) fails in Sandbox - the Graphics / ThirdParty hits show where; a library may also use it internally.'; Fix = 'Remove the reference if nothing needs it; replace the code or library feature that uses it.' },
    @{ Rx = '^(PresentationCore|PresentationFramework|WindowsBase|System\.Windows\.Forms)$'; Name = 'WPF / Windows Forms'; Status = 'OK'; Why = 'Framework user-interface assemblies, usually a leftover reference (the workflow project template adds them). Not a dependency; only code that uses them is a problem, and the scanner reports that code as Blocked hits.'; Fix = 'Optional: remove the unused reference.' },
    @{ Rx = '^Syncfusion\.(DocToPDFConverter|DocToPdfConverter|XlsIORenderer|PresentationRenderer|HtmlToPdfConverter|Pdf\.Imaging)'; Name = 'Syncfusion conversion (Word / Excel / HTML to PDF)'; Status = 'Review'; Why = 'Converting documents to PDF draws the pages with System.Drawing (GDI+) in the .NET Framework builds - likely to fail in Sandbox. Large DLLs (16 MB limit when merged).'; Fix = 'Test the exact conversion in a Sandbox plug-in, or confirm with Syncfusion; otherwise move the conversion outside the plug-in (Azure Function, Power Automate).' },
    @{ Rx = '^Syncfusion\.'; Name = 'Syncfusion'; Status = 'Review'; Why = 'Large commercial library; some features use System.Drawing or the file system.'; Fix = 'Test the features you use in Sandbox; load the licence key from CRM data, never from a file.' },
    @{ Rx = '^(iTextSharp|itextsharp|itext7|itext\..+)$'; Name = 'iTextSharp / iText'; Status = 'Review'; Why = 'Writing PDFs is managed code, but fonts from disk (FontFactory.Register*) and System.Drawing.Image overloads are blocked. AGPL licence.'; Fix = 'Load fonts from embedded resources / byte arrays; pass images as byte arrays.' },
    @{ Rx = '^(PDFsharp|PDFsharp-gdi|PDFsharp-wpf|PDFsharp-MigraDoc|PDFsharp-MigraDoc-gdi|PDFsharp-MigraDoc-wpf|MigraDoc)$'; Name = 'PDFsharp / MigraDoc'; Status = 'Review'; Why = 'The GDI and WPF builds draw with System.Drawing / WPF (blocked).'; Fix = 'Use the Core build of PDFsharp / MigraDoc (no GDI+), with fonts from embedded resources.' },
    @{ Rx = '^EPPlus'; Name = 'EPPlus'; Status = 'Review'; Why = 'Reading and writing cells works; AutoFitColumns, pictures and charts use System.Drawing. EPPlus 5+ needs a commercial licence.'; Fix = 'Avoid AutoFitColumns / pictures (set column widths), or generate the file outside the plug-in.' },
    @{ Rx = '^ClosedXML$'; Name = 'ClosedXML'; Status = 'Review'; Why = 'AdjustToContents and images use System.Drawing; depends on DocumentFormat.OpenXml.'; Fix = 'Avoid AdjustToContents / images, or generate the file outside the plug-in.' },
    @{ Rx = '^DocumentFormat\.OpenXml'; Name = 'Open XML SDK'; Status = 'Review'; Why = 'Managed code, but System.IO.Packaging can switch to isolated storage for large parts (about 10 MB), which Sandbox blocks.'; Fix = 'Keep documents small, or test with the largest real document.' },
    @{ Rx = '^ZXing\.Net'; Name = 'ZXing.Net'; Status = 'Review'; Why = 'BarcodeWriter (Bitmap) draws with System.Drawing.'; Fix = 'Use BarcodeWriterSvg or BarcodeWriterPixelData and encode the bytes yourself.' },
    @{ Rx = '^Aspose\.'; Name = 'Aspose'; Status = 'Review'; Why = 'Rendering uses System.Drawing in the .NET Framework builds; a licence loaded from a file is blocked.'; Fix = 'Load the licence from a stream / embedded resource; test the rendering in Sandbox.' },
    @{ Rx = '^(Microsoft\.ReportViewer\..+|Microsoft\.ReportingServices\.ReportViewerControl\..+)$'; Name = 'ReportViewer (local reports)'; Status = 'Blocked'; Why = 'Local report rendering needs full trust and GDI+.'; Fix = 'Render outside the plug-in - see "Report rendering".' },
    @{ Rx = '^(log4net|NLog|Serilog.*)$'; Name = 'Logging library'; Status = 'Blocked'; Why = 'Writes to files / event log.'; Fix = 'Use ITracingService.' },
    @{ Rx = '^(Dapper|EntityFramework)$'; Name = 'SQL access'; Status = 'Blocked'; Why = 'Direct database access is blocked.'; Fix = 'Use IOrganizationService.' },
    @{ Rx = '^Newtonsoft\.Json$'; Name = 'Newtonsoft.Json'; Status = 'Handled'; Why = 'Replaced by the serializer migration.'; Fix = 'See references/serializer-rules.md.' },
    @{ Rx = '^(RestSharp|HtmlAgilityPack|CsvHelper|Polly)$'; Name = $null; Status = 'OK'; Why = 'Plain managed code - allowed in Sandbox (HTTP calls get the usual hardening).'; Fix = 'Only packaging matters: plug-in package (plug-ins), or replace with built-in .NET code.' },
    @{ Rx = '^(WindowsAzure\.Storage|Azure\.Storage\..+|Azure\.Messaging\..+|Microsoft\.Azure\.ServiceBus|Azure\.Core)$'; Name = 'Azure SDK'; Status = 'Review'; Why = 'HTTP-based, but a large dependency tree.'; Fix = 'For Service Bus / Event Hub prefer a registered service endpoint (IServiceEndpointNotificationService); otherwise a plug-in package.' }
)
$libNames = New-Object System.Collections.Generic.List[object]
foreach ($r in (Get-XmlNodes $projXml 'Reference')) {
    $libNames.Add([pscustomobject]@{ Name = ($r.GetAttribute('Include') -split ',')[0].Trim(); From = 'Reference' })
    foreach ($ch in $r.ChildNodes) { if ($ch.LocalName -eq 'HintPath') { $libNames.Add([pscustomobject]@{ Name = ([IO.Path]::GetFileNameWithoutExtension(($ch.InnerText -replace '[\\/]', $sep))); From = 'Reference' }) } }
}
foreach ($id in $allPkgIds) { $libNames.Add([pscustomobject]@{ Name = $id; From = 'package' }) }
if ($merge) { foreach ($m in $merge.MergedLibraries) { $libNames.Add([pscustomobject]@{ Name = $m; From = 'merged' }) } }
$thirdParty = New-Object System.Collections.Generic.List[object]
$seenLib = @{}
foreach ($ln in $libNames) {
    foreach ($kl in $knownLibs) {
        if ($ln.Name -match $kl.Rx) {
            $label = if ($kl.Name) { $kl.Name } else { $ln.Name }
            if ($seenLib.ContainsKey($label)) { if ($seenLib[$label].Matched -notcontains $ln.Name) { $seenLib[$label].Matched += $ln.Name } }
            else {
                $o = [pscustomobject]@{ Library = $label; Matched = @($ln.Name); Status = $kl.Status; Why = $kl.Why; Fix = $kl.Fix; Merged = $false }
                $seenLib[$label] = $o; $thirdParty.Add($o)
            }
            if ($ln.From -eq 'merged') { $seenLib[$label].Merged = $true }
            break
        }
    }
}

# ---- report rendering (SSRS web service / ReportViewer): no Online equivalent for a plug-in
$reportRendering = New-Object System.Collections.Generic.List[object]
foreach ($wr in (Get-XmlNodes $projXml 'WebReferenceUrl')) {
    $u = $wr.GetAttribute('Include')
    if ($u -match '(?i)reportserver|reportexecution2005|reportservice2010') { $reportRendering.Add([pscustomobject]@{ Kind = 'SSRS web service'; Where = 'web reference in the .csproj'; Line = $null; Detail = $u }) }
}
foreach ($h in $hits) {
    if ($h.Category -ne 'Reporting' -or $h.Accepted) { continue }
    if ($h.File -match '(?i)[\\/](Web References|Connected Services|Service References)[\\/]') { continue }
    $kind = if ($h.Api -like 'ReportViewer*') { 'ReportViewer local report' } else { 'SSRS web service' }
    $reportRendering.Add([pscustomobject]@{ Kind = $kind; Where = $h.File; Line = $h.Line; Detail = $h.Text })
}
$reportNote = $null
if ($reportRendering.Count) { $reportNote = 'Renders reports through SQL Server Reporting Services or ReportViewer. Dataverse Online has no Report Server web service that a plug-in can call, so this needs a redesign for Online (see references/online-checklist.md, "Report rendering"). On-premises Sandbox: the web service call is allowed over HTTP(S) to a DNS name; ReportViewer local rendering is blocked.' }

$online = [pscustomobject]@{
    TargetFramework      = $fwInfo
    Signing              = $signing
    AssemblyVersion      = $versionInfo
    EntryPoints          = [pscustomobject]@{ Plugins = $plugins.ToArray(); WorkflowActivities = $workflows.ToArray(); Assumed = $assumedEntries }
    ContainsWorkflowActivities = ($workflows.Count -gt 0)
    DependencyCandidates = $deps.ToArray()
    HttpCalls            = $httpCalls.ToArray()
    UrlLiterals          = $urlLiterals.ToArray()
    LoopRisks            = $loopRisks.ToArray()
    MergeTool            = $merge
    ThirdPartyLibraries  = $thirdParty.ToArray()
    ReportRendering      = [pscustomobject]@{ Found = ($reportRendering.Count -gt 0); Items = $reportRendering.ToArray(); Note = $reportNote }
}

# ---------------------------------------------------------------- configured serializer check
$serializerCheck = $null
if ($serStrategy -eq 'existing') {
    $declared = New-Object System.Collections.Generic.List[string]
    $fileChecks = New-Object System.Collections.Generic.List[object]
    $contents = @{}
    foreach ($sf in $serFiles) {
        if (Test-Path -LiteralPath $sf) {
            $c = [IO.File]::ReadAllText($sf) -replace '(?s)/\*.*?\*/', '' -replace '(?m)//.*$', ''
            $contents[$sf] = $c
            foreach ($nm in [regex]::Matches($c, '\bnamespace\s+([\w\.]+)')) { $declared.Add($nm.Groups[1].Value) }
        }
    }
    $allProblems = New-Object System.Collections.Generic.List[string]
    foreach ($sf in $serFiles) {
        $probs = New-Object System.Collections.Generic.List[string]
        if (-not $contents.ContainsKey($sf)) { $probs.Add('file not found') }
        else {
            $c = $contents[$sf]
            foreach ($ln in ($c -split "`n")) {
                if (-not $prefilter.IsMatch($ln)) { continue }
                foreach ($pt in $compiled) {
                    if (($pt.Severity -eq 'Blocked' -or $pt.Severity -eq 'Avoid') -and $pt.Regex.IsMatch($ln) -and $ln.Trim() -notmatch '^using\s') { $probs.Add("$($pt.Severity): $($pt.Api) - $($ln.Trim())") }
                }
            }
            foreach ($um in [regex]::Matches($c, '(?m)^\s*using\s+(?!System\b)(?!static\s+System\b)([\w\.]+)\s*;')) {
                $u = $um.Groups[1].Value
                if (-not ($declared | Where-Object { $u -eq $_ -or $_.StartsWith($u + '.') })) { $probs.Add("depends on namespace $u, which is not in serializer.files - add its file(s)") }
            }
        }
        foreach ($pr in $probs) { $allProblems.Add("$([IO.Path]::GetFileName($sf)): $pr") }
        $fileChecks.Add([pscustomobject]@{ Path = $sf; Exists = $contents.ContainsKey($sf); Problems = $probs.ToArray() })
    }
    $serializerCheck = [pscustomobject]@{
        Strategy = 'existing'; ClassName = $serClass; Files = $fileChecks.ToArray()
        SerializeCall = [string](Get-Prop $ser 'serializeCall' ''); DeserializeCall = [string](Get-Prop $ser 'deserializeCall' '')
        Usings = @(Get-Prop $ser 'usings' @()); DateStyle = [string](Get-Prop $ser 'dateStyle' '')
        SandboxSafe = ($allProblems.Count -eq 0); Problems = $allProblems.ToArray()
        CompiledIntoThisProject = @($serFiles | Where-Object { $files.ContainsKey($_) -and $files[$_].Source -ne 'referenced' }).Count -eq $serFiles.Count
    }
} else {
    $serializerCheck = [pscustomobject]@{
        Strategy = 'builtin'; ClassName = $serClass; Namespace = [string](Get-Prop $ser 'namespace' '')
        File = $serFile; FileExists = [bool]($serFile -and (Test-Path -LiteralPath $serFile))
    }
}
$settings = [pscustomobject]@{
    Path = $cfgPath; Loaded = [bool]$raw; Errors = $cfgErrors.ToArray(); Warnings = $cfgWarnings.ToArray()
    Target = $target; ReportEnabled = $repEnabled; ReportLocation = $repLocation
    SharedHelperFolder = $sharedHelper; SharedHelperNamespace = $sharedHelperNs; SkipProjects = $skipProjects; HttpTimeoutSeconds = $httpTimeout
    AcceptedFindings = $suppressions.ToArray()
}

# ---------------------------------------------------------------- output
$fileList = @($fileRows | Sort-Object Source, Path)
$result = [pscustomobject]@{
    Project            = $projName
    Csproj             = $csproj
    AssemblyName       = $assemblyName
    ProjectStyle       = $(if ($isSdk) { 'sdk' } else { 'legacy' })
    TargetFramework    = $targetFw
    Counts             = [pscustomobject]@{
        Files   = @($fileList | Where-Object Source -ne 'referenced').Count
        Referenced = @($fileList | Where-Object Source -eq 'referenced').Count
        Local   = @($fileList | Where-Object Source -eq 'local').Count
        Linked  = @($fileList | Where-Object Source -eq 'linked').Count
        Shared  = @($fileList | Where-Object Source -eq 'shared').Count
        Missing = @($fileList | Where-Object { -not $_.Exists }).Count
        FilesWithHits = @($fileList | Where-Object { $_.Hits -gt 0 }).Count
        Hits    = $hits.Count
        Blocked = @($hits | Where-Object { $_.Severity -eq 'Blocked' -and -not $_.Accepted }).Count
        Avoid   = @($hits | Where-Object { $_.Severity -eq 'Avoid' -and -not $_.Accepted }).Count
        Review  = @($hits | Where-Object { $_.Severity -eq 'Review' -and -not $_.Accepted }).Count
        Harden  = @($hits | Where-Object { $_.Severity -eq 'Harden' -and -not $_.Accepted }).Count
        Accepted = @($hits | Where-Object { $_.Accepted }).Count
    }
    Settings           = $settings
    SerializerCheck    = $serializerCheck
    VersionControl     = $vcs
    OnlineReadiness    = $online
    Files              = $fileList
    Hits               = $hits.ToArray()
    UnresolvedIncludes = $unresolved.ToArray()
    LocalCsNotCompiled = $notCompiled
    References         = $refs
    PackageReferences  = $pkgRefs
    PackagesConfig     = $packages
    ProjectReferences  = $projRefs
    ReferencedProjects = $referencedProjects.ToArray()
    SolutionRoot       = $SolutionRoot
    SolutionProjects   = $solutionProjects
    ExistingAppSerializers = @($appSerializers)
    ExistingHelpers    = $existingHelpers.ToArray()
    ElapsedSeconds     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8

# compact console summary (Claude reads the JSON for details)
$c = $result.Counts
Write-Output "Project: $projName ($($result.ProjectStyle), $targetFw) -> $assemblyName.dll"
Write-Output "Files: $($c.Files) compiled ($($c.Local) local, $($c.Linked) linked, $($c.Shared) shared) | missing: $($c.Missing) | unresolved includes: $($unresolved.Count)"
if ($referencedProjects.Count) {
    Write-Output ("Referenced projects: {0} (+{1} files scanned - their code runs in this plug-in, but in its own DLL)" -f $referencedProjects.Count, $c.Referenced)
    foreach ($rpj in $referencedProjects) {
        $rh = @($hits | Where-Object { $_.ReferencedProject -eq $rpj.Name -and -not $_.Accepted -and $_.Severity -in @('Blocked', 'Avoid', 'Review') }).Count
        Write-Output ("  {0}{1}: {2} files, {3} finding(s){4}{5}" -f $rpj.Name, $(if ($rpj.Depth -gt 1) { " (via $($rpj.Via))" } else { '' }), $rpj.Files, $rh, $(if (@($rpj.ReferencedBy).Count) { "; referenced by $(@($rpj.ReferencedBy).Count) project(s)" } else { '' }), $(if (-not $rpj.Exists) { ' - PROJECT FILE NOT FOUND' } else { '' }))
    }
}
Write-Output "Hits: $($c.Hits) in $($c.FilesWithHits) files (Blocked $($c.Blocked), Avoid $($c.Avoid), Review $($c.Review), Harden $($c.Harden), Using $(@($hits | Where-Object Severity -eq 'Using').Count), Accepted $($c.Accepted))"
Write-Output ("Settings: {0}" -f $(if ($cfgPath) { $cfgPath } else { 'none (defaults)' }))
foreach ($e in $cfgErrors) { Write-Output "  ERROR: $e" }
foreach ($w in $cfgWarnings) { Write-Output "  warning: $w" }
Write-Output ("Version control: {0}{1}" -f $vcs.Type, $(if ($vcs.Root) { " ($($vcs.Root))" } else { '' }))
if ($serializerCheck.Strategy -eq 'existing') {
    Write-Output ("Serializer: existing {0} - {1}" -f $serClass, $(if ($serializerCheck.SandboxSafe) { 'Sandbox-safe' } else { 'NOT Sandbox-safe' }))
    foreach ($pr in $serializerCheck.Problems) { Write-Output "  - $pr" }
} else { Write-Output ("Serializer: builtin {0}{1}" -f $serClass, $(if ($serializerCheck.File) { " -> $($serializerCheck.File)" } else { '' })) }
if ($SolutionRoot) {
    Write-Output "Solution: $solutionProjects projects scanned for shared links | existing ${serClass}: $(@($appSerializers).Count)"
    foreach ($a in $appSerializers) {
        $verdict = if (-not $a.Reusable) { 'NOT reusable' } elseif ($a.Upgrade) { 'reusable after upgrade' } else { 'reusable' }
        $where = if ($a.CompiledIntoThisProject) { ' [already compiled into this project]' } else { '' }
        Write-Output ("  {0} ({1}, {2}) -> {3}{4}" -f $a.Path, $a.Namespace, $a.Visibility, $verdict, $where)
        foreach ($r in $a.Reasons) { Write-Output "     - $r" }
    }
}
if ($existingHelpers.Count) {
    Write-Output ("Existing shared helpers: {0}" -f $existingHelpers.Count)
    foreach ($h in $existingHelpers) {
        Write-Output ("  {0} {1} ({2}) -> {3}{4}" -f $h.Name, $h.Path, $h.Namespace, $(if ($h.Reusable) { 'reusable' } else { 'NOT reusable' }), $(if ($h.CompiledIntoThisProject) { ' [already compiled into this project]' } else { '' }))
        foreach ($r in $h.Reasons) { Write-Output "     - $r" }
    }
}
Write-Output "--- hits (file:line [severity/category] api | member) ---"
foreach ($h in ($hits | Sort-Object Source, File, Line)) {
    $rel = if ($h.File.StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase)) { $h.File.Substring($projDir.Length).TrimStart('\', '/') } else { $h.File }
    $tag = if ($h.Source -ne 'local') { "[$($h.Source.ToUpper())] " } else { '' }
    $dbg = if ($h.InDebug) { ' (#if DEBUG)' } else { '' }
    if ($h.Accepted) { $dbg += " (ACCEPTED: $($h.Accepted))" }
    Write-Output ("{0}{1}:{2} [{3}/{4}] {5} | {6}{7}" -f $tag, $rel, $h.Line, $h.Severity, $h.Category, $h.Api, $h.Member, $dbg)
}
function Get-Rel([string]$p) { if ($p -and $p.StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($projDir.Length).TrimStart('\', '/') } else { $p } }
Write-Output "--- online readiness ---"
Write-Output ("Framework: {0} [{1}] {2}" -f $fwInfo.Value, $fwInfo.Status, $fwInfo.Note)
Write-Output ("Signing:   [{0}] {1} {2}" -f $signing.Status, $signing.Note, $(if ($signing.KeyFile) { "($($signing.KeyFile))" } else { '' }))
Write-Output ("Version:   {0} - {1}" -f $versionInfo.Value, $versionInfo.Note)
Write-Output ("Entry points: {0} plug-in(s), {1} workflow activit(ies){2}" -f $plugins.Count, $workflows.Count, $(if ($workflows.Count) { ' -> plug-in packages NOT available; assembly must have no runtime dependencies' } else { '' }))
foreach ($ae in $assumedEntries) { Write-Output ("  assumed {0}: {1} (base class {2} is not in the source - confirm)" -f $ae.Kind, $ae.Class, $ae.Base) }
Write-Output ("Dependency candidates (confirm against the compiled DLL): {0}" -f $(if ($deps.Count) { ($deps | ForEach-Object { "$($_.Name) ($($_.Kind))" }) -join ', ' } else { 'none' }))
if ($merge) {
    Write-Output ("Merge tool: {0} ({1}) -> merged libraries are REAL dependencies: {2}" -f $merge.Tool, (($merge.Evidence | Select-Object -First 3) -join '; '), $(if ($merge.MergedLibraries.Count) { $merge.MergedLibraries -join ', ' } else { 'none found' }))
}
$outsideFiles = @($fileRows | Where-Object { @($_.SharedByNonAssembly).Count -and $_.Hits -gt 0 })
if ($outsideFiles.Count) {
    Write-Output ("Shared code with findings that non-plug-in projects also use ({0} file(s)) - ask before editing:" -f $outsideFiles.Count)
    foreach ($of in ($outsideFiles | Select-Object -First 15)) { Write-Output ("  {0} -> {1}" -f (Get-Rel $of.Path), ((@($of.SharedByNonAssembly) | ForEach-Object { "$($_.Project) ($($_.Reason))" }) -join ', ')) }
}
foreach ($tl in $thirdParty) { if ($tl.Status -ne 'OK') { Write-Output ("Library: {0} [{1}]{2} - {3}" -f $tl.Library, $tl.Status, $(if ($tl.Merged) { ' (merged)' } else { '' }), $tl.Why) } }
if ($reportRendering.Count) {
    Write-Output ("Report rendering: {0} place(s) - needs a redesign for Dataverse Online" -f $reportRendering.Count)
    foreach ($rr in $reportRendering) { Write-Output ("  {0}: {1}{2} {3}" -f $rr.Kind, (Get-Rel $rr.Where), $(if ($rr.Line) { ":$($rr.Line)" } else { '' }), $(if ($rr.Kind -eq 'SSRS web service' -and -not $rr.Line) { $rr.Detail } else { '' })) }
}
Write-Output "HTTP calls (file:line member call -> url source):"
foreach ($hc in $httpCalls) {
    $src = if ($hc.Url) { "$($hc.UrlSource) $($hc.Url) [$($hc.UrlClass): $($hc.UrlDetail)]" } else { "$($hc.UrlSource) $($hc.UrlKey)" }
    $via = if ($hc.Via) { " via $($hc.Via)" } else { '' }
    $lp = if ($hc.InLoop) { " (in loop @ line $($hc.LoopLine))" } else { '' }
    Write-Output ("  {0}:{1} {2} {3} -> {4}{5}{6}" -f (Get-Rel $hc.File), $hc.Line, $hc.Member, $hc.Call, $src, $via, $lp)
}
$flagged = @($urlLiterals | Where-Object { $_.Class -ne 'LooksPublic' })
Write-Output ("Hard-coded URLs: {0} ({1} flagged)" -f $urlLiterals.Count, $flagged.Count)
foreach ($ul in $flagged) { Write-Output ("  {0}:{1} {2} [{3}: {4}]{5}" -f (Get-Rel $ul.File), $ul.Line, $ul.Url, $ul.Class, $ul.Detail, $(if ($ul.Accepted) { " (ACCEPTED: $($ul.Accepted))" } else { '' })) }
Write-Output ("Calls inside loops: {0}" -f $loopRisks.Count)
foreach ($lr in $loopRisks) { Write-Output ("  {0}:{1} {2} {3} (loop @ line {4})" -f (Get-Rel $lr.File), $lr.Line, $lr.Member, $lr.Call, $lr.LoopLine) }
Write-Output "JSON: $OutFile  ($($result.ElapsedSeconds)s)"
