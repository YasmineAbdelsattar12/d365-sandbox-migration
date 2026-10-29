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
    4. Writes the full result as JSON (-OutFile) and prints a compact summary.

    The scanner only FINDS candidates. Claude still reads each hit in context,
    verifies callers, and decides what to fix.

    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scan.ps1 -Project "D:\Repo\Cs\My.Plugin" -SolutionRoot "D:\Repo" -OutFile "$env:TEMP\scan.json"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,      # .csproj path or folder containing one
    [string]$OutFile,                                    # JSON output path (default: %TEMP%\sandbox-scan-<project>.json)
    [string]$SolutionRoot                                # optional: folder to search for other projects / AppSerializer
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$isWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
$sep = [IO.Path]::DirectorySeparatorChar
$cmp = if ($isWin) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
$excludeDirs = '[\\/](bin|obj|packages|node_modules|\.git|\.vs)[\\/]'

# ---------------------------------------------------------------- project path
if (Test-Path -LiteralPath $Project -PathType Container) {
    $found = @(Get-ChildItem -LiteralPath $Project -Filter *.csproj -File)
    if ($found.Count -eq 0) { throw "No .csproj found in $Project" }
    if ($found.Count -gt 1) { throw "Multiple .csproj files in $Project - pass one explicitly: $($found.Name -join ', ')" }
    $csproj = $found[0].FullName
} else {
    $csproj = (Resolve-Path -LiteralPath $Project).Path
}
$projDir = Split-Path -Parent $csproj
$projName = [IO.Path]::GetFileNameWithoutExtension($csproj)
if (-not $OutFile) { $OutFile = Join-Path ([IO.Path]::GetTempPath()) "sandbox-scan-$projName.json" }
if ($SolutionRoot) { $SolutionRoot = (Resolve-Path -LiteralPath $SolutionRoot).Path }

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
                   elseif ($link -or $inc -match '^\.\.|[\\/]\.\.[\\/]' -or -not $f.StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase)) { 'linked' }
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

# ---------------------------------------------------------------- patterns
# Severity: Blocked = throws in Sandbox if executed | Review = depends on usage
#           Harden  = allowed, but apply HTTP hardening | Using = namespace import only
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
    @('Network',    'Blocked', 'Non-80/443 port in URL', '(?i)https?://[^/"\s:]+:(?!80\b|443\b)\d+'),
    # HTTP hardening targets
    @('HTTP',       'Harden',  'HttpClient',          '\bnew\s+HttpClient\s*\('),
    @('HTTP',       'Harden',  'WebRequest',          '\b(Http)?WebRequest\.Create(Http)?\s*\('),
    @('HTTP',       'Harden',  'WebClient',           '\bnew\s+WebClient\s*\('),
    @('HTTP',       'Review',  '.Result / .Wait() on a task', '(\)\s*\.Result\b|\.Wait\(\s*\))'),
    # Threading
    @('Threading',  'Blocked', 'new Thread',          '\bnew\s+(System\.Threading\.)?Thread\s*\('),
    @('Threading',  'Blocked', 'ThreadPool',          '\bThreadPool\.QueueUserWorkItem'),
    @('Threading',  'Review',  'Task.Run / StartNew', '\b(Task\.Run|Task\.Factory\.StartNew)\s*\('),
    @('Threading',  'Review',  'Parallel.*',          '\bParallel\.(For|ForEach|Invoke)\b'),
    @('Threading',  'Blocked', 'Timer',               '\bnew\s+(System\.Timers\.|System\.Threading\.)?Timer\s*\('),
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
    @('Misc',       'Blocked', 'Blocked namespace',   '\b(Microsoft\.VisualBasic|System\.Windows\.Forms|System\.Management|System\.ServiceProcess|System\.Printing|System\.Speech|System\.Drawing|System\.Windows\.Media)\b')
)
$compiled = foreach ($p in $patterns) {
    [pscustomobject]@{ Category = $p[0]; Severity = $p[1]; Api = $p[2]; Regex = New-Object regex($p[3], 'Compiled') }
}
$prefilter = New-Object regex((($patterns | ForEach-Object { '(?:' + $_[3] + ')' }) -join '|'), 'Compiled')
$methodRx = New-Object regex('^\s*(?:\[[^\]]*\]\s*)*(?:(?:public|private|protected|internal|static|override|virtual|abstract|sealed|async|new|extern|unsafe|partial)\s+)+[\w<>\[\],\.\?\s]+?\s+(\w+)\s*(?:<[^>]*>)?\s*\(', 'Compiled')
$typeRx = New-Object regex('\b(class|struct|interface)\s+(\w+)', 'Compiled')

# ---------------------------------------------------------------- resolve files
[xml]$projXml = Get-Content -LiteralPath $csproj -Raw
$isSdk = [bool]$projXml.DocumentElement.GetAttribute('Sdk')
$assemblyName = (Get-XmlNodes $projXml 'AssemblyName' | Select-Object -First 1).InnerText
if (-not $assemblyName) { $assemblyName = $projName }
$targetFw = (Get-XmlNodes $projXml 'TargetFrameworkVersion' | Select-Object -First 1).InnerText
if (-not $targetFw) { $targetFw = (Get-XmlNodes $projXml 'TargetFramework' | Select-Object -First 1).InnerText }

$all = Get-CompileFiles $csproj $isSdk
$files = New-Object 'System.Collections.Generic.Dictionary[string,object]' $cmp
$unresolved = New-Object System.Collections.Generic.List[string]
foreach ($f in $all) {
    if ($f.Path -like 'UNRESOLVED:*') { $unresolved.Add($f.Path.Substring(11)); continue }
    if ($f.Path -notlike '*.cs') { continue }
    if (-not $files.ContainsKey($f.Path)) { $files[$f.Path] = $f }
}

$notCompiled = @()
if (-not $isSdk) {
    $notCompiled = @(Get-ChildItem -LiteralPath $projDir -Recurse -Filter *.cs -File |
        Where-Object { $_.FullName -notmatch $excludeDirs -and -not $files.ContainsKey($_.FullName) } |
        ForEach-Object { $_.FullName.Substring($projDir.Length).TrimStart('\', '/') })
}

# ---------------------------------------------------------------- solution-wide info (optional)
$linkCount = New-Object 'System.Collections.Generic.Dictionary[string,object]' $cmp
$appSerializers = @()
$solutionProjects = 0
if ($SolutionRoot) {
    $projFiles = @(Get-ChildItem -LiteralPath $SolutionRoot -Recurse -Filter *.csproj -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludeDirs })
    $solutionProjects = $projFiles.Count
    $appSerializers = @(Get-ChildItem -LiteralPath $SolutionRoot -Recurse -Filter *.cs -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $excludeDirs } |
        Select-String -Pattern '\bclass\s+AppSerializer\b' -List |
        ForEach-Object {
            $content = [IO.File]::ReadAllText($_.Path)
            $ns = [regex]::Match($content, '\bnamespace\s+([\w\.]+)').Groups[1].Value
            [pscustomobject]@{
                Path = $_.Path
                Namespace = $ns
                Visibility = if ($content -match '\bpublic\s+(static\s+)?class\s+AppSerializer') { 'public' } else { 'internal' }
                OldDateFormat = [bool]($content -match 'fffZ')
                LinkedBy = @()
            }
        })
    $appSet = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
    foreach ($a in $appSerializers) { [void]$appSet.Add($a.Path) }
    foreach ($pf in $projFiles) {
        try {
            [xml]$px = Get-Content -LiteralPath $pf.FullName -Raw
            $sdk = [bool]$px.DocumentElement.GetAttribute('Sdk')
            foreach ($cf in (Get-CompileFiles $pf.FullName $sdk)) {
                if (-not $files.ContainsKey($cf.Path) -and -not $appSet.Contains($cf.Path)) { continue }
                if (-not $linkCount.ContainsKey($cf.Path)) { $linkCount[$cf.Path] = New-Object System.Collections.Generic.List[string] }
                if (-not $linkCount[$cf.Path].Contains($pf.BaseName)) { $linkCount[$cf.Path].Add($pf.BaseName) }
            }
        } catch { Write-Warning "Could not parse $($pf.FullName): $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- scan
$hits = New-Object System.Collections.Generic.List[object]
$fileRows = New-Object System.Collections.Generic.List[object]
foreach ($f in $files.Values) {
    $exists = Test-Path -LiteralPath $f.Path
    $count = 0; $types = @()
    if ($exists) {
        $lines = [IO.File]::ReadAllLines($f.Path)
        $inBlock = $false; $ppStack = New-Object System.Collections.Generic.List[string]
        $member = $null; $typeNames = New-Object System.Collections.Generic.List[string]
        for ($i = 0; $i -lt $lines.Length; $i++) {
            $line = $lines[$i]; $t = $line.Trim()
            # block comments (line-level approximation)
            if ($inBlock) { if ($t.Contains('*/')) { $inBlock = $false }; continue }
            if ($t.StartsWith('/*')) { if (-not $t.Contains('*/')) { $inBlock = $true }; continue }
            if ($t.StartsWith('//')) { continue }
            # preprocessor tracking for #if DEBUG
            if ($t -match '^#if\s+(.*)') { $ppStack.Add($(if ($matches[1] -match '^\s*DEBUG\b') { 'debug' } else { 'other' })); continue }
            if ($t -match '^#else' -and $ppStack.Count) { if ($ppStack[$ppStack.Count - 1] -eq 'debug') { $ppStack[$ppStack.Count - 1] = 'notdebug' }; continue }
            if ($t -match '^#endif' -and $ppStack.Count) { $ppStack.RemoveAt($ppStack.Count - 1); continue }
            $tm = $typeRx.Match($line); if ($tm.Success -and -not $t.StartsWith('using')) { if (-not $typeNames.Contains($tm.Groups[2].Value)) { $typeNames.Add($tm.Groups[2].Value) } }
            if ($t -notmatch '^(if|for|foreach|while|switch|catch|using|return|throw|else|lock)\b') {
                $mm = $methodRx.Match($line); if ($mm.Success -and -not $t.EndsWith(';')) { $member = $mm.Groups[1].Value }
            }
            if (-not $prefilter.IsMatch($line)) { continue }
            $isUsing = $t -match '^using\s+[\w\.]+\s*;'
            foreach ($p in $compiled) {
                if (-not $p.Regex.IsMatch($line)) { continue }
                $count++
                $hits.Add([pscustomobject]@{
                    File     = $f.Path
                    Source   = $f.Source
                    Line     = $i + 1
                    Category = $p.Category
                    Severity = $(if ($isUsing) { 'Using' } else { $p.Severity })
                    Api      = $p.Api
                    Member   = $(if ($isUsing) { $null } else { $member })
                    InDebug  = $ppStack.Contains('debug')
                    Text     = $(if ($t.Length -gt 200) { $t.Substring(0, 200) + '...' } else { $t })
                })
            }
        }
        $types = $typeNames.ToArray()
    }
    $sharedBy = $null
    if ($linkCount.ContainsKey($f.Path)) { $sharedBy = $linkCount[$f.Path].ToArray() }
    $fileRows.Add([pscustomobject]@{
        Path = $f.Path; Source = $f.Source; Include = $f.Include; Link = $f.Link
        Exists = $exists; Hits = $count; Types = $types
        SharedByProjects = $(if ($sharedBy) { $sharedBy.Count } else { $null })
        SharedBy = $sharedBy
    })
}
foreach ($a in $appSerializers) { if ($linkCount.ContainsKey($a.Path)) { $a.LinkedBy = $linkCount[$a.Path].ToArray() } }

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

# ---------------------------------------------------------------- output
$fileList = @($fileRows | Sort-Object Source, Path)
$result = [pscustomobject]@{
    Project            = $projName
    Csproj             = $csproj
    AssemblyName       = $assemblyName
    ProjectStyle       = $(if ($isSdk) { 'sdk' } else { 'legacy' })
    TargetFramework    = $targetFw
    Counts             = [pscustomobject]@{
        Files   = $fileList.Count
        Local   = @($fileList | Where-Object Source -eq 'local').Count
        Linked  = @($fileList | Where-Object Source -eq 'linked').Count
        Shared  = @($fileList | Where-Object Source -eq 'shared').Count
        Missing = @($fileList | Where-Object { -not $_.Exists }).Count
        FilesWithHits = @($fileList | Where-Object { $_.Hits -gt 0 }).Count
        Hits    = $hits.Count
        Blocked = @($hits | Where-Object Severity -eq 'Blocked').Count
        Review  = @($hits | Where-Object Severity -eq 'Review').Count
        Harden  = @($hits | Where-Object Severity -eq 'Harden').Count
    }
    Files              = $fileList
    Hits               = $hits.ToArray()
    UnresolvedIncludes = $unresolved.ToArray()
    LocalCsNotCompiled = $notCompiled
    References         = $refs
    PackageReferences  = $pkgRefs
    PackagesConfig     = $packages
    ProjectReferences  = $projRefs
    SolutionRoot       = $SolutionRoot
    SolutionProjects   = $solutionProjects
    ExistingAppSerializers = @($appSerializers)
    ElapsedSeconds     = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8

# compact console summary (Claude reads the JSON for details)
$c = $result.Counts
Write-Output "Project: $projName ($($result.ProjectStyle), $targetFw) -> $assemblyName.dll"
Write-Output "Files: $($c.Files) compiled ($($c.Local) local, $($c.Linked) linked, $($c.Shared) shared) | missing: $($c.Missing) | unresolved includes: $($unresolved.Count)"
Write-Output "Hits: $($c.Hits) in $($c.FilesWithHits) files (Blocked $($c.Blocked), Review $($c.Review), Harden $($c.Harden), Using $(@($hits | Where-Object Severity -eq 'Using').Count))"
if ($SolutionRoot) { Write-Output "Solution: $solutionProjects projects scanned for shared links | existing AppSerializer: $(@($appSerializers).Count)" }
Write-Output "--- hits (file:line [severity/category] api | member) ---"
foreach ($h in ($hits | Sort-Object Source, File, Line)) {
    $rel = if ($h.File.StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase)) { $h.File.Substring($projDir.Length).TrimStart('\', '/') } else { $h.File }
    $tag = if ($h.Source -ne 'local') { "[$($h.Source.ToUpper())] " } else { '' }
    $dbg = if ($h.InDebug) { ' (#if DEBUG)' } else { '' }
    Write-Output ("{0}{1}:{2} [{3}/{4}] {5} | {6}{7}" -f $tag, $rel, $h.Line, $h.Severity, $h.Category, $h.Api, $h.Member, $dbg)
}
Write-Output "JSON: $OutFile  ($($result.ElapsedSeconds)s)"
