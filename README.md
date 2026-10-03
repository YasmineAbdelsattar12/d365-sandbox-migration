# D365 Sandbox Migration Plugin

Fully automated tool that migrates Dynamics 365 CRM plugin and workflow activity projects from **Isolation Mode = None** (full trust) to **Sandbox** (partial trust).

Point it at your project → it scans every `.cs` file → fixes all violations → removes blocked references → builds Release → gives you a clean `.dll` ready for XrmToolBox.

## What It Does

1. **Scans** all `.cs` files in your plugin/workflow project
2. **Fixes** every Sandbox violation in-place (blocked APIs, serializers, HTTP hardening)
3. **Removes** blocked NuGet packages and assembly references (System.Web, Newtonsoft.Json, log4net, etc.)
4. **Adds** required references (System.Runtime.Serialization)
5. **Builds** the project in Release mode
6. **Fixes** any build errors caused by the migration
7. **Produces** a full summary of everything changed

You get a clean Release build — just register it in XrmToolBox Plugin Registration Tool with Sandbox isolation mode.

## Installation

### Repository URL

```
https://github.com/AhmedYassineMaalworked/d365-sandbox-migration
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
/sandbox-audit
```

The tool will ask for your project path, then do everything automatically.

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
- **Miscellaneous** — LDAP, WCF non-HTTP, WMI, VisualBasic

## What It Does NOT Change

- Code style, formatting, or naming
- Pre-existing bugs or performance issues
- Business logic
- Dead code (methods with zero callers from plugin code)
- Code in `#if DEBUG` blocks
- Anything that is not a Sandbox violation

## Author

**LinkDev**
