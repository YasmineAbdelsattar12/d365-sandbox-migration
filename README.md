# D365 Sandbox Migration Plugin

Fully automated tool that migrates Dynamics 365 CRM plugin and workflow activity projects from **Isolation Mode = None** (full trust) to **Sandbox** (partial trust) — and checks whether they are ready for **Dataverse Online** (on-prem → cloud).

Point it at your project → it scans every `.cs` file → fixes all violations → removes blocked references → builds Release → gives you a clean `.dll` ready for XrmToolBox.

## What It Does

1. **Scans** every compiled `.cs` file — local, linked (`<Link>`) and shared-project (`.projitems`) — with a bundled PowerShell scanner (`skills/sandbox-audit/scripts/scan.ps1`) that also shows which other projects link the same shared files
2. **Checks git** for uncommitted changes first, so each project's migration can be reviewed and reverted on its own
3. **Fixes** every live Sandbox violation in-place (blocked APIs, serializers, HTTP hardening) — shared files are only edited when a live call path is proven, and every project that links them is listed for rebuild
4. **Reuses one shared `AppSerializer`** across the solution (linked from your helper folder) instead of creating a copy per project
5. **Removes** blocked NuGet packages and assembly references (System.Web, Newtonsoft.Json, log4net, etc.)
6. **Adds** required references (System.Runtime.Serialization)
7. **Builds** the project in Release mode and fixes any build errors caused by the migration
8. **Checks Dataverse Online readiness** — every HTTP call and where its URL comes from (hard-coded, configuration record, workflow input, step config), IP/internal/`.local` addresses, Windows credentials, .NET Framework version, runtime DLL dependencies (plug-in packages don't support workflow activities), signing, assembly version, and service/HTTP calls inside loops
9. **Creates a PDF report** (optional — asked at the start and again at the end) for documentation: summary, every change with the real code diff, blocked APIs left in place with evidence, items for the team, references, Online Readiness tables, build details and a test checklist. Built with Microsoft Edge in the background — nothing to install
10. **Produces** a full summary — with an Online Readiness verdict (✅ / ⚠️ / ❌), what the team must do before go-live, what needs manual verification (JSON casing, date formats) and which projects to rebuild

## Changelog

- **1.4.2** — Author set to Yasmine Abdelsattar
- **1.4.1** — Ask for the project path as a plain chat question (a hand-made "Other" option in the question form had no text box)
- **1.4.0** — Optional PDF migration report (`scripts/make-report.ps1`): asked at the start and again at the end, saved in the repo (`docs\sandbox-migration`) or Documents, with git diff since the run's starting commit, rendered to PDF via headless Edge/Chrome
- **1.3.0** — Dataverse Online readiness: target environment choice; scanner traces every HTTP call's URL source and classifies hard-coded URLs (IP / internal / port / plain HTTP); detects plug-ins vs workflow activities, target framework, signing, assembly version, dependency candidates and calls inside loops; post-build DLL check (real dependencies, signature, version); new `online-checklist.md` (verified against Microsoft Learn and MC1515315); blocked-API list split into Blocked / Avoid and extended (IP URLs, Windows credentials, MemoryCache, `Settings.Default`); KeepAlive added to HTTP hardening; Newtonsoft and ILMerge guidance corrected
- **1.2.0** — Bundled scanner script; git safety check; shared-file rule (no silent edits to files linked by many projects); reuse a shared `AppSerializer`; `AppSerializer` date fix (`K` instead of literal `Z`, optional fractional seconds); case-sensitive `[DataMember(Name)]` guidance; keep `.Result` where code catches `AggregateException`; Visual Studio "Reload Project" note; README fixes
- **1.1.0** — Linked and shared-project files are always scanned
- **1.0.0** — Initial release

You get a clean Release build — just register it in XrmToolBox Plugin Registration Tool with Sandbox isolation mode.

## Installation

### Repository URL

```
https://github.com/YasmineAbdelsattar12/d365-sandbox-migration
```

### For GitHub Copilot and Codex (Visual Studio / VS Code)

1. **Agents → Plugins → Install Plugin From Source**
2. Paste the GitHub repository URL
3. Click **Install**

### For Claude Code

1. Use the `/plugin` command in Claude Code
2. Go to **Marketplaces → Add the GitHub repository → Plugins → Install**

### For Claude Desktop (Cowork)

1. Open **Settings → Plugins**
2. Click **Install Plugin** and select the `.plugin` file (or install from GitHub)

## Usage

After installation, type in the AI chat:

```
/d365-sandbox-migration:sandbox-audit
```

The tool will ask for your project path, then do everything automatically.

**Requirements**: Windows with Visual Studio / MSBuild (to build the project) and PowerShell 5.1+ (built into Windows — used by the bundled scanner script).

You can also say any of these:
- "Migrate this project to sandbox"
- "Audit for sandbox violations"
- "Convert from full trust to sandbox"
- "Fix sandbox violations in my plugin"

## Coverage

All Sandbox-blocked API categories:

- **File System** — File.*, Directory.*, FileStream, IsolatedStorage
- **Database** — SqlConnection, Entity Framework, ADO.NET
- **Configuration** — ConfigurationManager, Environment Variables
- **System.Web** — HttpUtility, MimeMapping, JavaScriptSerializer, HttpContext
- **Serialization** — Newtonsoft.Json (JsonConvert, JObject, attributes) → DataContractJsonSerializer
- **Networking** — FTP, SMTP, Sockets, WebSockets, Ping, localhost, non-80/443 ports
- **Threading** — Thread, Task.Run (fire-and-forget), Parallel, Timers
- **Process & OS** — Process.Start, Registry, EventLog, Environment
- **Interop** — DllImport, Marshal, COM, unsafe/fixed
- **Assembly & Reflection** — Assembly.Load, CSharpCodeProvider, Reflection.Emit
- **Graphics** — System.Drawing (GDI+), WPF media
- **Cryptography** — Key persistence, X509Store, DPAPI
- **XML** — DTD processing, XSL scripting
- **Logging** — log4net, NLog, Serilog → ITracingService
- **Caching** — MemoryCache / ObjectCache
- **Miscellaneous** — LDAP, WCF non-HTTP, WMI, VisualBasic
- **Dataverse Online** — no IP addresses or localhost, no Windows credentials, internal endpoints, .NET 4.6.2 / 4.8, ILMerge vs plug-in packages, signing, 16 MB, 2-minute limit

## What It Does NOT Change

- Code style, formatting, or naming
- Pre-existing bugs or performance issues
- Business logic
- Dead code (methods with zero callers from plugin code)
- Code in `#if DEBUG` blocks
- Anything that is not a Sandbox violation

## Author

**Yasmine Abdelsattar**
