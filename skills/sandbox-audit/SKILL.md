---
name: "sandbox-audit"
description: "Fully automated Dynamics 365 CRM Sandbox migration tool for any team or project, including Dataverse Online readiness. Scans all C# files in a plugin/workflow project (including linked and shared-project files), fixes every Sandbox violation in-place, removes blocked references, builds in Release, checks online readiness (endpoints, .NET version, dependencies, signing, version) and produces a summary and optional PDF report. Supports per-repo team settings (sandbox-audit.json), a setup mode, a read-only report mode, git and TFVC. Triggers on: 'sandbox migration', 'audit for sandbox', 'sandbox violation', 'partial trust', 'isolation mode', 'none to sandbox', 'full trust to sandbox', 'plugin sandbox', 'migrate to sandbox', 'migrate plugins to online', 'dataverse online readiness', 'on-prem to online', 'sandbox audit setup'."
---

# D365 Sandbox Migration — Automated Fix Tool

Fully automated: settings → scan → safety check → fix → clean references → build → verify → online readiness → summary → PDF report (optional).
The developer gets a clean Release build ready to register, plus a clear list of what still blocks go-live on Dataverse Online.

Scripts in this skill's base directory (the "Base directory for this skill" path shown when the skill loads) — use them, they are faster and give the same result every time:

| Script | Purpose |
|---|---|
| `scripts/scan.ps1` | Resolve every compiled file, find blocked APIs, online-readiness data, team settings, version control. `-ListProjects` lists the whole repo |
| `scripts/build.ps1` | Find MSBuild on any machine (vswhere), restore, rebuild, list errors, inspect the DLL |
| `scripts/make-report.ps1` | HTML + PDF report with the code diff |

Run them with Windows PowerShell: `powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\<script>.ps1" ...` (use `pwsh` if only PowerShell 7 is installed).

## Step 0: Mode

Read the text the skill was invoked with:

| Invocation contains | Mode |
|---|---|
| `setup`, `configure`, `init` | **Setup mode** — follow `references/modes.md` → Setup Mode. Writes `sandbox-audit.json`; changes no code |
| `report`, `audit only`, `dry run`, `read-only`, `assess` | **Report-only mode** — follow `references/modes.md` → Report-Only Mode. Analyses and reports; changes no code |
| anything else (or nothing) | **Migrate mode** — Steps 1–9 below |

A project path in the invocation text is used as the project.

## Step 1: Project, Target and Report

**Team settings.** The scanner finds `sandbox-audit.json` on its own (project folder or any parent up to the repo root) — see `references/config.md`. Its values replace the questions below:

| Setting | Effect |
|---|---|
| `target: online` / `onprem` | Don't ask the target question |
| `report.enabled: true` + `report.location` | Don't ask; create the report there |
| `report.enabled: false` | Don't ask, and skip Step 9 entirely |
| `skipProjects` | Never suggest these; if the developer names one, say it is listed as skipped and ask before continuing |

If settings exist but nothing has been scanned yet, run the scanner (Step 2) first with the chosen project, then apply them. If the scanner reports **settings errors**, show them and stop — they must be fixed in the file first. Show settings **warnings** in one line and continue.

**Project.** If the developer already gave a path, or the current working directory contains exactly one `.csproj`, use it and say so. Otherwise ask **as a normal chat message — NOT with AskUserQuestion** — and wait for the reply:

> What is the path to the D365 plugin or workflow activity project you want to migrate? (The folder containing the `.csproj`, or the `.csproj` itself.)

To suggest candidates in the same message, run `scan.ps1 -ListProjects -SolutionRoot "<repo root>"` and list a few projects whose `Kind` is not `Other`, that are not `Skipped`, and have no full-trust `Hint` — never guess from folder names. The developer answers by typing. **Never create an option named "Other" / "Other (type path)" in AskUserQuestion** — the tool adds its own free-text choice, and a hand-made "Other" is just a button with no text box.

Accept a folder path or a `.csproj` file path. If the developer gives a `.sln` path, find all `.csproj` files in the solution directory and ask which project(s) to migrate (AskUserQuestion with the real project names as options is fine here). Confirm the path exists and contains a `.csproj` file before proceeding.

**Target and report** — ask what the settings don't answer, together in one AskUserQuestion call:

- Target: **Dataverse Online** (default — moving from on-prem to the cloud: every check, including Step 7 against `references/online-checklist.md`) or **On-premises, Sandbox only** (skips online-only checks; internal endpoints become ⚠️ instead of ❌). If nobody answers, use Dataverse Online and say so in the summary.
- Report: "Create a PDF report of this migration at the end (for documentation)?" — **Yes — save in the repo** (`<repo root>\docs\sandbox-migration\`) / **Yes — save in my Documents folder** (`Documents\Sandbox Migration Reports\`) / **No**. Remember the answer for Step 9; no answer = No for now (Step 9 asks again).

In the same chat, reuse earlier answers instead of asking again, and say which ones you reused.

## Step 2: Run the Scanner

1. **Solution root** — used to find settings, other projects that link the same files, and existing serializers: the git root (`git -C "<project folder>" rev-parse --show-toplevel`), else the TFVC workspace root, else the folder containing the `.sln`, else omit `-SolutionRoot`.
2. Run:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\scan.ps1" -Project "<path to .csproj>" -SolutionRoot "<solution root>" -OutFile "<scratchpad or %TEMP%>\sandbox-scan-<Project>.json"
   ```
3. The console output gives counts and one line per hit. The JSON file has everything — every field is described in `references/scanner-output.md`. The ones used most: `Settings` (team settings, `Errors`, `Warnings`), `SerializerCheck`, `VersionControl`, `Files[]` (with `Source` and `SharedBy`), `Hits[]` (with `Member`, `InDebug`, `Accepted`), `ExistingAppSerializers[]`, and `OnlineReadiness` (`TargetFramework`, `Signing`, `AssemblyVersion`, `EntryPoints`, `DependencyCandidates`, `HttpCalls`, `UrlLiterals`, `LoopRisks`).

   Severity meanings: **Blocked** = fails in Sandbox if executed · **Avoid** = unsupported or unreliable in plug-ins · **Review** = depends on usage, read in context · **Harden** = allowed, apply HTTP hardening · **Using** = namespace import only. Counts exclude **Accepted** findings.

4. Report discovery to the developer: "Found X compiled .cs files (Y local, Z linked, W shared) — N findings in M files (B blocked, R review, H HTTP calls, A accepted by the team)." Then **list every linked and shared file explicitly**. Linked files are the most common source of missed violations because they live outside the project folder.
5. If `Files[].Exists` is false for any file, report it — the build will fail on it anyway.

**Fallback (scanner cannot run):** Parse the `.csproj` yourself. Resolve every `<Compile Include>` relative to the `.csproj` folder (entries with `<Link>` or `..` are linked files), every `<Import Project="*.projitems">` (resolve its `<Compile>` entries relative to the `.projitems` folder, `$(MSBuildThisFileDirectory)` = that folder), and for SDK-style projects all `**/*.cs` except `bin/`/`obj/` and `<Compile Remove>`. Then search all of them for the patterns in `references/blocked-apis.md`. Read `sandbox-audit.json` yourself if it exists. On Windows, prefer PowerShell `[xml]` parsing over `grep`/`sed` pipelines — they are slow on large trees.

### Scope rule

Every file in `Files[]` is compiled into the assembly and runs in Sandbox — it is **in scope**, whether local, linked or shared. Do NOT skip a file because it lives outside the project folder. The only files to skip are those clearly not part of plugin execution: unit tests (`[TestClass]`, `[Fact]`), API controllers (`ApiController`, `ControllerBase`), console `Main()` entry points.

### Accepted findings

A finding with `Accepted` set was reviewed and accepted by the team (in `sandbox-audit.json` → `acceptedFindings`, or an inline `// sandbox-ignore: reason` comment). Do **not** fix it and do not count it as a violation; list it under **"Accepted findings"** in the summary with its reason. Never add accepted findings yourself — only when the developer asks, and then always with a reason and a date (in `sandbox-audit.json`, or as an inline comment if they prefer).

## Step 3: Safety Check (version control)

Before editing anything, use `VersionControl.Type` from the scan:

**git**
1. Run `git -C "<project folder>" status --porcelain`.
2. Check whether any file the migration may touch (the `.csproj`, `packages.config`, files with hits) already has uncommitted changes, and whether other uncommitted changes exist elsewhere in the repo (e.g. from migrating a previous project).
3. If there are uncommitted changes, ask with AskUserQuestion: **Commit first** (recommended, so each project's migration is its own reviewable commit) / **New branch** (`git switch -c sandbox/<ProjectName>`, then continue) / **Continue anyway**.
4. Record for the report: `git -C "<project folder>" rev-parse --short HEAD` (**base commit**, after any commit made in this step) and `git config user.name` (**author**).

**tfvc** (Team Foundation Version Control)
1. Find `tf.exe`: `& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -find "Common7\IDE\CommonExtensions\Microsoft\TeamFoundation\Team Explorer\TF.exe"`.
2. Run `tf status "<project folder>" /recursive /noprompt` (and for the folders of linked files with hits). Pending changes → ask: **Check in first** (recommended) / **Shelve first** (`tf shelve`, then continue) / **Continue anyway**.
3. Record for the report: baseline `"TFVC workspace version"` plus the latest changeset if available (`tf history "<project folder>" /recursive /stopafter:1 /noprompt /format:brief`), and the author (`$env:USERNAME` or the TFS display name).
4. Remind the developer that files edited outside Visual Studio may need **"Detect local changes"** / **Promote** in Team Explorer (local workspaces) before they show up as pending changes.

**none** (no version control found)
- Say so, recommend copying the project folder (and linked helper folders) before continuing, and ask: **Continue** / **Stop**. Note "no version-control baseline" in the summary.

Never commit, check in, stash, shelve or discard on the developer's behalf unless they ask.

## Step 4: Analyse and Fix

Read **every file that has a Blocked, Avoid, Review or Harden hit that is not Accepted** — the whole file, using its absolute path. Files with zero hits do not need to be read, except:
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
- **Any fix that needs a helper method** (`MimeTypeHelper`, `QueryStringHelper`, `EnvironmentVariableHelper`): read `references/shared-helpers.md` — one shared file per helper in `Settings.SharedHelperFolder`, reused or linked if it already exists (`ExistingHelpers[]` from the scan), never pasted into the class being fixed or copied per project
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
2. Timeout = `Settings.HttpTimeoutSeconds` (default 90; never above 110 — `client.Timeout` / `request.Timeout`)
3. KeepAlive disabled — `request.KeepAlive = false;` / `client.DefaultRequestHeaders.ConnectionClose = true;` (Microsoft guidance for sandboxed calls)
4. `.GetAwaiter().GetResult()` instead of `.Result` — except as below
5. `InvalidPluginExecutionException` instead of generic `Exception` / `InvalidOperationException`
6. Response body read before the status check

### `.Result` → `.GetAwaiter().GetResult()` — exception

Normally replace `.Result` / `.Wait()` on tasks with `.GetAwaiter().GetResult()`. **But** first look at the surrounding `try/catch`:
- If the call is inside a `try` whose `catch` handles `AggregateException` specifically (and the code relies on it — e.g. swallows or unwraps it), **keep `.Result`**. `.GetAwaiter().GetResult()` throws the inner exception instead, so the catch would no longer match and behaviour would change.
- Record it under "Left as-is on purpose" in the summary and offer the change.

### Serializer Migration

When any file in scope uses `JavaScriptSerializer`, Newtonsoft.Json, or a wrapper around them: **read `references/serializer-rules.md` and follow it exactly** — which serializer to use (the team's `existing` class or the builtin helper), keeping the JSON identical (`JsonDateStyle.MsAjax` for JavaScriptSerializer replacements), case-sensitive `[DataMember(Name)]`, where the helper lives, and the mandatory "Shared helper decisions" section. Code and format details are in `references/serializer-guide.md`.

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

1. Build with the bundled script — it finds MSBuild on any machine (vswhere → PATH → dotnet for SDK-style), restores NuGet packages (including `packages.config`), rebuilds and inspects the DLL:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\build.ps1" -Project "<path to .csproj>" -OutFile "<scratchpad or %TEMP%>\sandbox-build-<Project>.json"
   ```
   JSON: `Success`, `Builder`, `Errors[]` (`File`, `Line`, `Code`, `Message`), `WarningCount`, `Dll` (`Path`, `Size`, `WithinSizeLimit`, `Version`, `PublicKeyToken`, `Signed`, `References[]`, `RuntimeDependencies[]`), `LogTail`.
2. Error `NO-MSBUILD` / `NEEDS-MSBUILD` → tell the developer to install Visual Studio or **Build Tools for Visual Studio** (".NET desktop build tools"), and stop the build step (the code changes stay; say the build was not verified).
3. If the build **fails**: fix each error —
   - **Missing type/namespace** after removing a reference → a usage was missed; fix the code or restore the reference
   - **Missing `using`** → add it
   - **Ambiguous reference / CS0433** → add the full namespace qualifier, or make a linked helper `internal`
   - **Missing `[DataMember]`** → add it
   - **Type not public** → make the DTO `public`
   - **Missing parameterless constructor** → add `public ClassName() { }`
4. Rebuild after fixes, max 5 attempts. If still failing, stop and report the remaining errors.
5. **DLL checks** from `Dll` in the build JSON (or `build.ps1 -InspectOnly -Dll <path>` when the team builds another way):
   - **Runtime dependencies** = `Dll.RuntimeDependencies` (references other than .NET Framework and the CRM SDK). This is the real list — `DependencyCandidates` from the scan are only `.csproj` entries.
   - **Signed** = `Dll.Signed`.
   - **Size** = `Dll.WithinSizeLimit` (16 MB).
   - **Version** = compare major.minor of `Dll.Version` with the version at the baseline (git: `git show <base commit>:<path of AssemblyInfo.cs or .csproj>`; TFVC: `tf view "<path>" /version:T` or the scan's `AssemblyVersion` taken before editing). If major or minor changed, warn: the Plugin Registration Tool treats it as a different assembly, so the in-place update fails or steps/workflows stay bound to the old one.

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

Write the summary in chat following `references/summary-template.md` — the sections, their order and their exact shape (Migration Summary block, linked/shared files, changes, accepted findings, blocked APIs left in place, shared helper decisions, left as-is on purpose, needs verification, needs decision, projects to rebuild, references, Online Readiness tables, next steps). In report-only mode, "Changes Made" becomes "Would change".

## Step 9: PDF Report

1. **Decide.** `Settings.ReportEnabled` = `false` → skip this step. `true` → create it at `Settings.ReportLocation`. Otherwise: if the developer chose a report location in Step 1, continue. If they chose **No** or did not answer, ask once more now (AskUserQuestion): "Want a PDF report of this migration for your documentation?" with the same three options. If nobody is there to answer, skip the report.
2. **Write `report-data.json`** (UTF-8) in the scratchpad or `%TEMP%`, following `references/report-schema.md`. Fill it from the summary you just wrote — same facts, same wording, plain text. Include in `ChangedPaths` every file modified or created in this run (absolute paths, including the `.csproj` and `packages.config`), and set `BaseCommit` (git) or `Baseline` (TFVC / none, e.g. "TFVC workspace version (changeset 1234)") and `Author` from Step 3. Add `AcceptedFindings` and `SerializerDecisions` (all shared helper decisions, serializer included) from the summary.
3. **Output folder:**
   - Repo: `<repo root>\docs\sandbox-migration`
   - Documents: `[Environment]::GetFolderPath('MyDocuments')` + `\Sandbox Migration Reports`
   - A path from `Settings.ReportLocation`: that folder (relative to the settings file)
4. **Run:**
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\make-report.ps1" -Data "<report-data.json>" -Scan "<scanner JSON from Step 2>" -Repo "<repo root>" -OutDir "<output folder>" -Open
   ```
   The script builds an HTML report with the real code diff since the base commit and converts it to PDF with Microsoft Edge (or Chrome) in headless mode, then opens it.
   - **TFVC**: omit `-Repo`; first write the diff with `tf diff <every changed path> /format:unified /noprompt > "<scratchpad>\changes.diff"` and pass `-DiffFile "<that file>"`. New files that are not yet added to TFVC: run `tf add` only if the developer agrees, otherwise list them under "New files" (their content is not in the diff).
   - **No version control**: omit `-Repo` and `-DiffFile`; the report has no diff section.
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
