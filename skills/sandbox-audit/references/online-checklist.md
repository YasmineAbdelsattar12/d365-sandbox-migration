# Dataverse Online Readiness Checklist

Use when the target environment is **Dataverse / Dynamics 365 Online**. Online runs every plug-in and custom workflow activity in Sandbox, so everything in `blocked-apis.md` applies — plus the items below, which are about the environment around the code, not just the code.

Sources (Microsoft Learn): "Access external web services", "Build and package plug-in code", and Message Center MC1515315 (.NET Framework 4.8 support).

## Status Icons

| Icon | Meaning |
|---|---|
| ✅ | Ready |
| ⚠️ | Needs a check or a change by the team before go-live |
| ❌ | Will not work online until redesigned / changed |

## 1. Network Access (most common blocker)

Microsoft's documented rules for sandboxed web access:

| Rule | Online result if broken |
|---|---|
| Only `http` / `https` | ❌ |
| No `localhost` / `127.0.0.1` | ❌ |
| **No IP addresses** — must be a named address that needs DNS resolution | ❌ (even public IPs) |
| Anonymous authentication only — no Windows credentials (`UseDefaultCredentials`, `CredentialCache.DefaultCredentials`, NTLM/Kerberos to internal services) | ❌ |
| The target server must accept connections from the Power Platform outbound IPs (`PowerPlatformPlex` service tag) | ⚠️ firewall rule needed |
| Current TLS / cipher suites on the target server | ⚠️ |
| Non-80/443 ports | ⚠️ not documented — may be blocked by firewalls; prefer 443 |

**Internal endpoints.** Microsoft's cloud cannot reach a company's internal network. A URL that works today because the on-prem CRM server sits inside the network will fail online, even though the code is Sandbox-safe. Typical internal signs:

- Private IPs: `10.x.x.x`, `172.16–31.x.x`, `192.168.x.x`
- Single-label host names: `http://crmapp01/`, `http://fileserver/`
- Internal suffixes: `.local`, `.lan`, `.corp`, `.internal`, `.intranet`, `.ad`
- Company domain names that only resolve inside the network (cannot be detected from code — the team must confirm)

**Fixes for internal endpoints** (team decision, not a code change the skill makes):
- Publish the API publicly behind Azure API Management / Application Gateway, with authentication (API key / OAuth client credentials)
- Azure Relay hybrid connections
- Move the logic into an Azure Function / Power Automate flow that can reach the internal system through a supported connector or gateway

**URLs that come from configuration** (CRM configuration entity, environment variable, plug-in step config, workflow input argument) cannot be judged from code — list the **key name** and where it is read, and mark ⚠️ "confirm the value is a public DNS name".

## 2. HTTP Hardening Additions for Online

In addition to the hardening rules in `code-patterns.md`:

- **Disable KeepAlive** (Microsoft guidance for sandboxed calls):
  - `HttpWebRequest`: `request.KeepAlive = false;`
  - `HttpClient`: `client.DefaultRequestHeaders.ConnectionClose = true;`
- Set an explicit `Timeout` on every call (Microsoft's sample uses 15 s; never above 90 s — the whole plug-in execution is limited to 2 minutes).

## 3. .NET Framework Target

| Project targets | Status |
|---|---|
| 4.6.2 | ✅ |
| 4.8 | ✅ only if the environment runs service update **9.2.26092** or later (rolling out from 26 Oct 2026, MC1515315). Otherwise ⚠️ — check **Settings → About** in the environment, or retarget to 4.6.2 |
| 4.7 / 4.7.1 / 4.7.2 | ⚠️ not named by Microsoft — retarget to 4.6.2 (or 4.8 once supported) |
| 4.8.1 or later | ❌ unsupported |
| Below 4.6.2 | ⚠️ current CRM SDK packages need 4.6.2 — retarget |

## 4. Dependent Assemblies (DLLs the plug-in needs at runtime)

- **ILMerge is not supported** by Microsoft.
- The supported replacement is **plug-in packages** (dependent assemblies). Limits:
  - **Custom workflow activities are NOT supported** in plug-in packages
  - Not available on-premises
  - No unmanaged code
- Therefore:

| Assembly contains | Runtime dependency on a non-framework, non-SDK DLL | Status |
|---|---|---|
| Plug-ins only | none | ✅ |
| Plug-ins only | yes | ⚠️ move to a plug-in package (or remove the dependency) |
| Any custom workflow activity | none | ✅ |
| Any custom workflow activity | yes | ❌ cannot use a package — remove the dependency: compile the needed source in (linked files) or split the workflow activities into their own assembly without the dependency |

"Runtime dependency" = the **compiled DLL** references it (check after build with the referenced-assembly list), not just a `<Reference>` in the `.csproj`. Linked source files compile into the assembly and are not dependencies.

Framework assemblies (`mscorlib`, `System.*` that ship with .NET Framework) and the SDK (`Microsoft.Xrm.Sdk`, `Microsoft.Xrm.Sdk.Workflow`, `Microsoft.Crm.Sdk.Proxy`) are fine.

## 5. Signing, Size, Version

| Check | Rule |
|---|---|
| Signing | Assemblies registered on their own (not via a plug-in package) **must be strong-name signed**. If you sign an assembly, everything it depends on must be signed too |
| Size | ≤ 16 MB |
| Version | Keep major.minor the same as the registered assembly and change only build/revision, so the Plugin Registration Tool updates it in place and existing steps and workflows keep pointing at it |

## 6. Execution Limits

- A plug-in / custom workflow activity execution is limited to **2 minutes**.
- Loops that call the organization service (`Retrieve`, `RetrieveMultiple`, `Create`, `Update`, `Execute`) or an HTTP endpoint once per item are the most common cause of timeouts with real data volumes. Report them as ⚠️ with the loop location — do not redesign them as part of the migration.
- Bulk / migration-style work is better moved to asynchronous steps, `ExecuteMultiple` batches, Power Automate, or an Azure Function.

## 7. Things That Disappear Online

| On-prem habit | Online replacement |
|---|---|
| Server registry / `app.config` / `web.config` settings | Plug-in secure/unsecure configuration, environment variables, configuration records |
| Windows Event Log on the CRM server | Plug-in Trace Log (`ITracingService`) — enable in Settings → Administration → System Settings → Customization |
| Writing files to a server share | Note attachments, SharePoint, Azure Blob Storage |
| Direct SQL to the CRM database or other databases | Organization service / Web API; external DBs via an API |
| Server-side scheduled jobs on the CRM machine | Power Automate (scheduled) or Azure Functions (timer) |
| `SandboxWorkerOutboundUriPattern` registry setting (on-prem Sandbox network allow-list) | Does not exist online — the rules in section 1 are fixed |
