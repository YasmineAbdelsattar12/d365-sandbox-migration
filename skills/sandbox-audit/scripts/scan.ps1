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
    @('Auth',       'Review',  'NetworkCredential',   '\bnew\s+NetworkCredential\s*\('),
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
$httpCalls = New-Object System.Collections.Generic.List[object]
$urlLiterals = New-Object System.Collections.Generic.List[object]
$loopRisks = New-Object System.Collections.Generic.List[object]
$classBases = New-Object 'System.Collections.Generic.Dictionary[string,object]'
$asmVersion = $null; $asmKeyAttr = $null
foreach ($f in $files.Values) {
    $exists = Test-Path -LiteralPath $f.Path
    $count = 0; $types = @()
    if ($exists) {
        $lines = [IO.File]::ReadAllLines($f.Path)
        $fileText = [string]::Join("`n", $lines)
        $inBlock = $false; $ppStack = New-Object System.Collections.Generic.List[string]
        $member = $null; $memberStart = -1; $memberBase = @{}
        $typeNames = New-Object System.Collections.Generic.List[string]
        $depth = 0; $loops = New-Object System.Collections.Generic.List[object]
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
                $mm = $methodRx.Match($line); if ($mm.Success -and -not $t.EndsWith(';')) { $member = $mm.Groups[1].Value; $memberStart = $i; $memberBase = @{} }
            }

            # ---- online readiness: structure, loops, URLs, HTTP calls
            $code = $line -replace '@"(?:[^"]|"")*"', '""' -replace '"(?:[^"\\]|\\.)*"', '""' -replace "'(?:[^'\\]|\\.)'", "''" -replace '//.*$', ''
            $ct = $code.Trim()
            $inLoop = $false; $loopLine = $null
            foreach ($lp in $loops) { if ($lp.Entered -or ($i -gt $lp.Line -and $ct)) { $inLoop = $true; $loopLine = $lp.Line + 1 } }
            $cd = $classDeclRx.Match($code)
            if ($cd.Success) {
                $bases = @($cd.Groups['b'].Value -split ',' | ForEach-Object { (($_.Trim() -split '<')[0] -split '\.')[-1].Trim() } | Where-Object { $_ -and $_ -ne 'where' })
                $classBases[$cd.Groups['n'].Value] = [pscustomobject]@{ Bases = $bases; Abstract = [bool]($code -match '\babstract\s+(partial\s+)?class\b'); File = $f.Path; Line = $i + 1 }
            }
            $av = [regex]::Match($line, '^\s*\[\s*assembly\s*:\s*AssemblyVersion(?:Attribute)?\s*\(\s*"([^"]+)"')
            if ($av.Success -and -not $ppStack.Contains('debug')) { $asmVersion = [pscustomobject]@{ Value = $av.Groups[1].Value; File = $f.Path; Line = $i + 1 } }
            $ak = [regex]::Match($line, '^\s*\[\s*assembly\s*:\s*AssemblyKeyFile(?:Attribute)?\s*\(\s*@?"([^"]*)"')
            if ($ak.Success -and $ak.Groups[1].Value) { $asmKeyAttr = $ak.Groups[1].Value }
            if (-not $ppStack.Contains('debug')) {
                foreach ($um in $urlLiteralRx.Matches($line)) {
                    $u = $um.Groups['u'].Value; $uc = Get-UrlClass $u
                    if ($uc.Host -and $uc.Host -match $nsHosts) { continue }
                    $urlLiterals.Add([pscustomobject]@{ File = $f.Path; Source = $f.Source; Line = $i + 1; Member = $member; Url = $u; Class = $uc.Class; Detail = $uc.Detail })
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
function Get-EntryKind([string]$name, [int]$d) {
    if ($d -gt 12 -or -not $classBases.ContainsKey($name)) { return $null }
    $cb = $classBases[$name]
    if ($cb.Bases -contains 'IPlugin') { return 'Plugin' }
    if ($cb.Bases.Count -and $cb.Bases[0] -match '^(CodeActivity|AsyncCodeActivity|NativeActivity)$') { return 'WorkflowActivity' }
    foreach ($b in $cb.Bases) { $k = Get-EntryKind $b ($d + 1); if ($k) { return $k } }
    return $null
}
$plugins = New-Object System.Collections.Generic.List[string]; $workflows = New-Object System.Collections.Generic.List[string]
foreach ($n in $classBases.Keys) {
    if ($classBases[$n].Abstract) { continue }
    $k = Get-EntryKind $n 0
    if ($k -eq 'Plugin') { $plugins.Add($n) } elseif ($k -eq 'WorkflowActivity') { $workflows.Add($n) }
}

# dependency candidates (confirm against the compiled DLL after the build)
$fwRefRx = '^(mscorlib|netstandard|System(\..+)?|Microsoft\.CSharp|Microsoft\.Xrm\.Sdk(\..+)?|Microsoft\.Crm\.Sdk\.Proxy|WindowsBase|Microsoft\.VisualBasic)$'
$fwPkgRx = '^(Microsoft\.CrmSdk\..+|System\..+|Microsoft\.NETFramework\.ReferenceAssemblies.*|Microsoft\.PowerApps\.MSBuild\..+)$'
$deps = New-Object System.Collections.Generic.List[object]
foreach ($r in (Get-XmlNodes $projXml 'Reference')) {
    $nm = ($r.GetAttribute('Include') -split ',')[0].Trim()
    if ($nm -match $fwRefRx) { continue }
    $hp = $null; foreach ($ch in $r.ChildNodes) { if ($ch.LocalName -eq 'HintPath') { $hp = $ch.InnerText } }
    $deps.Add([pscustomobject]@{ Name = $nm; Kind = 'Reference'; Detail = $hp })
}
foreach ($pr in (Get-XmlNodes $projXml 'PackageReference')) {
    $nm = $pr.GetAttribute('Include'); if ($nm -match $fwPkgRx) { continue }
    $deps.Add([pscustomobject]@{ Name = $nm; Kind = 'PackageReference'; Detail = $pr.GetAttribute('Version') })
}
foreach ($pk in $packages) {
    $nm = ($pk -split ' ')[0]; if ($nm -match $fwPkgRx -or ($deps | Where-Object { $_.Name -eq $nm })) { continue }
    $deps.Add([pscustomobject]@{ Name = $nm; Kind = 'packages.config'; Detail = ($pk -split ' ')[1] })
}
foreach ($pj in $projRefs) { $deps.Add([pscustomobject]@{ Name = [IO.Path]::GetFileNameWithoutExtension(($pj -replace '[\\/]', $sep)); Kind = 'ProjectReference'; Detail = $pj }) }

$online = [pscustomobject]@{
    TargetFramework      = $fwInfo
    Signing              = $signing
    AssemblyVersion      = $versionInfo
    EntryPoints          = [pscustomobject]@{ Plugins = $plugins.ToArray(); WorkflowActivities = $workflows.ToArray() }
    ContainsWorkflowActivities = ($workflows.Count -gt 0)
    DependencyCandidates = $deps.ToArray()
    HttpCalls            = $httpCalls.ToArray()
    UrlLiterals          = $urlLiterals.ToArray()
    LoopRisks            = $loopRisks.ToArray()
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
        Avoid   = @($hits | Where-Object Severity -eq 'Avoid').Count
        Review  = @($hits | Where-Object Severity -eq 'Review').Count
        Harden  = @($hits | Where-Object Severity -eq 'Harden').Count
    }
    OnlineReadiness    = $online
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
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutFile -Encoding UTF8

# compact console summary (Claude reads the JSON for details)
$c = $result.Counts
Write-Output "Project: $projName ($($result.ProjectStyle), $targetFw) -> $assemblyName.dll"
Write-Output "Files: $($c.Files) compiled ($($c.Local) local, $($c.Linked) linked, $($c.Shared) shared) | missing: $($c.Missing) | unresolved includes: $($unresolved.Count)"
Write-Output "Hits: $($c.Hits) in $($c.FilesWithHits) files (Blocked $($c.Blocked), Avoid $($c.Avoid), Review $($c.Review), Harden $($c.Harden), Using $(@($hits | Where-Object Severity -eq 'Using').Count))"
if ($SolutionRoot) { Write-Output "Solution: $solutionProjects projects scanned for shared links | existing AppSerializer: $(@($appSerializers).Count)" }
Write-Output "--- hits (file:line [severity/category] api | member) ---"
foreach ($h in ($hits | Sort-Object Source, File, Line)) {
    $rel = if ($h.File.StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase)) { $h.File.Substring($projDir.Length).TrimStart('\', '/') } else { $h.File }
    $tag = if ($h.Source -ne 'local') { "[$($h.Source.ToUpper())] " } else { '' }
    $dbg = if ($h.InDebug) { ' (#if DEBUG)' } else { '' }
    Write-Output ("{0}{1}:{2} [{3}/{4}] {5} | {6}{7}" -f $tag, $rel, $h.Line, $h.Severity, $h.Category, $h.Api, $h.Member, $dbg)
}
function Get-Rel([string]$p) { if ($p -and $p.StartsWith($projDir, [StringComparison]::OrdinalIgnoreCase)) { $p.Substring($projDir.Length).TrimStart('\', '/') } else { $p } }
Write-Output "--- online readiness ---"
Write-Output ("Framework: {0} [{1}] {2}" -f $fwInfo.Value, $fwInfo.Status, $fwInfo.Note)
Write-Output ("Signing:   [{0}] {1} {2}" -f $signing.Status, $signing.Note, $(if ($signing.KeyFile) { "($($signing.KeyFile))" } else { '' }))
Write-Output ("Version:   {0} - {1}" -f $versionInfo.Value, $versionInfo.Note)
Write-Output ("Entry points: {0} plug-in(s), {1} workflow activit(ies){2}" -f $plugins.Count, $workflows.Count, $(if ($workflows.Count) { ' -> plug-in packages NOT available; assembly must have no runtime dependencies' } else { '' }))
Write-Output ("Dependency candidates (confirm against the compiled DLL): {0}" -f $(if ($deps.Count) { ($deps | ForEach-Object { "$($_.Name) ($($_.Kind))" }) -join ', ' } else { 'none' }))
Write-Output "HTTP calls (file:line member call -> url source):"
foreach ($hc in $httpCalls) {
    $src = if ($hc.Url) { "$($hc.UrlSource) $($hc.Url) [$($hc.UrlClass): $($hc.UrlDetail)]" } else { "$($hc.UrlSource) $($hc.UrlKey)" }
    $via = if ($hc.Via) { " via $($hc.Via)" } else { '' }
    $lp = if ($hc.InLoop) { " (in loop @ line $($hc.LoopLine))" } else { '' }
    Write-Output ("  {0}:{1} {2} {3} -> {4}{5}{6}" -f (Get-Rel $hc.File), $hc.Line, $hc.Member, $hc.Call, $src, $via, $lp)
}
$flagged = @($urlLiterals | Where-Object { $_.Class -ne 'LooksPublic' })
Write-Output ("Hard-coded URLs: {0} ({1} flagged)" -f $urlLiterals.Count, $flagged.Count)
foreach ($ul in $flagged) { Write-Output ("  {0}:{1} {2} [{3}: {4}]" -f (Get-Rel $ul.File), $ul.Line, $ul.Url, $ul.Class, $ul.Detail) }
Write-Output ("Calls inside loops: {0}" -f $loopRisks.Count)
foreach ($lr in $loopRisks) { Write-Output ("  {0}:{1} {2} {3} (loop @ line {4})" -f (Get-Rel $lr.File), $lr.Line, $lr.Member, $lr.Call, $lr.LoopLine) }
Write-Output "JSON: $OutFile  ($($result.ElapsedSeconds)s)"
