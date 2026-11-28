# Scanner Output (`scan.ps1` JSON)

| JSON field | Meaning |
|---|---|
| `Settings` | `Path` of `sandbox-audit.json` (or null), `Errors`, `Warnings`, and the effective values: `Target`, `ReportEnabled`, `ReportLocation`, `SharedHelperFolder`, `SharedHelperNamespace`, `SkipProjects`, `HttpTimeoutSeconds`, `AcceptedFindings` |
| `SerializerCheck` | Configured serializer strategy. `builtin`: `ClassName`, `Namespace`, `File`. `existing`: `Files[]`, `SerializeCall`, `DeserializeCall`, `Usings`, `DateStyle`, `SandboxSafe`, `Problems[]`, `CompiledIntoThisProject` |
| `VersionControl` | `Type` = `git` / `tfvc` / `none`, and `Root` |
| `Files[]` | Every compiled `.cs` file: `Source` = `local` / `linked` / `shared`, `Exists`, `Hits`, `Types`, `SharedBy` (other projects compiling the same file) |
| `Hits[]` | `File`, `Line`, `Category`, `Severity`, `Api`, `Member` (containing method), `InDebug`, `Text`, `Accepted` (reason, when the team accepted it) |
| `UnresolvedIncludes` | `<Compile Include>` values with MSBuild properties the script could not expand — resolve these manually |
| `LocalCsNotCompiled` | `.cs` files in the folder that are NOT in the `.csproj` — not compiled, ignore them |
| `References`, `PackagesConfig`, `PackageReferences`, `ProjectReferences` | Inputs for Step 5 |
| `ReferencedProjects[]` | Projects reached through `<ProjectReference>`, directly or indirectly: `Name`, `Path`, `Exists`, `AssemblyName`, `Via` (the project that references it), `Depth`, `Files` (scanned), `ReferencedBy` (every project in the solution that uses it, directly or indirectly). Their files are in `Files[]` with `Source = 'referenced'` and `ReferencedProject`; their hits carry `ReferencedProject`. `Counts.Files` counts only files compiled into this DLL; `Counts.Referenced` counts the referenced ones |
| `ExistingHelpers[]` | Every `MimeTypeHelper` / `QueryStringHelper` / `EnvironmentVariableHelper` class in the solution (or in this project, without `-SolutionRoot`): `Name`, `Path`, `Namespace`, `Visibility`, `CompiledIntoThisProject`, `OwnedBy`, `LinkedBy`, `Reusable`, `Reasons[]` — input for `shared-helpers.md` |
| `ExistingAppSerializers[]` | Every class named like `SerializerCheck.ClassName` in the solution: `Path`, `Namespace`, `Visibility`, `CompiledIntoThisProject`, `OwnedBy`, `LinkedBy`, `Reusable`, `Upgrade`, `Reasons[]` — input for "Placing the Serializer" |
| `ProjectStyle` | `legacy` (old-style `.csproj` / `packages.config`) or `sdk` |
| `OnlineReadiness.TargetFramework` / `.Signing` / `.AssemblyVersion` | `Status` + `Note` for each — input for Step 7 |
| `OnlineReadiness.MergeTool` | `null`, or `Tool` (ILMerge / ILRepack / Costura), `Evidence[]`, `MergedLibraries[]`, `MergedFrom`, `Note`. Merged libraries are real runtime dependencies even though the built DLL shows none |
| `OnlineReadiness.ThirdPartyLibraries[]` | Libraries from the known list (`references/third-party-libraries.md`) found in references, packages or merged libraries: `Library`, `Matched[]`, `Status` (Blocked / Review / OK / Handled), `Why`, `Fix`, `Merged` |
| `OnlineReadiness.ReportRendering` | `Found`, `Items[]` (`Kind`: SSRS web service / ReportViewer local report, `Where`, `Line`, `Detail`), `Note` — report rendering that needs a redesign for Online |
| `OnlineReadiness.EntryPoints` | Plug-in and workflow-activity classes as full names (`Namespace.Class`), resolved through custom base classes. `Assumed[]` lists classes counted only because their base class comes from a referenced DLL and is named like a plug-in / activity base — confirm them. `ContainsWorkflowActivities` decides whether plug-in packages are possible |
| `OnlineReadiness.DependencyCandidates` | Non-framework references / packages / project references — confirmed against the compiled DLL in Step 6 |
| `OnlineReadiness.HttpCalls[]` | Every HTTP call: `Call`, `UrlExpr`, best-effort `UrlSource` (`Hardcoded` / `Configuration` / `WorkflowInput` / `StepConfig` / `Parameter` / `Relative` / `Unknown`), `UrlKey`, `Url`, `UrlClass`, `InLoop`, `Accepted` |
| `OnlineReadiness.UrlLiterals[]` | Every hard-coded URL with `Class`: `Blocked` (IP / localhost / protocol), `Internal` (single-label host, `.local`, …), `Avoid` (port), `Review` (plain http), `LooksPublic`, `Unknown`; `Accepted` |
| `OnlineReadiness.LoopRisks[]` | Organization-service or HTTP calls inside loops (2-minute limit risk) |

## `-ListProjects` output

`scan.ps1 -ListProjects -SolutionRoot <root>` writes `Projects[]`, one per `.csproj`: `Name`, `Path` (relative to the root), `FullPath`, `Kind` (`Plugins` / `WorkflowActivities` / `Plugins+WorkflowActivities` / `Other`), `Framework`, `Hint` (full-trust looking names), `Skipped`, `AssemblyName` (from the `.csproj`, else the file name), `AssemblyVersion` (from `[assembly: AssemblyVersion]` in a compiled file, or the `.csproj` `AssemblyVersion` / `Version`), `EntryTypes` — the full names (`Namespace.Class`) of every non-abstract plug-in and workflow activity class — and `AssumedEntryTypes`, the ones counted only because their base class (not in the source, so from a referenced DLL) is named like a plug-in / activity base; confirm those. `crm-inventory.ps1` uses `AssemblyName` and `EntryTypes` to match registered assemblies with source projects.
