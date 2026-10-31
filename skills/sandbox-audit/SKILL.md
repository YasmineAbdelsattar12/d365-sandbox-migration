---
name: "sandbox-audit"
description: "Fully automated Dynamics 365 CRM Sandbox migration tool, including Dataverse Online readiness. Scans all C# files in a plugin/workflow project (including linked and shared-project files), fixes every Sandbox violation in-place, removes blocked NuGet packages and references, builds in Release mode, fixes build errors, checks online readiness (endpoints, .NET version, dependencies, signing, version) and produces a summary. Triggers on: 'sandbox migration', 'audit for sandbox', 'sandbox violation', 'partial trust', 'isolation mode', 'none to sandbox', 'full trust to sandbox', 'plugin sandbox', 'migrate to sandbox', 'migrate plugins to online', 'dataverse online readiness', 'on-prem to online'."
---

# D365 Sandbox Migration — Automated Fix Tool

Fully automated: scan → safety check → fix → clean references → build → verify → online readiness → summary → PDF report (optional).
The developer gets a clean Release build ready to register, plus a clear list of what still blocks go-live on Dataverse Online.

This skill ships a scanner script at `scripts/scan.ps1` inside this skill's base directory (the "Base directory for this skill" path shown when the skill loads). Use it — it is faster and more consistent than grepping by hand.

## Step 1: Get the Project Path and Target

Order: settle the **project path first** (plain chat), then ask **target + PDF report** together in one AskUserQuestion call.

**Target environment.** Ask once (AskUserQuestion) unless the developer already said:
- **Dataverse Online** (default — moving from on-prem to the cloud): run every check, including Step 7 Online Readiness against `references/online-checklist.md`
- **On-premises, Sandbox only**: skip the online-only checks (framework rule, plug-in packages, internal endpoints become ⚠️ instead of ❌)

If nobody answers, use **Dataverse Online** and say so in the summary.

**PDF report.** In the same AskUserQuestion call, ask:

> Create a PDF report of this migration at the end (for documentation)?
- **Yes — save in the repo** (`<repo root>\docs\sandbox-migration\`, can be committed with the migration)
- **Yes — save in my Documents folder** (`Documents\Sandbox Migration Reports\`)
- **No**

Remember the answer for Step 9. If nobody answers, treat it as **No** for now (Step 9 asks again).

**Project.** If the developer already gave a path, or the current working directory contains exactly one `.csproj`, use it and say so. Otherwise ask **as a normal chat message — NOT with AskUserQuestion** — and wait for the reply:

> What is the path to the D365 plugin or workflow activity project you want to migrate? (The folder containing the `.csproj`, or the `.csproj` itself.)

You may suggest a few likely candidates in the same message (e.g. projects not yet migrated), but the developer answers by typing. **Never create an option named "Other" / "Other (type path)" in AskUserQuestion** — the tool adds its own free-text choice, and a hand-made "Other" is just a button with no text box, so the path never arrives.

Accept a folder path or a `.csproj` file path. If the developer gives a `.sln` path, find all `.csproj` files in the solution directory and ask which project(s) to migrate (AskUserQuestion with the real project names as options is fine here).

Confirm the path exists and contains a `.csproj` file before proceeding.

## Step 2: Run the Scanner

1. Determine the **solution root** — the folder used to find other projects that link the same shared files:
   - The git repository root (`git -C "<project folder>" rev-parse --show-toplevel`), or
   - The folder containing the `.sln`, or
   - If neither exists, omit `-SolutionRoot`.

2. Run (Windows PowerShell 5.1+ or PowerShell 7):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\scan.ps1" -Project "<path to .csproj>" -SolutionRoot "<solution root>" -OutFile "<scratchpad or %TEMP%>\sandbox-scan-<Project>.json"
   ```
   (Use `pwsh` instead of `powershell` if only PowerShell 7 is installed.)

3. The console output gives counts and one line per hit. The JSON file has everything:

   | JSON field | Meaning |
   |---|---|
   | `Files[]` | Every compiled `.cs` file: `Source` = `local` / `linked` / `shared`, `Exists`, `Hits`, `Types`, `SharedBy` (other projects compiling the same file) |
   | `Hits[]` | `File`, `Line`, `Category`, `Severity`, `Api`, `Member` (containing method), `InDebug`, `Text` |
   | `UnresolvedIncludes` | `<Compile Include>` values with MSBuild properties the script could not expand — resolve these manually |
   | `LocalCsNotCompiled` | `.cs` files in the folder that are NOT in the `.csproj` — not compiled, ignore them |
   | `References`, `PackagesConfig`, `PackageReferences`, `ProjectReferences` | Inputs for Step 5 |
   | `ExistingAppSerializers[]` | `Path`, `Namespace`, `Visibility`, `OldDateFormat`, `LinkedBy` — input for "Placing AppSerializer" |
   | `ProjectStyle` | `legacy` (old-style `.csproj` / `packages.config`) or `sdk` |
   | `OnlineReadiness.TargetFramework` / `.Signing` / `.AssemblyVersion` | `Status` + `Note` for each — input for Step 7 |
   | `OnlineReadiness.EntryPoints` | Plug-in and workflow-activity classes (resolved through custom base classes). `ContainsWorkflowActivities` decides whether plug-in packages are possible |
   | `OnlineReadiness.DependencyCandidates` | Non-framework references / packages / project references — confirmed against the compiled DLL in Step 6 |
   | `OnlineReadiness.HttpCalls[]` | Every HTTP call: `Call`, `UrlExpr`, best-effort `UrlSource` (`Hardcoded` / `Configuration` / `WorkflowInput` / `StepConfig` / `Parameter` / `Relative` / `Unknown`), `UrlKey`, `Url`, `UrlClass`, `InLoop` |
   | `OnlineReadiness.UrlLiterals[]` | Every hard-coded URL with `Class`: `Blocked` (IP / localhost / protocol), `Internal` (single-label host, `.local`, …), `Avoid` (port), `Review` (plain http), `LooksPublic`, `Unknown` |
   | `OnlineReadiness.LoopRisks[]` | Organization-service or HTTP calls inside loops (2-minute limit risk) |

   Severity meanings: **Blocked** = fails in Sandbox if executed · **Avoid** = unsupported or unreliable in plug-ins · **Review** = depends on usage, read in context · **Harden** = allowed, apply HTTP hardening · **Using** = namespace import only.

4. Report discovery to the developer: "Found X compiled .cs files (Y local, Z linked, W shared) — N hits in M files (B blocked, R review, H HTTP calls)." Then **list every linked and shared file explicitly**. Linked files are the most common source of missed violations because they live outside the project folder.

5. If `Files[].Exists` is false for any file, report it — the build will fail on it anyway.

**Fallback (scanner cannot run):** Parse the `.csproj` yourself. Resolve every `<Compile Include>` relative to the `.csproj` folder (entries with `<Link>` or `..` are linked files), every `<Import Project="*.projitems">` (resolve its `<Compile>` entries relative to the `.projitems` folder, `$(MSBuildThisFileDirectory)` = that folder), and for SDK-style projects all `**/*.cs` except `bin/`/`obj/` and `<Compile Remove>`. Then search all of them for the patterns in `references/blocked-apis.md`. On Windows, prefer PowerShell `[xml]` parsing over `grep`/`sed` pipelines — they are slow on large trees.

### Scope rule

Every file in `Files[]` is compiled into the assembly and runs in Sandbox — it is **in scope**, whether local, linked or shared. Do NOT skip a file because it lives outside the project folder. The only files to skip are those clearly not part of plugin execution: unit tests (`[TestClass]`, `[Fact]`), API controllers (`ApiController`, `ControllerBase`), console `Main()` entry points.

## Step 3: Safety Check (git)

Before editing anything:

1. Run `git -C "<project folder>" status --porcelain` for the repository.
2. Check whether any file the migration may touch (the `.csproj`, `packages.config`, files with hits) already has uncommitted changes, and whether other uncommitted changes exist elsewhere in the repo (e.g. from migrating a previous project).
3. If there are uncommitted changes, ask with AskUserQuestion:
   - **Commit first** — the developer commits, then says continue (recommended, so each project's migration is its own reviewable commit)
   - **New branch** — run `git switch -c sandbox/<ProjectName>` and continue
   - **Continue anyway**
4. Never commit, stash or discard on the developer's behalf unless they ask.
5. Record the starting point for the report: `git -C "<project folder>" rev-parse --short HEAD` (**base commit**, after any commit the developer made in this step) and `git config user.name` (**author**).
6. If the folder is not a git repository, or nobody answers, continue and note it in the summary ("Changes were made without a clean git baseline").

## Step 4: Analyse and Fix

Read **every file that has a Blocked, Review or Harden hit** — the whole file, using its absolute path. Files with zero hits do not need to be read, except:
- DTO / model classes passed to a serializer you are replacing (they need `[DataContract]` / `[DataMember]`)
- Classes containing the callers you need to trace for a hit

Process DTOs and helpers first, then plugins and workflows. For each hit, decide in this order:

1. **In `#if DEBUG`** (`InDebug: true`) → leave it.
2. **In a `local` file** → apply caller verification (below), then fix if live.
3. **In a `linked` or `shared` file** → follow **Shared File Rule** below.
4. **Review hits** → read the code; fix only if it actually violates Sandbox (e.g. `StreamReader` on a file path, not on a stream).
5. **Avoid hits** → fix only when the replacement is mechanical and keeps behaviour (e.g. a fire-and-forget `new Thread(() => Log(x)).Start()` → `Log(x)`); otherwise report under "Needs decision".
6. **Network design hits** — IP-address or internal URLs, Windows credentials (`UseDefaultCredentials`, `CredentialCache.DefaultCredentials`) → **never change the URL or the authentication** yourself. These need an infrastructure decision (public DNS name, API Management, token auth). Report them in Step 7.

Fix in-place with the Edit tool:
- Replace blocked API calls with Sandbox-safe alternatives (`references/blocked-apis.md`)
- Serialization: follow `references/serializer-guide.md` exactly
- HTTP calls: apply hardening from `references/code-patterns.md`
- System.Web utilities: use replacements from `references/code-patterns.md`
- Add required `using` statements; remove `using` statements for blocked namespaces ONLY if nothing else in the file uses them
- Ensure DTO classes are `public` (required in partial trust)

Record every change (file, lines, what was replaced).

### Shared File Rule (linked / shared files)

A linked file is ONE physical file compiled into every project that links it. `Files[].SharedBy` lists those projects. Editing it changes all of them.

1. **Trace callers inside this assembly** (local files + all linked/shared files in `Files[]`) for the method containing the hit.
2. **No caller reaches it from a plugin / workflow entry point** → dead code in this assembly. Do NOT edit. Record it in "Blocked APIs left in place" with the evidence (e.g. "`Tools.GetMimeType` — no call sites in the 78 compiled files").
3. **A live call path exists** → fix it, but only with a change that is behaviour-identical in full trust too (all fixes in the reference files are). Then list **every project in `SharedBy`** under "Projects to rebuild" in the summary.
4. **Unsure whether a path is live** (e.g. called through reflection, virtual dispatch, or a public API used by many callers) → fix it if `SharedBy` has 1–3 projects; if more, do NOT edit — list it under **"Needs decision"** with the call path you found and the number of affected projects, and let the developer choose.
5. Never edit a shared file just because it contains a blocked API.

### Caller Verification (local files)

Applies to individual METHODS, never to whole files.

1. Search for all callers **within the same assembly** (all files in `Files[]`).
2. Zero callers from plugin/workflow code → NOT a violation — do NOT change it.
3. Callers only in API/Portal projects → do NOT change it.
4. Virtual/abstract methods → check whether any override is called from plugin code.
5. Sandbox enforces at **execution time**, not **load time**. Dead code is safe — but only skip a method when you are certain it has no live caller.

### Fix Rules

- Fix ONLY Sandbox violations. Do NOT change code style, formatting, naming, pre-existing bugs, performance, business logic, or comments (except comments naming a removed API).
- Keep changes minimal — replace only the blocked call, preserve surrounding logic.

### HTTP Hardening

For every outbound call (`Harden` hits), ensure:
1. `ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;` before the call
2. Timeout ≤ 90 seconds (`client.Timeout` / `request.Timeout`)
3. KeepAlive disabled — `request.KeepAlive = false;` / `client.DefaultRequestHeaders.ConnectionClose = true;` (Microsoft guidance for sandboxed calls)
4. `.GetAwaiter().GetResult()` instead of `.Result` — except as below
5. `InvalidPluginExecutionException` instead of generic `Exception` / `InvalidOperationException`
6. Response body read before the status check

### `.Result` → `.GetAwaiter().GetResult()` — exception

Normally replace `.Result` / `.Wait()` on tasks with `.GetAwaiter().GetResult()`. **But** first look at the surrounding `try/catch`:
- If the call is inside a `try` whose `catch` handles `AggregateException` specifically (and the code relies on it — e.g. swallows or unwraps it), **keep `.Result`**. `.GetAwaiter().GetResult()` throws the inner exception instead, so the catch would no longer match and behaviour would change.
- Record it under "Left as-is on purpose" in the summary and offer the change.

### Serializer Migration

When a file uses `Newtonsoft.Json` or `JavaScriptSerializer`:

1. Replace `JsonConvert.SerializeObject/DeserializeObject` and `JavaScriptSerializer.Serialize/Deserialize` → `AppSerializer.Serialize/Deserialize`
2. Replace `[JsonProperty("x")]` → `[DataMember(Name = "x")]`
3. Remove `[JsonIgnore]` / `[ScriptIgnore]` (with `[DataContract]` on the class, unannotated members are excluded)
4. Add `[DataContract]` to the class and `[DataMember]` to EVERY member that should serialize
5. **Choose `Name` values carefully** — `DataContractJsonSerializer` is case-sensitive; the old serializers were not. Follow the table in `references/serializer-guide.md` → "Property Names Are Case-Sensitive". For any **deserialized** class whose real JSON casing you could not confirm, list it under **"Needs verification"**.
6. **DateTime members**: if the class being serialized was previously serialized with `JavaScriptSerializer` and has `DateTime` members, the wire format changes — see serializer-guide → "DateTime Handling" and list it under **"Needs verification"**.
7. Replace `JObject.Parse` → typed DTO + `AppSerializer.Deserialize<T>`
8. Get `AppSerializer` from **Placing AppSerializer** below — never write a new copy without checking.

### Placing AppSerializer

Check `ExistingAppSerializers` from the scan (or search the solution for `class AppSerializer` if the scanner could not run):

1. **Already compiled into this project** (its path is in `Files[]`) → use it. If `OldDateFormat` is true, update its date format per `references/serializer-guide.md` (it is shared — list its `LinkedBy` projects under "Projects to rebuild").
2. **Exists elsewhere in the solution** → add it to this `.csproj` as a linked file, using the same `<Link>` folder convention as the project's other linked files:
   ```xml
   <Compile Include="..\..\Helper\LinkDev.Common.Crm.Utilities\AppSerializer.cs">
     <Link>Utilities\AppSerializer.cs</Link>
   </Compile>
   ```
   If it is `public`, and this assembly references another assembly that also compiles it, change it to `internal` to avoid `CS0433` (list affected projects). Apply the `OldDateFormat` fix as in 1.
3. **Does not exist** → if the project already links files from a shared helper folder (most `linked` entries share a parent folder, e.g. `Helper\...Utilities\`), create `AppSerializer.cs` there using the `internal` version from `references/serializer-guide.md`, with that folder's namespace, and link it. Only if the project has no linked files at all, create it in the project folder.
4. Add the matching `using <namespace>;` to every file that calls it.

## Step 5: Clean Project References and NuGet Packages

After fixing all `.cs` files, clean the `.csproj`:

### Remove Blocked NuGet Packages

Search `packages.config` or `<PackageReference>` for:

| Package | Action |
|---|---|
| `Newtonsoft.Json` | Remove the package and `<Reference>` once all usages in compiled code are replaced (including dead code in linked files — otherwise the build breaks; then keep it and confirm in Step 6 that the compiled DLL no longer references it). |
| `System.Web` | Remove the reference |
| `log4net` | Remove package and reference |
| `NLog` | Remove package and reference |
| `Serilog` (any Serilog.*) | Remove package and reference |
| `System.Data.SqlClient` | Remove if all usages replaced |
| `EntityFramework` | Remove if all usages replaced |

### Remove Blocked Assembly References

Remove `<Reference>` entries for `System.Web`, `System.Web.Extensions`, `System.Drawing`, `System.Windows.Forms`, `System.Management`, `Microsoft.VisualBasic`, `System.DirectoryServices`, `System.ServiceProcess` — only if NO remaining compiled code (including dead code in linked files) uses types from that assembly. Otherwise keep it and say why.

### Add Required References

If not already present: `System.Runtime.Serialization` (for `DataContractJsonSerializer`, `[DataContract]`, `[DataMember]`); `System.ServiceModel` only if WCF `BasicHttpsBinding` is used.

### Clean packages.config

If packages were removed from `packages.config`, also remove the corresponding `<Reference>` with `HintPath` pointing to the package.

## Step 6: Build in Release Mode

1. Locate `MSBuild.exe` or use `dotnet build`:
   ```
   dotnet build "ProjectName.csproj" --configuration Release
   ```
   If `dotnet build` is not available or the project uses old-style `.csproj`, try:
   ```
   msbuild "ProjectName.csproj" /p:Configuration=Release /t:Rebuild
   ```
2. If the build **succeeds**: continue with item 5 below, then Step 7.
3. If the build **fails**: fix each error —
   - **Missing type/namespace** after removing a reference → a usage was missed; fix the code or restore the reference
   - **Missing `using`** → add it
   - **Ambiguous reference / CS0433** → add the full namespace qualifier, or make a linked helper `internal`
   - **Missing `[DataMember]`** → add it
   - **Type not public** → make the DTO `public`
   - **Missing parameterless constructor** → add `public ClassName() { }`
4. Rebuild after fixes, max 5 attempts. If still failing, stop and report the remaining errors.
5. **Inspect the compiled DLL** (use Windows PowerShell `powershell` — `ReflectionOnlyLoadFrom` is not available in PowerShell 7):
   ```powershell
   $dll = (Resolve-Path "bin\Release\<Assembly>.dll").Path
   $n = [System.Reflection.AssemblyName]::GetAssemblyName($dll)
   "Version: $($n.Version)  PublicKeyToken: $(-join ($n.GetPublicKeyToken() | % { $_.ToString('x2') }))  Size: $((Get-Item $dll).Length) bytes"
   [System.Reflection.Assembly]::ReflectionOnlyLoadFrom($dll).GetReferencedAssemblies() | % { "$($_.Name) $($_.Version)" }
   ```
   - **Runtime dependencies** = referenced assemblies other than `mscorlib`, `netstandard`, `System*`, `Microsoft.CSharp`, `Microsoft.Xrm.Sdk*`, `Microsoft.Crm.Sdk.Proxy`. This is the real list — `DependencyCandidates` from the scan are only `.csproj` entries.
   - **Signed** = the public key token is not empty.
   - **Version** = compare major.minor with the version at the last commit (`git show HEAD:<path of AssemblyInfo.cs or .csproj>`). If major or minor changed, warn: the Plugin Registration Tool treats it as a different assembly, so the in-place update fails or steps/workflows stay bound to the old one.

## Step 7: Online Readiness

Skip the online-only rows when the target is on-premises (Step 1). Use `references/online-checklist.md` for the rules and wording.

1. **HTTP endpoint inventory** — one row per entry in `OnlineReadiness.HttpCalls`. The scanner's `UrlSource` is a best-effort trace: open the code and confirm it, and resolve `Unknown` / `Relative` / `Parameter` rows yourself (for `Parameter`, follow the caller one level up). Status per row:
   | Source | Status |
   |---|---|
   | Hard-coded, `UrlClass` = `Blocked` (IP, localhost, non-http) | ❌ |
   | Hard-coded, `Internal` (single-label host, `.local` …) | ❌ online / ⚠️ on-prem |
   | Hard-coded, `Avoid` (port) or `Review` (plain http) | ⚠️ |
   | Hard-coded, `LooksPublic` https | ✅ (note "confirm it resolves publicly") |
   | `Configuration` / `WorkflowInput` / `StepConfig` / `Parameter` | ⚠️ "confirm the value is a public HTTPS DNS name" — name the key / argument and where it is read |
   | Any call using Windows credentials | ❌ |
2. **Project checks**: `TargetFramework`, `Signing`, version (Step 6, item 5), size ≤ 16 MB.
3. **Dependencies** — from the compiled DLL (Step 6, item 5):
   - none → ✅
   - some, and `ContainsWorkflowActivities` → ❌ "plug-in packages don't support workflow activities — compile the code in via linked files or remove the dependency"
   - some, plug-ins only → ⚠️ "deploy as a plug-in package, or remove the dependency"
4. **Loop risks** — each `LoopRisks` entry → ⚠️ with file, line and loop line. Report only; do not redesign.
5. **Overall**: ❌ if any row is ❌, else ⚠️ if any row is ⚠️, else ✅.
6. **What the team must do before go-live** — a short numbered list built from every ❌ and ⚠️ row, most serious first.

## Step 8: Write Summary

### Migration Summary

```
Project: [Project Name]
Assembly: [Assembly Name]
Total .cs files scanned: X (Y local, Z linked, W shared)
Files modified: N
New files: [list, or none]
Files clean (no changes): M
Files skipped (full-trust only): K
Build result: ✅ Success / ❌ Failed (with errors)
Output: bin\Release\[Assembly].dll, [size] (limit 16 MB)
Git baseline: clean / uncommitted changes present / not a git repo
Target: Dataverse Online / On-premises Sandbox
Online readiness: ✅ Ready / ⚠️ Needs work (N items) / ❌ Blocked (N items)
```

### Linked & Shared Files Scanned

List every linked/shared file with **[LINKED]** / **[SHARED]**, its status, and `SharedBy` count when known.

### Changes Made

For each modified file: path (with **[LINKED]** / **[SHARED]** when applicable), what changed, lines affected.

### Blocked APIs Left in Place

Table: location · blocked API · evidence it never runs in this assembly.

### Left As-Is On Purpose

E.g. `.Result` kept because of an `AggregateException` catch — with the one-line change on offer.

### Needs Verification

Deserialized DTOs whose JSON casing was not confirmed; serialized classes whose DateTime format changed. Say exactly what to check.

### Needs Decision

Shared-file violations not edited because of their reach (rule 4 of the Shared File Rule).

### Projects to Rebuild

Every project in `SharedBy` of any shared file that was edited — they all compile the changed file.

### References & Packages

Removed / kept (with reason) / added.

### Online Readiness

From Step 7, in this shape:

```
Online Readiness: ⚠️ Needs work (2 items)

Target framework:  ✅ .NET 4.6.2
Signed:            ✅ <key file>
Version:           ✅ 1.0.0.0 → 1.0.0.0 (in-place update OK)
Dependencies:      ✅ none (Contracts compiled in via linked files)
Size:              ✅ 277 KB (limit 16 MB)
```

| # | Class / method | Call | URL comes from | Status |
|---|---|---|---|---|
| 1 | MigrateNotesToDocuments.Execute | POST | Config record `DocumentsApiUrl` | ⚠️ Confirm it's a public HTTPS DNS name |
| 2 | … | … | Hard-coded `http://10.1.2.15/api` | ❌ IP address — not allowed online |

Then **calls inside loops** (⚠️, report only) and **What your team must do before go-live** (numbered, most serious first).

### Next Steps for Developer

1. **If a file was added to the `.csproj`** (e.g. `AppSerializer.cs` linked or created): in Visual Studio, right-click the project → **Reload Project** (or reopen the solution) — Solution Explorer does not show files added outside VS until it reloads.
2. Review the diff and commit this project's migration as its own commit.
3. Open **XrmToolBox → Plugin Registration Tool** (connected to the target environment), update the assembly with the `.dll` from `bin\Release\`, set Isolation Mode to **Sandbox** (online: always Sandbox), and confirm all steps are still registered.
4. Online: enable the **Plug-in Trace Log** (Settings → Administration → System Settings → Customization) for the first test runs — it replaces Event Log / file logging.
5. Rebuild and re-register every project under "Projects to rebuild".
6. Test: [list key scenarios based on what changed — every HTTP call, every serialized payload, every "Needs verification" item].

## Step 9: PDF Report

1. **Decide.** If the developer chose a report location in Step 1, continue. If they chose **No** or did not answer, ask once more now (AskUserQuestion): "Want a PDF report of this migration for your documentation?" with the same three options. If nobody is there to answer, skip the report.
2. **Write `report-data.json`** (UTF-8) in the scratchpad or `%TEMP%`, following `references/report-schema.md`. Fill it from the summary you just wrote — same facts, same wording, plain text. Include in `ChangedPaths` every file modified or created in this run (absolute paths, including the `.csproj` and `packages.config`), and set `BaseCommit` / `Author` from Step 3.
3. **Output folder:**
   - Repo: `<repo root>\docs\sandbox-migration`
   - Documents: `[Environment]::GetFolderPath('MyDocuments')` + `\Sandbox Migration Reports`
4. **Run:**
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\make-report.ps1" -Data "<report-data.json>" -Scan "<scanner JSON from Step 2>" -Repo "<repo root>" -OutDir "<output folder>" -Open
   ```
   The script builds an HTML report with the real code diff since the base commit and converts it to PDF with Microsoft Edge (or Chrome) in headless mode, then opens it. Omit `-Repo` if the project is not in git.
5. **Tell the developer** the PDF path in one line. If the script says the PDF was not created (no Edge/Chrome), give the HTML path and say: open it and use **Print → Save as PDF**. If it was saved in the repo, mention it will show up in Git Changes and can be committed with the migration.

## What NOT to Change

- Style, formatting, naming conventions
- Pre-existing bugs, performance issues
- Methods with no live caller in this assembly (even if they contain blocked APIs)
- Shared files without a proven live call path (see Shared File Rule)
- Code in `#if DEBUG` blocks
- Newtonsoft.Json in non-plugin assemblies
- Business logic, validation rules, error messages
- Endpoint URLs, authentication design, or loop/batching design — report them in Online Readiness instead
- Comments (unless they reference a removed API by name)
- Any code that is not a Sandbox violation
