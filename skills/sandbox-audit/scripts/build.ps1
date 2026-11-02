<#
.SYNOPSIS
    Builds a D365 plug-in / workflow activity project and inspects the compiled DLL.

.DESCRIPTION
    1. Finds MSBuild on any machine: vswhere (Visual Studio 2017+ / Build Tools), then PATH,
       then the dotnet CLI (SDK-style projects only).
    2. Restores NuGet packages (PackageReference and packages.config).
    3. Rebuilds the project (default: Release) and lists every compiler error.
    4. Inspects the compiled DLL: version, public key token (signed or not), size against the
       16 MB limit, referenced assemblies, and the runtime dependencies that are not part of
       .NET Framework or the CRM SDK.
    5. Writes everything to JSON (-OutFile) and prints a short summary. Exit code 0 = success.

    Use -InspectOnly -Dll <path> to inspect a DLL that was built some other way.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -Project "D:\Repo\Cs\My.Plugin" -OutFile "$env:TEMP\build.json"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File build.ps1 -InspectOnly -Dll "D:\Repo\Cs\My.Plugin\bin\Release\My.Plugin.dll"
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Configuration = 'Release',
    [string]$OutFile,
    [switch]$InspectOnly,
    [string]$Dll,
    [switch]$NoRestore
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$frameworkRefRx = '^(mscorlib|netstandard|System(\..+)?|Microsoft\.CSharp|Microsoft\.VisualBasic|WindowsBase|Microsoft\.Xrm\.Sdk(\..+)?|Microsoft\.Crm\.Sdk\.Proxy)$'

function Get-Size([long]$b) { if ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) } else { '{0:N0} KB' -f [math]::Ceiling($b / 1KB) } }

function Get-DllInfo([string]$path) {
    $an = [System.Reflection.AssemblyName]::GetAssemblyName($path)
    $tok = $an.GetPublicKeyToken()
    $tokHex = if ($tok -and $tok.Length) { -join ($tok | ForEach-Object { $_.ToString('x2') }) } else { '' }
    $refs = New-Object System.Collections.Generic.List[object]
    $method = $null
    try {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            $method = 'ReflectionOnlyLoadFrom'
            $asm = [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($path)
            foreach ($r in $asm.GetReferencedAssemblies()) { $refs.Add([pscustomobject]@{ Name = $r.Name; Version = $r.Version.ToString() }) }
        } else {
            $method = 'System.Reflection.Metadata'
            $fs = [IO.File]::OpenRead($path)
            try {
                $pe = New-Object System.Reflection.PortableExecutable.PEReader($fs)
                $md = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($pe)
                foreach ($h in $md.AssemblyReferences) {
                    $r = $md.GetAssemblyReference($h)
                    $refs.Add([pscustomobject]@{ Name = $md.GetString($r.Name); Version = $r.Version.ToString() })
                }
            } finally { $fs.Dispose() }
        }
    } catch { $method = "failed: $($_.Exception.Message)" }
    $size = (Get-Item -LiteralPath $path).Length
    $deps = @($refs | Where-Object { $_.Name -notmatch $frameworkRefRx })
    return [pscustomobject]@{
        Path = $path; SizeBytes = $size; Size = (Get-Size $size); WithinSizeLimit = ($size -le 16MB)
        Version = $an.Version.ToString(); PublicKeyToken = $tokHex; Signed = [bool]$tokHex
        References = $refs.ToArray(); RuntimeDependencies = $deps; ReferenceReadMethod = $method
    }
}

function Write-Result($result) {
    if ($OutFile) {
        $od = Split-Path -Parent $OutFile
        if ($od -and -not (Test-Path -LiteralPath $od)) { New-Item -ItemType Directory -Path $od | Out-Null }
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
    }
    $d = $result.Dll
    if ($d) {
        Write-Output ("DLL: {0}" -f $d.Path)
        Write-Output ("  Version {0} | {1} | {2}{3}" -f $d.Version, $(if ($d.Signed) { "signed ($($d.PublicKeyToken))" } else { 'NOT signed' }), $d.Size, $(if (-not $d.WithinSizeLimit) { ' - OVER the 16 MB limit' } else { '' }))
        Write-Output ("  Runtime dependencies (not .NET Framework / CRM SDK): {0}" -f $(if ($d.RuntimeDependencies.Count) { ($d.RuntimeDependencies | ForEach-Object { "$($_.Name) $($_.Version)" }) -join ', ' } else { 'none' }))
    }
    if ($OutFile) { Write-Output "JSON: $OutFile" }
}

# ---------------------------------------------------------------- inspect only
if ($InspectOnly) {
    if (-not $Dll -or -not (Test-Path -LiteralPath $Dll)) { throw "Pass -Dll with the path of an existing DLL" }
    $res = [pscustomobject]@{ Mode = 'inspect'; Success = $true; Dll = (Get-DllInfo (Resolve-Path -LiteralPath $Dll).Path) }
    Write-Result $res
    exit 0
}

# ---------------------------------------------------------------- project
if (-not $Project) { throw 'Pass -Project (a .csproj or its folder)' }
if (Test-Path -LiteralPath $Project -PathType Container) {
    $found = @(Get-ChildItem -LiteralPath $Project -Filter *.csproj -File)
    if ($found.Count -ne 1) { throw "Expected exactly one .csproj in $Project (found $($found.Count))" }
    $csproj = $found[0].FullName
} else { $csproj = (Resolve-Path -LiteralPath $Project).Path }
$projDir = Split-Path -Parent $csproj
[xml]$px = Get-Content -LiteralPath $csproj -Raw
$isSdk = [bool]$px.DocumentElement.GetAttribute('Sdk')
$asmName = @($px.SelectNodes("//*[local-name()='AssemblyName']") | Select-Object -First 1 | ForEach-Object { $_.InnerText })
$asmName = if ($asmName -and $asmName[0]) { $asmName[0] } else { [IO.Path]::GetFileNameWithoutExtension($csproj) }

# ---------------------------------------------------------------- find a builder
function Find-Builder {
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) {
        $vswhere = Join-Path $pf86 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (Test-Path -LiteralPath $vswhere) {
            $p = & $vswhere -latest -prerelease -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
            if ($p -and (Test-Path -LiteralPath $p)) { return [pscustomobject]@{ Kind = 'msbuild'; Path = $p; Source = 'vswhere' } }
        }
    }
    $cmd = Get-Command 'msbuild.exe', 'msbuild' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return [pscustomobject]@{ Kind = 'msbuild'; Path = $cmd.Source; Source = 'PATH' } }
    $dn = Get-Command 'dotnet' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($dn) { return [pscustomobject]@{ Kind = 'dotnet'; Path = $dn.Source; Source = 'PATH' } }
    return $null
}
$builder = Find-Builder
$errors = New-Object System.Collections.Generic.List[object]
$log = New-Object System.Collections.Generic.List[string]
$restore = [pscustomobject]@{ Ran = $false; Succeeded = $null }
$exit = 1

if (-not $builder) {
    $errors.Add([pscustomobject]@{ File = $null; Line = $null; Code = 'NO-MSBUILD'; Message = 'MSBuild was not found. Install Visual Studio or "Build Tools for Visual Studio" (workload: .NET desktop build tools), or put msbuild.exe on PATH.' })
} elseif ($builder.Kind -eq 'dotnet' -and -not $isSdk) {
    $errors.Add([pscustomobject]@{ File = $null; Line = $null; Code = 'NEEDS-MSBUILD'; Message = 'This is an old-style (non-SDK) .csproj, which the dotnet CLI cannot build. Install Visual Studio or Build Tools for Visual Studio.' })
} else {
    $common = @('/nologo', '/v:minimal', "/p:Configuration=$Configuration")
    if (-not $NoRestore) {
        $restore.Ran = $true
        $rArgs = @($csproj, '/t:Restore') + $common
        if (Test-Path -LiteralPath (Join-Path $projDir 'packages.config')) { $rArgs += '/p:RestorePackagesConfig=true' }
        if ($builder.Kind -eq 'dotnet') { $out = & $builder.Path restore $csproj 2>&1 } else { $out = & $builder.Path @rArgs 2>&1 }
        $restore.Succeeded = ($LASTEXITCODE -eq 0)
        foreach ($l in $out) { $log.Add([string]$l) }
    }
    if ($builder.Kind -eq 'dotnet') { $out = & $builder.Path build $csproj -c $Configuration --no-restore -nologo -v minimal 2>&1 }
    else { $out = & $builder.Path @(@($csproj, '/t:Rebuild', '/m') + $common) 2>&1 }
    $exit = $LASTEXITCODE
    $seen = @{}
    foreach ($l in $out) {
        $s = [string]$l; $log.Add($s)
        $m = [regex]::Match($s, '^\s*(?<file>[^(]+?)(?:\((?<line>\d+)(?:,\d+)?\))?\s*:\s*error\s+(?<code>[A-Z]+\d+)\s*:\s*(?<msg>.+?)(?:\s+\[[^\]]+\])?\s*$')
        if ($m.Success) {
            $key = "$($m.Groups['file'].Value)|$($m.Groups['line'].Value)|$($m.Groups['code'].Value)"
            if (-not $seen.ContainsKey($key)) { $seen[$key] = 1; $errors.Add([pscustomobject]@{ File = $m.Groups['file'].Value.Trim(); Line = $m.Groups['line'].Value; Code = $m.Groups['code'].Value; Message = $m.Groups['msg'].Value }) }
        }
    }
}
$warnCount = @($log | Where-Object { $_ -match ':\s*warning\s+[A-Z]+\d+' } | Sort-Object -Unique).Count
$success = ($exit -eq 0 -and $errors.Count -eq 0)

# ---------------------------------------------------------------- locate + inspect the DLL
$dllInfo = $null
if ($success) {
    $searchDirs = New-Object System.Collections.Generic.List[string]
    foreach ($pg in $px.SelectNodes("//*[local-name()='PropertyGroup']")) {
        $cond = $pg.GetAttribute('Condition')
        if ($cond -and $cond -notmatch [regex]::Escape($Configuration)) { continue }
        foreach ($op in $pg.ChildNodes) { if ($op.LocalName -eq 'OutputPath' -and $op.InnerText) { $searchDirs.Add([IO.Path]::GetFullPath((Join-Path $projDir ($op.InnerText -replace '[\\/]', [IO.Path]::DirectorySeparatorChar)))) } }
    }
    $searchDirs.Add((Join-Path $projDir (Join-Path 'bin' $Configuration)))
    $dllFile = $null
    foreach ($sd in $searchDirs) {
        if (-not (Test-Path -LiteralPath $sd)) { continue }
        $dllFile = Get-ChildItem -LiteralPath $sd -Recurse -Filter "$asmName.dll" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($dllFile) { break }
    }
    if ($dllFile) { $dllInfo = Get-DllInfo $dllFile.FullName }
}

$result = [pscustomobject]@{
    Mode = 'build'; Project = $csproj; Configuration = $Configuration; ProjectStyle = $(if ($isSdk) { 'sdk' } else { 'legacy' })
    Builder = $builder; Restore = $restore; Success = $success; ExitCode = $exit
    Errors = $errors.ToArray(); ErrorCount = $errors.Count; WarningCount = $warnCount
    Dll = $dllInfo; LogTail = @($log | Select-Object -Last 40); ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
Write-Output ("Build: {0} ({1} error(s), {2} warning(s)) using {3}{4}" -f $(if ($success) { 'SUCCEEDED' } else { 'FAILED' }), $errors.Count, $warnCount, $(if ($builder) { "$($builder.Kind) [$($builder.Source)] $($builder.Path)" } else { 'no builder found' }), $(if ($restore.Ran -and -not $restore.Succeeded) { ' - restore reported problems' } else { '' }))
foreach ($e in ($errors | Select-Object -First 30)) { Write-Output ("  {0}{1} {2}" -f $(if ($e.File) { "$($e.File)$(if ($e.Line) { "($($e.Line))" }): " } else { '' }), $e.Code, $e.Message) }
if ($success -and -not $dllInfo) { Write-Output "  Build succeeded but $asmName.dll was not found under the output folder - inspect it with -InspectOnly -Dll <path>" }
Write-Result $result
exit $(if ($success) { 0 } else { 1 })
