<#
.SYNOPSIS
    Reads the plug-in registrations from Dynamics 365 on-premises or Dataverse Online (read-only)
    and compares them with the source code in the repository.

.DESCRIPTION
    1. Connects to the organization:
         on-premises: Web API with your Windows login (default), or another account (credential
                      prompt), or the Microsoft.Xrm.Data.PowerShell login window (IFD / claims)
         Online:      the Microsoft.Xrm.Data.PowerShell login window (default), or an Azure CLI
                      token (az login already done)
       Nothing is written to the organization - only plug-in assemblies, plug-in types and steps are read.
    2. Lists every custom plug-in assembly: version, isolation mode (None / Sandbox), where it is
       stored (Database / Disk / GAC), plug-in and workflow activity classes, enabled / disabled steps.
    3. Compares with the repository (scan.ps1 -ListProjects): registered with source, registered
       without source, source not registered, version differences, class differences.
    4. Writes JSON (-OutFile) for the report and prints a summary.

    Passwords are never passed on the command line or stored. Compatible with Windows PowerShell 5.1
    and PowerShell 7+ (the login window option needs Windows PowerShell 5.1).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File crm-inventory.ps1 -Environment onprem -Url "https://crm.contoso.local/Contoso" -SolutionRoot "D:\Repo" -OutFile "$env:TEMP\crm-inventory.json"
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File crm-inventory.ps1 -Environment online -Url "https://contoso.crm4.dynamics.com" -Auth interactive -SolutionRoot "D:\Repo"
#>
[CmdletBinding()]
param(
    [string]$Environment,               # onprem | online
    [string]$Url,
    [string]$Auth,                      # windows | credential | interactive | azcli | token
    [string]$AccessToken,              # only with -Auth token (e.g. a pipeline); never typed into chat
    [string]$SolutionRoot,             # repository root - enables the source comparison
    [string]$ProjectsJson,             # output of scan.ps1 -ListProjects (skips re-scanning)
    [string]$Config,                   # sandbox-audit.json (default: <SolutionRoot>\sandbox-audit.json)
    [string]$OutFile,
    [string]$MockData                  # testing only: JSON with Assemblies / Types / Steps instead of connecting
)

$ErrorActionPreference = 'Stop'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
if (-not $OutFile) { $OutFile = Join-Path ([IO.Path]::GetTempPath()) 'crm-inventory.json' }
$isWin = [Environment]::OSVersion.Platform -eq 'Win32NT'

# ---------------------------------------------------------------- settings (crm section of sandbox-audit.json)
function Get-Prop($obj, [string]$name, $default) {
    if ($null -eq $obj) { return $default }
    $p = $obj.PSObject.Properties[$name]
    if ($p -and $null -ne $p.Value -and "$($p.Value)" -ne '') { return $p.Value } else { return $default }
}
if ($SolutionRoot) { $SolutionRoot = (Resolve-Path -LiteralPath $SolutionRoot).Path }
if (-not $Config -and $SolutionRoot -and (Test-Path -LiteralPath (Join-Path $SolutionRoot 'sandbox-audit.json'))) { $Config = Join-Path $SolutionRoot 'sandbox-audit.json' }
$cfg = $null
if ($Config -and (Test-Path -LiteralPath $Config)) { try { $cfg = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Warning "sandbox-audit.json could not be read: $($_.Exception.Message)" } }
$crmCfg = Get-Prop $cfg 'crm' $null
if (-not $Environment) { $Environment = [string](Get-Prop $crmCfg 'environment' '') }
if (-not $Url) { $Url = [string](Get-Prop $crmCfg 'url' '') }
if (-not $Auth) { $Auth = [string](Get-Prop $crmCfg 'auth' '') }
$skipProjects = @(Get-Prop $cfg 'skipProjects' @())

if (-not $MockData) {
    if ($Environment -notin @('onprem', 'online')) { throw 'Pass -Environment onprem or online (or set crm.environment in sandbox-audit.json)' }
    if (-not $Url) { throw 'Pass -Url with the organization address (or set crm.url in sandbox-audit.json)' }
    if ($Auth -and $Auth -notin @('windows', 'credential', 'interactive', 'azcli', 'token')) { throw "Unknown -Auth '$Auth' (windows, credential, interactive, azcli, token)" }
    if (-not $Auth) { $Auth = $(if ($Environment -eq 'onprem') { 'windows' } else { 'interactive' }) }
    if ($Environment -eq 'online' -and $Auth -in @('windows', 'credential')) { throw "Auth '$Auth' does not work with Dataverse Online - use interactive or azcli" }
    $Url = $Url.TrimEnd('/')
    if ($Url -notmatch '^https?://') { $Url = 'https://' + $Url }
}

# ---------------------------------------------------------------- data access
$isoNames = @{ 1 = 'None'; 2 = 'Sandbox'; 3 = 'External' }
$srcNames = @{ 0 = 'Database'; 1 = 'Disk'; 2 = 'GAC'; 3 = 'AzureWebApp'; 4 = 'FileStore' }
$apiVersion = if ($Environment -eq 'online') { 'v9.2' } else { 'v9.0' }
$script:cred = $null; $script:token = $null; $script:conn = $null

function Get-ErrorHint([string]$msg) {
    if ($msg -match 'proxy') { return 'A proxy server blocked the request - check the proxy / VPN settings of this machine, or run from a machine on the company network.' }
    if ($msg -match '401|Unauthorized') { return 'Login was rejected - check the account has access to this organization, or try another sign-in option.' }
    if ($msg -match '403|Forbidden|privilege') { return 'Signed in, but the account cannot read plug-in registrations - it needs e.g. the System Customizer or System Administrator role.' }
    if ($msg -match '404|Not Found') { return 'Address not found - check the organization URL (on-premises usually https://<server>/<OrgName>).' }
    if ($msg -match 'SSL|TLS|trust relationship|certificate') { return 'The server certificate is not trusted by this machine - open the URL in a browser on this machine and ask IT to install the certificate. The skill never turns certificate checks off.' }
    if ($msg -match 'remote name could not be resolved|No such host|NameResolution') { return 'Server name not found - check the URL and that this machine is on the company network / VPN.' }
    if ($msg -match 'Unable to connect|timed out|actively refused') { return 'Could not reach the server - check network / VPN and the URL.' }
    return $null
}

function Invoke-WebApiAll([string]$relative) {
    $next = "$Url/api/data/$apiVersion/$relative"
    $all = New-Object System.Collections.Generic.List[object]
    $headers = @{ 'Accept' = 'application/json'; 'OData-MaxVersion' = '4.0'; 'OData-Version' = '4.0'; 'Prefer' = 'odata.maxpagesize=5000' }
    if ($script:token) { $headers['Authorization'] = "Bearer $($script:token)" }
    while ($next) {
        $p = @{ Uri = $next; Headers = $headers; Method = 'Get' }
        if ($Auth -eq 'windows') { $p.UseDefaultCredentials = $true }
        if ($Auth -eq 'credential') { $p.Credential = $script:cred }
        if ($PSVersionTable.PSEdition -ne 'Core') { $p.UseBasicParsing = $true }
        $r = Invoke-RestMethod @p
        foreach ($v in @($r.value)) { $all.Add($v) }
        $nl = $r.PSObject.Properties['@odata.nextLink']
        $next = if ($nl) { $nl.Value } else { $null }
    }
    return , $all
}

function Invoke-FetchAll([string]$entity, [string[]]$attrs, [string]$filterXml) {
    $all = New-Object System.Collections.Generic.List[object]
    $page = 1; $cookie = $null
    do {
        $cookieAttr = if ($cookie) { ' paging-cookie="' + [System.Security.SecurityElement]::Escape($cookie) + '"' } else { '' }
        $xml = "<fetch page=""$page"" count=""5000""$cookieAttr><entity name=""$entity"">" + (($attrs | ForEach-Object { "<attribute name=""$_"" />" }) -join '') + $filterXml + '</entity></fetch>'
        $res = $script:conn.RetrieveMultiple((New-Object Microsoft.Xrm.Sdk.Query.FetchExpression($xml)))
        foreach ($e in $res.Entities) {
            $o = [ordered]@{}
            foreach ($a in $attrs) {
                $v = $null
                if ($e.Attributes.Contains($a)) {
                    $v = $e.Attributes[$a]
                    if ($v -is [Microsoft.Xrm.Sdk.OptionSetValue]) { $v = $v.Value }
                    elseif ($v -is [Microsoft.Xrm.Sdk.EntityReference]) { $v = $v.Id.ToString() }
                    elseif ($v -is [guid]) { $v = $v.ToString() }
                }
                $key = if ($a -in @('pluginassemblyid', 'eventhandler', 'plugintypeid') -and $entity -ne ($a -replace 'id$', '')) { "_$($a)_value" } else { $a }
                $o[$key] = $v
            }
            $all.Add([pscustomobject]$o)
        }
        $page++; $cookie = $res.PagingCookie
    } while ($res.MoreRecords)
    return , $all
}

$assembliesRaw = $null; $typesRaw = $null; $stepsRaw = $null
$connected = $false; $connError = $null; $connHint = $null; $method = $null; $who = $null
try {
    if ($MockData) {
        $m = Get-Content -LiteralPath $MockData -Raw -Encoding UTF8 | ConvertFrom-Json
        $assembliesRaw = @($m.Assemblies); $typesRaw = @($m.Types); $stepsRaw = @($m.Steps)
        $method = 'mock data (testing)'; $connected = $true
        if (-not $Environment) { $Environment = [string](Get-Prop $m 'Environment' 'onprem') }
        if (-not $Url) { $Url = [string](Get-Prop $m 'Url' 'https://mock') }
    } elseif ($Auth -eq 'interactive') {
        if (-not $isWin -or $PSVersionTable.PSEdition -eq 'Core') { throw 'The login window option needs Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.' }
        if (-not (Get-Module -ListAvailable -Name Microsoft.Xrm.Data.PowerShell)) { throw 'MODULE-MISSING: Microsoft.Xrm.Data.PowerShell is not installed. Install it once with: Install-Module Microsoft.Xrm.Data.PowerShell -Scope CurrentUser' }
        Import-Module Microsoft.Xrm.Data.PowerShell -ErrorAction Stop
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($Environment -eq 'online') { $script:conn = Connect-CrmOnline -ServerUrl $Url -ForceOAuth }
        else { $script:conn = Get-CrmConnection -InteractiveMode }
        if (-not $script:conn -or -not $script:conn.IsReady) { throw "Login did not complete: $($script:conn.LastCrmError)" }
        $method = 'Microsoft.Xrm.Data.PowerShell login window'
        $who = "$($script:conn.ConnectedOrgFriendlyName)"
        $assembliesRaw = Invoke-FetchAll 'pluginassembly' @('pluginassemblyid', 'name', 'version', 'publickeytoken', 'culture', 'isolationmode', 'sourcetype', 'ismanaged', 'modifiedon') '<filter><condition attribute="customizationlevel" operator="eq" value="1" /></filter>'
        $typesRaw = Invoke-FetchAll 'plugintype' @('plugintypeid', 'typename', 'isworkflowactivity', 'pluginassemblyid') '<filter><condition attribute="customizationlevel" operator="eq" value="1" /></filter>'
        $stepsRaw = Invoke-FetchAll 'sdkmessageprocessingstep' @('sdkmessageprocessingstepid', 'name', 'statecode', 'mode', 'stage', 'eventhandler') '<filter><condition attribute="customizationlevel" operator="eq" value="1" /></filter>'
        $connected = $true
    } else {
        if ($PSVersionTable.PSEdition -ne 'Core') { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }
        switch ($Auth) {
            'windows'    { $method = "Web API $apiVersion with your Windows login" }
            'credential' { $script:cred = Get-Credential -Message "Account for $Url (DOMAIN\user)"; if (-not $script:cred) { throw 'No account entered' }; $method = "Web API $apiVersion with account $($script:cred.UserName)" }
            'azcli' {
                $az = Get-Command az -ErrorAction SilentlyContinue
                if (-not $az) { throw 'Azure CLI (az) is not installed - use the login window option instead.' }
                $resource = ([Uri]$Url).GetLeftPart([UriPartial]::Authority)
                $script:token = (& az account get-access-token --resource $resource --query accessToken -o tsv 2>&1 | Select-Object -Last 1)
                if (-not $script:token -or $script:token -match 'ERROR|az login') { throw "Azure CLI could not get a token - run 'az login' first. $($script:token)" }
                $method = "Web API $apiVersion with an Azure CLI token"
            }
            'token' { if (-not $AccessToken) { throw '-Auth token needs -AccessToken' }; $script:token = $AccessToken; $method = "Web API $apiVersion with a bearer token" }
        }
        try { $whoAmI = Invoke-WebApiAll 'WhoAmI'; $who = 'connected' } catch { $whoAmI = $null }
        $assembliesRaw = Invoke-WebApiAll 'pluginassemblies?$select=pluginassemblyid,name,version,publickeytoken,culture,isolationmode,sourcetype,ismanaged,modifiedon&$filter=customizationlevel eq 1'
        try { $typesRaw = Invoke-WebApiAll 'plugintypes?$select=plugintypeid,typename,isworkflowactivity,_pluginassemblyid_value&$filter=customizationlevel eq 1' }
        catch { $typesRaw = Invoke-WebApiAll 'plugintypes?$select=plugintypeid,typename,isworkflowactivity,_pluginassemblyid_value' }
        try { $stepsRaw = Invoke-WebApiAll 'sdkmessageprocessingsteps?$select=sdkmessageprocessingstepid,name,statecode,mode,stage,_eventhandler_value&$filter=customizationlevel eq 1' }
        catch { $stepsRaw = Invoke-WebApiAll 'sdkmessageprocessingsteps?$select=sdkmessageprocessingstepid,name,statecode,mode,stage,_plugintypeid_value&$filter=customizationlevel eq 1' }
        $connected = $true
    }
} catch {
    $connError = $_.Exception.Message
    $connHint = Get-ErrorHint $connError
}

# ---------------------------------------------------------------- normalize CRM data
function P($o, $n) { $p = $o.PSObject.Properties[$n]; if ($p) { $p.Value } else { $null } }
$assemblies = New-Object System.Collections.Generic.List[object]
if ($connected) {
    $typesByAsm = @{}
    foreach ($t in $typesRaw) {
        $aid = [string](P $t '_pluginassemblyid_value')
        if (-not $typesByAsm.ContainsKey($aid)) { $typesByAsm[$aid] = New-Object System.Collections.Generic.List[object] }
        $typesByAsm[$aid].Add($t)
    }
    $stepsByType = @{}
    foreach ($st in $stepsRaw) {
        $tid = [string](P $st '_eventhandler_value'); if (-not $tid) { $tid = [string](P $st '_plugintypeid_value') }
        if (-not $tid) { continue }
        if (-not $stepsByType.ContainsKey($tid)) { $stepsByType[$tid] = New-Object System.Collections.Generic.List[object] }
        $stepsByType[$tid].Add($st)
    }
    foreach ($a in $assembliesRaw) {
        $id = [string](P $a 'pluginassemblyid')
        $types = @(); if ($typesByAsm.ContainsKey($id)) { $types = $typesByAsm[$id].ToArray() }
        $enabled = 0; $disabled = 0
        foreach ($t in $types) {
            $tid = [string](P $t 'plugintypeid')
            if ($stepsByType.ContainsKey($tid)) { foreach ($st in $stepsByType[$tid]) { if ([int](P $st 'statecode') -eq 0) { $enabled++ } else { $disabled++ } } }
        }
        $iso = [int](P $a 'isolationmode'); $src = [int](P $a 'sourcetype')
        $assemblies.Add([pscustomobject]@{
            Id = $id; Name = [string](P $a 'name'); Version = [string](P $a 'version'); PublicKeyToken = [string](P $a 'publickeytoken')
            IsolationMode = $iso; Isolation = $(if ($isoNames.ContainsKey($iso)) { $isoNames[$iso] } else { "Unknown ($iso)" })
            SourceType = $src; Source = $(if ($srcNames.ContainsKey($src)) { $srcNames[$src] } else { "Unknown ($src)" })
            IsManaged = [bool](P $a 'ismanaged'); ModifiedOn = [string](P $a 'modifiedon')
            PluginTypes = @($types | Where-Object { -not [bool](P $_ 'isworkflowactivity') } | ForEach-Object { [string](P $_ 'typename') } | Sort-Object)
            WorkflowActivities = @($types | Where-Object { [bool](P $_ 'isworkflowactivity') } | ForEach-Object { [string](P $_ 'typename') } | Sort-Object)
            StepsEnabled = $enabled; StepsDisabled = $disabled
            Match = 'none'; MatchedProjects = @(); SourceVersion = $null; VersionDiff = $null
            ClassesNotInCode = @(); ClassesNotRegistered = @(); Notes = @(); Status = $null
        })
    }
}

# ---------------------------------------------------------------- source projects
$projects = @()
$projError = $null
if ($ProjectsJson -and (Test-Path -LiteralPath $ProjectsJson)) {
    $projects = @((Get-Content -LiteralPath $ProjectsJson -Raw -Encoding UTF8 | ConvertFrom-Json).Projects)
} elseif ($SolutionRoot) {
    $listOut = Join-Path ([IO.Path]::GetTempPath()) ('sandbox-projects-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $scanArgs = @{ ListProjects = $true; SolutionRoot = $SolutionRoot; OutFile = $listOut }
        if ($Config) { $scanArgs.Config = $Config }
        & (Join-Path $PSScriptRoot 'scan.ps1') @scanArgs | Out-Null
        $projects = @((Get-Content -LiteralPath $listOut -Raw -Encoding UTF8 | ConvertFrom-Json).Projects)
    } catch { $projError = $_.Exception.Message }
}

# ---------------------------------------------------------------- compare
$notRegistered = New-Object System.Collections.Generic.List[object]
if ($connected -and $projects.Count) {
    $byName = @{}; $byType = @{}
    foreach ($p in $projects) {
        $k = ([string]$p.AssemblyName).ToLowerInvariant()
        if (-not $byName.ContainsKey($k)) { $byName[$k] = New-Object System.Collections.Generic.List[object] }
        $byName[$k].Add($p)
        foreach ($t in @($p.EntryTypes)) { $tk = ([string]$t).ToLowerInvariant(); if (-not $byType.ContainsKey($tk)) { $byType[$tk] = New-Object System.Collections.Generic.List[object] }; $byType[$tk].Add($p) }
    }
    $matchedProjectPaths = @{}
    foreach ($a in $assemblies) {
        $regTypes = @($a.PluginTypes) + @($a.WorkflowActivities)
        $cands = @()
        $k = $a.Name.ToLowerInvariant()
        if ($byName.ContainsKey($k)) { $cands = $byName[$k].ToArray(); $a.Match = 'assembly name' }
        else {
            $hits = @{}
            foreach ($t in $regTypes) { $tk = $t.ToLowerInvariant(); if ($byType.ContainsKey($tk)) { foreach ($p in $byType[$tk]) { $hits[$p.FullPath] = $p } } }
            if ($hits.Count) { $cands = @($hits.Values); $a.Match = 'class names (assembly name differs)' }
        }
        if (-not $cands.Count) { continue }
        $a.MatchedProjects = @($cands | ForEach-Object { $_.Path })
        foreach ($c in $cands) { $matchedProjectPaths[$c.FullPath] = $true }
        if ($cands.Count -gt 1) { $a.Notes += "$($cands.Count) projects build an assembly with this name - check which one is deployed" }
        $p = $cands[0]
        $a.SourceVersion = $p.AssemblyVersion
        if ($p.AssemblyVersion -and $a.Version -and $p.AssemblyVersion -ne $a.Version) {
            $rv = $a.Version.Split('.'); $sv = ([string]$p.AssemblyVersion).Split('.')
            $a.VersionDiff = $(if ($rv[0] -ne $sv[0] -or ($rv.Length -gt 1 -and $sv.Length -gt 1 -and $rv[1] -ne $sv[1])) { 'major/minor differs - the Plugin Registration Tool will treat the new build as a different assembly' } else { 'build/revision differs - code changed after the last deployment, or not deployed yet' })
        }
        $code = @($p.EntryTypes | ForEach-Object { ([string]$_).ToLowerInvariant() })
        $reg = @($regTypes | ForEach-Object { $_.ToLowerInvariant() })
        $a.ClassesNotInCode = @($regTypes | Where-Object { $code -notcontains $_.ToLowerInvariant() })
        $a.ClassesNotRegistered = @($p.EntryTypes | Where-Object { $reg -notcontains ([string]$_).ToLowerInvariant() })
    }
    foreach ($p in $projects) {
        if ($p.Kind -eq 'Other' -or $matchedProjectPaths.ContainsKey($p.FullPath)) { continue }
        if (@($skipProjects | Where-Object { $p.Name -like $_ }).Count) { continue }
        $notRegistered.Add([pscustomobject]@{ Name = $p.Name; Path = $p.Path; AssemblyName = $p.AssemblyName; Kind = $p.Kind; EntryTypes = @($p.EntryTypes); Hint = $p.Hint })
    }
}

# ---------------------------------------------------------------- status per assembly
foreach ($a in $assemblies) {
    $issues = New-Object System.Collections.Generic.List[string]
    if ($a.IsolationMode -eq 1) { $issues.Add('Isolation None - needs Sandbox migration') }
    if ($a.SourceType -in @(1, 2)) { $issues.Add("Stored on $($a.Source) - must be registered in the Database for Online / Sandbox") }
    if ($projects.Count -and $a.Match -eq 'none') { $issues.Add($(if ($a.IsManaged) { 'No source in this repository - from a managed solution (Microsoft, ISV or another team)' } else { 'No source code found in this repository' })) }
    if ($a.Match -like 'class names*') { $issues.Add("Matched by class names - the project builds a different assembly name ($(@($a.MatchedProjects) -join ', '))") }
    if ($a.VersionDiff) { $issues.Add("Version $($a.Version) in CRM vs $($a.SourceVersion) in code - $($a.VersionDiff)") }
    if (@($a.ClassesNotInCode).Count) { $issues.Add("Registered but not in the code: $(@($a.ClassesNotInCode) -join ', ')") }
    if (@($a.ClassesNotRegistered).Count) { $issues.Add("In the code but not registered: $(@($a.ClassesNotRegistered) -join ', ')") }
    if (($a.StepsEnabled + $a.StepsDisabled) -eq 0 -and -not @($a.WorkflowActivities).Count) { $issues.Add('No steps and no workflow activities - possibly unused') }
    elseif ($a.StepsEnabled -eq 0 -and $a.StepsDisabled -gt 0 -and -not @($a.WorkflowActivities).Count) { $issues.Add('All steps disabled - possibly unused') }
    $a.Notes = @($a.Notes) + @($issues)
    $a.Status = if ($a.IsolationMode -eq 2 -and $a.SourceType -eq 0) { 'Sandbox' } elseif ($a.IsolationMode -eq 2) { 'Sandbox (not in Database)' } elseif ($a.IsolationMode -eq 1) { 'Needs migration' } else { $a.Isolation }
}

# ---------------------------------------------------------------- output
$list = @($assemblies | Sort-Object @{ Expression = { if ($_.IsolationMode -eq 1) { 0 } else { 1 } } }, Name)
$counts = [pscustomobject]@{
    Assemblies = $list.Count
    IsolationNone = @($list | Where-Object { $_.IsolationMode -eq 1 }).Count
    Sandbox = @($list | Where-Object { $_.IsolationMode -eq 2 }).Count
    External = @($list | Where-Object { $_.IsolationMode -eq 3 }).Count
    Database = @($list | Where-Object { $_.SourceType -eq 0 }).Count
    DiskOrGac = @($list | Where-Object { $_.SourceType -in @(1, 2) }).Count
    Managed = @($list | Where-Object { $_.IsManaged }).Count
    PluginTypes = (@($list | ForEach-Object { @($_.PluginTypes).Count }) | Measure-Object -Sum).Sum
    WorkflowActivities = (@($list | ForEach-Object { @($_.WorkflowActivities).Count }) | Measure-Object -Sum).Sum
    StepsEnabled = (@($list | ForEach-Object { $_.StepsEnabled }) | Measure-Object -Sum).Sum
    StepsDisabled = (@($list | ForEach-Object { $_.StepsDisabled }) | Measure-Object -Sum).Sum
    SourceProjects = $projects.Count
    WithSource = @($list | Where-Object { $_.Match -ne 'none' }).Count
    WithoutSource = $(if ($projects.Count) { @($list | Where-Object { $_.Match -eq 'none' }).Count } else { $null })
    NotRegistered = $notRegistered.Count
    VersionDifferences = @($list | Where-Object { $_.VersionDiff }).Count
    ClassDifferences = @($list | Where-Object { @($_.ClassesNotInCode).Count -or @($_.ClassesNotRegistered).Count }).Count
    Own = @($list | Where-Object { -not ($_.IsManaged -and $_.Match -eq 'none') }).Count
    OwnIsolationNone = @($list | Where-Object { -not ($_.IsManaged -and $_.Match -eq 'none') -and $_.IsolationMode -eq 1 }).Count
    OwnSandbox = @($list | Where-Object { -not ($_.IsManaged -and $_.Match -eq 'none') -and $_.IsolationMode -eq 2 }).Count
    Vendor = @($list | Where-Object { $_.IsManaged -and $_.Match -eq 'none' }).Count
    VendorIsolationNone = @($list | Where-Object { $_.IsManaged -and $_.Match -eq 'none' -and $_.IsolationMode -eq 1 }).Count
    WithoutSourceUnmanaged = $(if ($projects.Count) { @($list | Where-Object { $_.Match -eq 'none' -and -not $_.IsManaged }).Count } else { $null })
    PossiblyUnused = @($list | Where-Object { @($_.Notes) -match 'possibly unused' }).Count
}
$result = [pscustomobject]@{
    Mode = 'crm-inventory'; Generated = (Get-Date).ToString('s'); Environment = $Environment; Url = $Url; Auth = $Auth; Method = $method
    Connected = $connected; Error = $connError; ErrorHint = $connHint; SolutionRoot = $SolutionRoot; ProjectScanError = $projError
    Counts = $counts; Assemblies = $list; NotRegistered = $notRegistered.ToArray()
    ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
}
$od = Split-Path -Parent $OutFile; if ($od -and -not (Test-Path -LiteralPath $od)) { New-Item -ItemType Directory -Path $od | Out-Null }
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8

if (-not $connected) {
    Write-Output "CRM connection FAILED ($Environment, $Url, auth: $Auth)"
    Write-Output "  Error: $connError"
    if ($connHint) { Write-Output "  Hint:  $connHint" }
    Write-Output "JSON: $OutFile"
    exit 1
}
$c = $counts
Write-Output ("CRM: {0} ({1}) via {2}" -f $Url, $Environment, $method)
Write-Output ("Custom plug-in assemblies: {0} - {1} isolation None, {2} Sandbox{3} | stored: {4} Database, {5} Disk/GAC | {6} from managed solutions" -f $c.Assemblies, $c.IsolationNone, $c.Sandbox, $(if ($c.External) { ", $($c.External) External" } else { '' }), $c.Database, $c.DiskOrGac, $c.Managed)
Write-Output ("Classes: {0} plug-ins, {1} workflow activities | steps: {2} enabled, {3} disabled" -f $c.PluginTypes, $c.WorkflowActivities, $c.StepsEnabled, $c.StepsDisabled)
Write-Output ("Your team's assemblies: {0} - {1} isolation None, {2} Sandbox | Microsoft / vendor (managed, no source here): {3} - {4} isolation None" -f $c.Own, $c.OwnIsolationNone, $c.OwnSandbox, $c.Vendor, $c.VendorIsolationNone)
if ($projects.Count) { Write-Output ("Source ({0} projects): {1} with source, {2} of your assemblies without source, {3} projects not registered, {4} version differences, {5} class differences" -f $c.SourceProjects, $c.WithSource, $c.WithoutSourceUnmanaged, $c.NotRegistered, $c.VersionDifferences, $c.ClassDifferences) }
elseif ($projError) { Write-Output "Source comparison skipped: $projError" }
else { Write-Output 'Source comparison skipped (pass -SolutionRoot)' }
Write-Output '--- your assemblies (Microsoft / vendor managed ones are in the JSON only) ---'
foreach ($a in @($list | Where-Object { -not ($_.IsManaged -and $_.Match -eq 'none') })) {
    Write-Output ("  [{0}] {1} {2} ({3}; {4} plug-ins, {5} activities; steps {6}/{7}){8}" -f $a.Isolation, $a.Name, $a.Version, $a.Source, @($a.PluginTypes).Count, @($a.WorkflowActivities).Count, $a.StepsEnabled, ($a.StepsEnabled + $a.StepsDisabled), $(if ($a.MatchedProjects.Count) { ' -> ' + ($a.MatchedProjects -join ', ') } else { '' }))
    foreach ($n in $a.Notes) { if ($n -notmatch '^Isolation None') { Write-Output "      - $n" } }
}
if ($notRegistered.Count) {
    Write-Output '--- source projects not registered in this organization ---'
    foreach ($p in $notRegistered) { Write-Output ("  {0} ({1}, assembly {2})" -f $p.Path, $p.Kind, $p.AssemblyName) }
}
Write-Output "JSON: $OutFile  ($($result.ElapsedSeconds)s)"
