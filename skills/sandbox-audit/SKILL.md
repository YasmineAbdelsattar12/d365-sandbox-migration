---
name: "sandbox-audit"
description: "Fully automated Dynamics 365 CRM Sandbox migration tool. Scans all C# files in a plugin/workflow project, fixes every Sandbox violation in-place, removes blocked NuGet packages and references, builds in Release mode, fixes build errors, and produces a summary. Triggers on: 'sandbox migration', 'audit for sandbox', 'sandbox violation', 'partial trust', 'isolation mode', 'none to sandbox', 'full trust to sandbox', 'plugin sandbox', 'migrate to sandbox'."
---

# D365 Sandbox Migration — Automated Fix Tool

Fully automated: scan → fix → clean references → build → verify → summary.
The developer gets a clean Release build ready to register in XrmToolBox.

## Step 1: Get the Project Path

Ask the developer:

> What is the path to your D365 plugin or workflow activity project folder?
> (The folder containing the `.csproj` file)

Use AskUserQuestion if available. Accept a folder path or a `.csproj` file path. If the developer gives a `.sln` path, find all `.csproj` files in the solution directory and ask which project(s) to migrate.

Confirm the path exists and contains a `.csproj` file before proceeding.

## Step 2: Discover and Classify All Files

1. Read the `.csproj` file to understand the project structure:
   - Find all `<Compile Include="...">` entries (including linked files with `<Link>`)
   - Find all `<Reference>` and `<PackageReference>` entries
   - Find `<Import Project="...*.projitems">` for shared projects
   - Note the assembly name and output path

2. Find all `.cs` files in the project directory (and linked paths).

3. Classify each file:
   - **Plugin** — inherits from `IPlugin` or a custom base class like `PluginBase`
   - **Workflow Activity** — inherits from `CodeActivity` or a custom base class
   - **Helper / BLL / DAL / Utility** — called by plugin or workflow code
   - **DTO / Model** — data transfer objects used in serialization
   - **Full-trust only** — skip (unit tests, API controllers, console entry points)

4. Build a dependency map: which helpers are called by which plugins/workflows. Only code reachable from plugin/workflow entry points is in scope.

5. Report the discovery count to the developer: "Found X .cs files (Y plugins, Z workflows, W helpers/DTOs). Starting migration..."

## Step 3: Scan and Fix Every File

Process files in dependency order — DTOs and helpers first, then plugins and workflows.

For each in-scope `.cs` file:

1. **Read** the entire file.
2. **Scan** for blocked APIs — consult `references/blocked-apis.md` for the full list.
3. **Skip clean files** — if no violations, mark as clean and move on.
4. **Fix violations in-place** using the Edit tool:
   - Replace blocked API calls with Sandbox-safe alternatives
   - For serialization: follow `references/serializer-guide.md` exactly
   - For HTTP calls: apply hardening from `references/code-patterns.md`
   - For System.Web utilities: use replacement patterns from `references/code-patterns.md`
   - Add required `using` statements for new APIs
   - Remove `using` statements for blocked namespaces ONLY if no other code in the file references them
   - Add `[DataContract]` / `[DataMember]` attributes when replacing serializers
   - Ensure DTO classes are `public` (required in partial trust)
5. **Record** what was changed (file name, line numbers, what was replaced).

### Fix Rules

- Fix ONLY Sandbox violations. Do NOT change:
  - Code style, formatting, or naming
  - Pre-existing bugs unrelated to Sandbox
  - Performance issues
  - Business logic
  - Comments (except to update comments that reference removed APIs)
- If a blocked API is in a method with ZERO callers from plugin/workflow code → do NOT fix it (dead code is safe)
- If a blocked API is inside `#if DEBUG` → do NOT fix it
- Keep changes minimal — replace only the blocked call, preserve surrounding logic
- When adding the `AppSerializer` helper class, add it once as a new file, not duplicated in each class

### Serializer Migration

When a file uses `Newtonsoft.Json` or `JavaScriptSerializer`:

1. Replace `JsonConvert.SerializeObject/DeserializeObject` → `AppSerializer.Serialize/Deserialize`
2. Replace `[JsonProperty("x")]` → `[DataMember(Name = "x")]`
3. Replace `[JsonIgnore]` → remove the attribute (with `[DataContract]` on the class, unannotated properties are excluded)
4. Add `[DataContract]` to the class and `[DataMember]` to EVERY property that should serialize
5. Replace `JObject.Parse` → typed DTO + `AppSerializer.Deserialize<T>`
6. If this is the first file needing serialization, create `AppSerializer.cs` in the project — see `references/serializer-guide.md`

### HTTP Hardening

When a file makes outbound HTTP calls, ensure:
1. `ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;` before the call
2. Timeout ≤ 90 seconds
3. `.GetAwaiter().GetResult()` instead of `.Result`
4. `InvalidPluginExecutionException` instead of generic `Exception`
5. Response body read before status check

## Step 4: Clean Project References and NuGet Packages

After fixing all `.cs` files, clean the `.csproj`:

### Remove Blocked NuGet Packages

Search `packages.config` or `<PackageReference>` in `.csproj` for:

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

In the `.csproj`, remove `<Reference>` entries for:
- `System.Web`
- `System.Web.Extensions`
- `System.Drawing`
- `System.Windows.Forms`
- `System.Management`
- `Microsoft.VisualBasic`
- `System.DirectoryServices`
- `System.ServiceProcess`

Only remove a reference if NO remaining code in the project uses types from that assembly.

### Add Required References

If not already present, ensure these references exist:
- `System.Runtime.Serialization` (for `DataContractJsonSerializer`, `[DataContract]`, `[DataMember]`)
- `System.ServiceModel` (only if WCF `BasicHttpsBinding` is used)

### Clean packages.config

If packages were removed from `packages.config`, also:
1. Remove the corresponding `<Reference>` with `HintPath` pointing to the package
2. Remove the package folder from the `packages/` directory if accessible

## Step 5: Build in Release Mode

1. Locate `MSBuild.exe` or use `dotnet build`:
   ```
   dotnet build "ProjectName.csproj" --configuration Release
   ```
   If `dotnet build` is not available or the project uses old-style `.csproj`, try:
   ```
   msbuild "ProjectName.csproj" /p:Configuration=Release /t:Rebuild
   ```

2. If the build **succeeds**: proceed to Step 6.

3. If the build **fails**: analyze each error and fix it:
   - **Missing type/namespace** after removing a reference → a usage was missed; fix the code or restore the reference
   - **Missing `using` statement** → add the correct `using`
   - **Ambiguous reference** → add the full namespace qualifier
   - **Missing `[DataMember]`** on properties → add the attribute
   - **Type not public** → make the DTO class `public`
   - **Missing parameterless constructor** → add `public ClassName() { }`

4. Rebuild after fixes. Repeat until the build is clean (max 5 attempts).

5. If the build still fails after 5 attempts, stop and report the remaining errors to the developer.

## Step 6: Write Summary

Produce a clear summary with these sections:

### Migration Summary

```
Project: [Project Name]
Assembly: [Assembly Name]
Total .cs files scanned: X
Files modified: Y
Files clean (no changes): Z
Files skipped (full-trust only): W
Build result: ✅ Success / ❌ Failed (with errors)
```

### Changes Made

For each modified file, list:
- File path
- What was changed (e.g., "Replaced JsonConvert with AppSerializer", "Added [DataContract] attributes", "Replaced HttpUtility.UrlEncode with Uri.EscapeDataString")
- Lines affected

### References & Packages Removed

List every NuGet package and assembly reference that was removed.

### References & Packages Added

List every new reference added (e.g., `System.Runtime.Serialization`).

### New Files Created

List any new files added (e.g., `AppSerializer.cs`).

### Build Output

- Release build output path (e.g., `bin\Release\AssemblyName.dll`)
- Assembly file size (check against 16 MB limit)

### Next Steps for Developer

1. Open **XrmToolBox → Plugin Registration Tool**
2. Update the assembly: select the `.dll` from `bin\Release\`
3. Change Isolation Mode to **Sandbox**
4. Register / update all plugin steps
5. Test the following scenarios: [list key scenarios based on what was changed]

## Caller Verification

Before fixing a method:

1. Search for all callers across the project.
2. **Zero callers from plugin/workflow code** → NOT a violation — do NOT change it.
3. **Callers only in API/Portal projects** → do NOT change it.
4. **Virtual/abstract methods** → check if any override is called from plugin code.
5. Sandbox enforces at **execution time**, not **load time**. Dead code is safe.

## What NOT to Change

- Style, formatting, naming conventions
- Pre-existing bugs, performance issues
- Unused methods (even if they contain blocked APIs)
- Code in `#if DEBUG` blocks
- Newtonsoft.Json in non-plugin assemblies
- Business logic, validation rules, error messages
- Comments (unless they reference a removed API by name)
- Any code that is not a Sandbox violation
