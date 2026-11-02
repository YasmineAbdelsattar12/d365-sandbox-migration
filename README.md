# D365 Sandbox Migration Plugin

Migrates Dynamics 365 / Dataverse plug-in and custom workflow activity projects from **Isolation Mode = None** (full trust) to **Sandbox** (partial trust), and checks whether they are ready for **Dataverse Online** (on-prem → cloud).

Point it at a project: it finds every compiled `.cs` file (including linked and shared files), fixes the Sandbox violations that actually run, removes blocked references, builds in Release, verifies the DLL, and tells you exactly what still blocks go-live — with an optional PDF report for documentation.

Built to work for **any team and any repository layout**: each team can describe its own conventions in one settings file.

## Quick start

1. **Install** (Claude Code): `/plugin` → **Marketplaces** → add `YasmineAbdelsattar12/d365-sandbox-migration` → **Plugins** → install **d365-sandbox-migration**. Other tools: see [Installation](#installation).
2. **First time in a repository** (one developer, once):
   ```
   /d365-sandbox-migration:sandbox-audit setup
   ```
   It looks at the whole repo, asks a few questions, writes `sandbox-audit.json` at the repo root and validates it. Commit / check it in so the whole team shares the same settings. (Optional — without it the skill uses defaults and detects what it can.)
3. **Migrate a project:**
   ```
   /d365-sandbox-migration:sandbox-audit
   ```
   Type the project path when asked (it suggests projects not yet migrated).

## Three modes

| Command | What happens | Changes code? |
|---|---|---|
| `/d365-sandbox-migration:sandbox-audit` | **Migrate** — scan, fix, build, verify, online readiness, summary, optional PDF | Yes |
| `/d365-sandbox-migration:sandbox-audit report` | **Report only** — the same analysis and summary, listing what *would* change. Good for estimating effort or a review with the tech lead | No |
| `/d365-sandbox-migration:sandbox-audit setup` | **Setup** — creates or updates `sandbox-audit.json` for the repository | No |

You can also just say "migrate this project to sandbox", "audit my plugins for sandbox", "is this project ready for Dataverse Online?".

## Team settings (`sandbox-audit.json`)

One optional file per repository. Everything in it is described in [`skills/sandbox-audit/references/config.md`](skills/sandbox-audit/references/config.md); ready-to-copy examples are in [`examples/`](examples/).

| Setting | Example | Why |
|---|---|---|
| `target` | `online` | Skip the "Online or on-prem?" question |
| `report` | `{ "enabled": true, "location": "repo" }` | Always create the PDF, in `docs/sandbox-migration` |
| `serializer` | `builtin`, or `existing` + your class files and call pattern | Use the team's own Sandbox-safe serializer everywhere, or the skill's builtin helper with your class name / namespace |
| `sharedHelperFolder` | `Shared/Crm.Common` | Where **every** shared helper file (serializer, MIME types, query strings, environment variables) is created once and linked from |
| `sharedHelperNamespace` | `Contoso.Crm.Common` | Namespace for new shared helper files |
| `skipProjects` | `["*.Api", "*.Portal", "*.Tests"]` | Never migrate or suggest full-trust projects |
| `http.timeoutSeconds` | `60` | Timeout put on outbound HTTP calls |
| `acceptedFindings` | `{ "file": "Shared/Logger.cs", "api": "EventLog", "reason": "..." }` | Findings the team reviewed and accepted — reported as *Accepted* (with the reason), not fixed |

Findings can also be accepted inline: `// sandbox-ignore: reason` on the same line or the line above.

## What it does

1. **Finds every compiled file** — local, linked (`<Link>`), wildcard and shared-project (`.projitems`) files, legacy and SDK-style projects — and shows which other projects link each shared file
2. **Checks version control first** (git or TFVC) so each project's migration can be reviewed and reverted on its own
3. **Fixes live violations only** — blocked APIs in methods nothing calls are left alone with evidence; shared files linked by many projects are never edited silently
4. **Serializers without changing the JSON** — `JavaScriptSerializer` / Newtonsoft → a Sandbox-safe `DataContractJsonSerializer` helper that keeps the same date format (`\/Date(...)\/` or ISO), uses the runtime type, and handles case-sensitive property names — or the team's own serializer from the settings
5. **Shared helpers, never copies** — fixes that need a helper (`MimeTypeHelper` for `MimeMapping`, `QueryStringHelper` for `HttpUtility.ParseQueryString`, `EnvironmentVariableHelper` for settings moved to Dataverse environment variables) use one shared file in the shared helper folder, reused or linked if it already exists, and behaving exactly like the API it replaces
6. **HTTP hardening** — TLS 1.2, timeout, KeepAlive off, `.GetAwaiter().GetResult()` (except where code relies on `AggregateException`), `InvalidPluginExecutionException`
7. **Cleans references and packages**, then **builds** with MSBuild found automatically on any machine (vswhere), and fixes build errors it caused
8. **Verifies the DLL** — real runtime dependencies, strong-name signature, 16 MB limit, assembly version change that would break the in-place update
9. **Dataverse Online readiness** — every HTTP call and where its URL comes from, IP / internal / `.local` addresses, Windows credentials, .NET Framework 4.6.2 / 4.8, dependencies (plug-in packages don't support workflow activities), calls inside loops (2-minute limit), with a ✅ / ⚠️ / ❌ verdict and a "before go-live" list
10. **Summary + optional PDF report** — every change with the real code diff, accepted findings, shared helper decisions, items to verify or decide, projects to rebuild, online readiness tables and a test checklist

## Requirements

- **Windows** with **PowerShell 5.1+** (built in)
- **Visual Studio 2017+** or **Build Tools for Visual Studio** (".NET desktop build tools") — the build script finds MSBuild itself
- **Microsoft Edge** or Chrome for the PDF report (Edge is on every Windows PC; without it you get the HTML report)
- **git** or **TFVC** recommended (works without version control, with a warning)

## Coverage

- **File System** — File.*, Directory.*, FileStream, IsolatedStorage
- **Database** — SqlConnection, Entity Framework, ADO.NET
- **Configuration** — ConfigurationManager, `app.config` / `Settings.Default`, environment variables
- **System.Web** — HttpUtility, MimeMapping, JavaScriptSerializer, HttpContext
- **Serialization** — Newtonsoft.Json (JsonConvert, JObject, attributes) → DataContractJsonSerializer
- **Networking** — FTP, SMTP, sockets, WebSockets, Ping, localhost, IP addresses, non-80/443 ports, Windows credentials
- **Threading** — Thread, Task.Run (fire-and-forget), Parallel, timers
- **Process & OS** — Process.Start, Registry, EventLog, Environment
- **Interop** — DllImport, Marshal, COM, unsafe/fixed
- **Assembly & Reflection** — Assembly.Load, CSharpCodeProvider, Reflection.Emit
- **Graphics** — System.Drawing (GDI+), WPF media
- **Cryptography** — key persistence, X509Store, DPAPI
- **XML** — DTD processing, XSL scripting
- **Logging** — log4net, NLog, Serilog → ITracingService
- **Caching** — MemoryCache / ObjectCache
- **Miscellaneous** — LDAP, WCF non-HTTP, WMI, VisualBasic
- **Dataverse Online** — internal endpoints, .NET version, ILMerge vs plug-in packages, signing, 16 MB, 2-minute limit

## What it does NOT change

- Code style, formatting, naming, business logic, error messages
- Pre-existing bugs or performance issues
- Dead code (methods with no live caller in the assembly), code in `#if DEBUG`
- Shared files without a proven live call path, or the team's own serializer class
- Endpoint URLs, authentication or loop design — these are reported for the team to decide
- Anything that is not a Sandbox violation

## Installation

Repository URL:

```
https://github.com/YasmineAbdelsattar12/d365-sandbox-migration
```

**Claude Code** — `/plugin` → **Marketplaces** → add the repository → **Plugins** → install. To update later: refresh the marketplace and update the plugin (if it says "no newer version", uninstall and install again).

**GitHub Copilot / Codex (Visual Studio / VS Code)** — **Agents → Plugins → Install Plugin From Source**, paste the repository URL, **Install**.

**Claude Desktop (Cowork)** — **Settings → Plugins → Install Plugin**, then select the `.plugin` file or install from GitHub.

## Changelog

- **1.7.3** — Report footer: "D365 Sandbox Migration tool created and owned by Yasmine Abdelsattar · © 2026. All rights reserved."
- **1.7.2** — Report footer shows only the copyright line
- **1.7.1** — Owner name shown once, in the PDF report footer
- **1.7.0** — Shared helpers for every fix that needs one, not only the serializer: `MimeTypeHelper`, `QueryStringHelper` (now a `NameValueCollection` exactly like `HttpUtility`, `+` as space) and `EnvironmentVariableHelper`, one file each in `sharedHelperFolder`, reused or linked if they exist; scanner finds and judges existing helpers anywhere in the solution; new `sharedHelperNamespace` setting; "Shared helper decisions" in the summary and PDF
- **1.6.2** — Setup writes plain JSON without comments (explanations go into `notes`), so Windows PowerShell 5.1 can read the settings file
- **1.6.1** — Owner shown on every PDF report (cover and footer) and in every script header
- **1.6.0** — For any team and project: per-repo settings file `sandbox-audit.json` (target, report, serializer strategy incl. the team's own class, shared helper folder, projects to skip, HTTP timeout, accepted findings) with validation; inline `// sandbox-ignore: reason`; **setup mode** (`-ListProjects` overview of the whole repo) and **report-only mode**; TFVC support (safety check, `tf diff` in the PDF); `build.ps1` finds MSBuild via vswhere, restores packages and inspects the DLL; project suggestions come from a real project scan; neutral examples; skill instructions split into reference files
- **1.5.1** — AppSerializer serializes the object's runtime type (`obj.GetType()`), like JavaScriptSerializer and Newtonsoft
- **1.5.0** — AppSerializer gets `JsonDateStyle` (`MsAjax` keeps JavaScriptSerializer's `\/Date(...)\/` dates and `"null"`); scanner judges every existing serializer (reusable / upgrade / not reusable, with reasons) and never modifies non-reusable ones; "Serializer decisions" section
- **1.4.2** — Author set to Yasmine Abdelsattar
- **1.4.1** — Project path asked as a plain chat question
- **1.4.0** — Optional PDF migration report with git diff, rendered via headless Edge/Chrome
- **1.3.0** — Dataverse Online readiness (URL sources, internal/IP URLs, framework, signing, version, dependencies, loops); Blocked / Avoid split; KeepAlive; Newtonsoft and ILMerge guidance corrected
- **1.2.0** — Bundled scanner; git safety check; shared-file rule; shared `AppSerializer`; date-format fix; case-sensitive `[DataMember(Name)]`; `.Result` / `AggregateException` rule
- **1.1.0** — Linked and shared-project files are always scanned
- **1.0.0** — Initial release

## Author

**Yasmine Abdelsattar**
