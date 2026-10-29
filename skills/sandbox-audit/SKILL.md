---
name: "sandbox-audit"
description: "Fully automated Dynamics 365 CRM Sandbox migration tool. Scans all C# files in a plugin/workflow project (including linked and shared-project files), fixes every Sandbox violation in-place, removes blocked NuGet packages and references, builds in Release mode, fixes build errors, and produces a summary. Triggers on: 'sandbox migration', 'audit for sandbox', 'sandbox violation', 'partial trust', 'isolation mode', 'none to sandbox', 'full trust to sandbox', 'plugin sandbox', 'migrate to sandbox'."
---

# D365 Sandbox Migration — Automated Fix Tool

Fully automated: scan → safety check → fix → clean references → build → verify → summary.
The developer gets a clean Release build ready to register in XrmToolBox.

This skill ships a scanner script at `scripts/scan.ps1` inside this skill's base directory (the "Base directory for this skill" path shown when the skill loads). Use it — it is faster and more consistent than grepping by hand.

## Step 1: Get the Project Path

If the current working directory contains exactly one `.csproj`, use it and say so. Otherwise ask the developer:

> What is the path to your D365 plugin or workflow activity project folder?
> (The folder containing the `.csproj` file)

Use AskUserQuestion if available. Accept a folder path or a `.csproj` file path. If the developer gives a `.sln` path, find all `.csproj` files in the solution directory and ask which project(s) to migrate.

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

   Severity meanings: **Blocked** = throws in Sandbox if executed · **Review** = depends on usage, read in context · **Harden** = allowed, apply HTTP hardening · **Using** = namespace import only.

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
5. If the folder is not a git repository, or nobody answers, continue and note it in the summary ("Changes were made without a clean git baseline").

## Step 4: Analyse and Fix

Read **every file that has a Blocked, Review or Harden hit** — the whole file, using its absolute path. Files with zero hits do not need to be read, except:
- DTO / model classes passed to a serializer you are replacing (they need `[DataContract]` / `[DataMember]`)
- Classes containing the callers you need to trace for a hit

Process DTOs and helpers first, then plugins and workflows. For each hit, decide in this order:

1. **In `#if DEBUG`** (`InDebug: true`) → leave it.
2. **In a `local` file** → apply caller verification (below), then fix if live.
3. **In a `linked` or `shared` file** → follow **Shared File Rule** below.
4. **Review hits** → read the code; fix only if it actually violates Sandbox (e.g. `StreamReader` on a file path, not on a stream).

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
3. `.GetAwaiter().GetResult()` instead of `.Result` — except as below
4. `InvalidPluginExecutionException` instead of generic `Exception` / `InvalidOperationException`
5. Response body read before the status check

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
| `Newtonsoft.Json` | Remove IF all usages have been replaced AND the package is ILMerged into the plugin assembly. If not ILMerged, leave it. |
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
2. If the build **succeeds**: proceed to Step 7.
3. If the build **fails**: fix each error —
   - **Missing type/namespace** after removing a reference → a usage was missed; fix the code or restore the reference
   - **Missing `using`** → add it
   - **Ambiguous reference / CS0433** → add the full namespace qualifier, or make a linked helper `internal`
   - **Missing `[DataMember]`** → add it
   - **Type not public** → make the DTO `public`
   - **Missing parameterless constructor** → add `public ClassName() { }`
4. Rebuild after fixes, max 5 attempts. If still failing, stop and report the remaining errors.

## Step 7: Write Summary

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

### Next Steps for Developer

1. **If a file was added to the `.csproj`** (e.g. `AppSerializer.cs` linked or created): in Visual Studio, right-click the project → **Reload Project** (or reopen the solution) — Solution Explorer does not show files added outside VS until it reloads.
2. Review the diff and commit this project's migration as its own commit.
3. Open **XrmToolBox → Plugin Registration Tool**, update the assembly with the `.dll` from `bin\Release\`, set Isolation Mode to **Sandbox**, and confirm all steps are still registered.
4. Rebuild and re-register every project under "Projects to rebuild".
5. Test: [list key scenarios based on what changed — every HTTP call, every serialized payload, every "Needs verification" item].

## What NOT to Change

- Style, formatting, naming conventions
- Pre-existing bugs, performance issues
- Methods with no live caller in this assembly (even if they contain blocked APIs)
- Shared files without a proven live call path (see Shared File Rule)
- Code in `#if DEBUG` blocks
- Newtonsoft.Json in non-plugin assemblies
- Business logic, validation rules, error messages
- Comments (unless they reference a removed API by name)
- Any code that is not a Sandbox violation
