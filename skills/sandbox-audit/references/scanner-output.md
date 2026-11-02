# Scanner Output (`scan.ps1` JSON)

| JSON field | Meaning |
|---|---|
| `Settings` | `Path` of `sandbox-audit.json` (or null), `Errors`, `Warnings`, and the effective values: `Target`, `ReportEnabled`, `ReportLocation`, `SharedHelperFolder`, `SkipProjects`, `HttpTimeoutSeconds`, `AcceptedFindings` |
| `SerializerCheck` | Configured serializer strategy. `builtin`: `ClassName`, `Namespace`, `File`. `existing`: `Files[]`, `SerializeCall`, `DeserializeCall`, `Usings`, `DateStyle`, `SandboxSafe`, `Problems[]`, `CompiledIntoThisProject` |
| `VersionControl` | `Type` = `git` / `tfvc` / `none`, and `Root` |
| `Files[]` | Every compiled `.cs` file: `Source` = `local` / `linked` / `shared`, `Exists`, `Hits`, `Types`, `SharedBy` (other projects compiling the same file) |
| `Hits[]` | `File`, `Line`, `Category`, `Severity`, `Api`, `Member` (containing method), `InDebug`, `Text`, `Accepted` (reason, when the team accepted it) |
| `UnresolvedIncludes` | `<Compile Include>` values with MSBuild properties the script could not expand — resolve these manually |
| `LocalCsNotCompiled` | `.cs` files in the folder that are NOT in the `.csproj` — not compiled, ignore them |
| `References`, `PackagesConfig`, `PackageReferences`, `ProjectReferences` | Inputs for Step 5 |
| `ExistingAppSerializers[]` | Every class named like `SerializerCheck.ClassName` in the solution: `Path`, `Namespace`, `Visibility`, `CompiledIntoThisProject`, `OwnedBy`, `LinkedBy`, `Reusable`, `Upgrade`, `Reasons[]` — input for "Placing the Serializer" |
| `ProjectStyle` | `legacy` (old-style `.csproj` / `packages.config`) or `sdk` |
| `OnlineReadiness.TargetFramework` / `.Signing` / `.AssemblyVersion` | `Status` + `Note` for each — input for Step 7 |
| `OnlineReadiness.EntryPoints` | Plug-in and workflow-activity classes (resolved through custom base classes). `ContainsWorkflowActivities` decides whether plug-in packages are possible |
| `OnlineReadiness.DependencyCandidates` | Non-framework references / packages / project references — confirmed against the compiled DLL in Step 6 |
| `OnlineReadiness.HttpCalls[]` | Every HTTP call: `Call`, `UrlExpr`, best-effort `UrlSource` (`Hardcoded` / `Configuration` / `WorkflowInput` / `StepConfig` / `Parameter` / `Relative` / `Unknown`), `UrlKey`, `Url`, `UrlClass`, `InLoop`, `Accepted` |
| `OnlineReadiness.UrlLiterals[]` | Every hard-coded URL with `Class`: `Blocked` (IP / localhost / protocol), `Internal` (single-label host, `.local`, …), `Avoid` (port), `Review` (plain http), `LooksPublic`, `Unknown`; `Accepted` |
| `OnlineReadiness.LoopRisks[]` | Organization-service or HTTP calls inside loops (2-minute limit risk) |
