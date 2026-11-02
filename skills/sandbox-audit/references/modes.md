# Setup Mode and Report-Only Mode

Read this file when Step 0 selects one of these modes.

## Setup Mode

Creates `sandbox-audit.json` for a repository so the whole team gets the same behaviour. Changes no code.

1. Find the repo root (git root / TFVC workspace root / folder with the `.sln`; ask if unclear). If `sandbox-audit.json` already exists there, show it and ask whether to **update** it or **stop**.
2. Run `scan.ps1 -ListProjects -SolutionRoot "<repo root>" -OutFile "<scratchpad>\sandbox-projects.json"`. It lists every project (`Kind`: Plugins / WorkflowActivities / both / Other; full-trust `Hint`s), the shared folders most linked by plug-in projects (`SharedFolderCandidates`), and every existing serializer class with `Reusable` / `Reasons`.
3. Show the developer a short overview: how many plug-in / workflow projects, which projects look like full trust, the top shared folders, and the serializer classes found.
4. Ask with AskUserQuestion (up to four questions in one call):
   - **Default target**: Dataverse Online / On-premises Sandbox / Ask every run
   - **PDF report**: Always, in the repo / Always, in Documents / Ask every run / Never
   - **Serializer**: Builtin helper (recommended) / one option per existing class that is Sandbox-safe or could be made so (name its path). If the team picks a class that is **not** Sandbox-safe today, say so plainly: it would need to be converted to `DataContractJsonSerializer` first (show the problems), and set the strategy only after the team confirms they will do that
   - **Shared helper folder**: the top `SharedFolderCandidates` (one option each) — a free-text answer is possible through the tool's own "Other"
5. Propose `skipProjects` from the projects with a full-trust `Hint` (as name patterns where possible, e.g. `*.Api`) and ask the developer to confirm or edit the list in chat.
6. For an `existing` serializer, fill `files` with the class **and** every file declaring a namespace it uses (interfaces, base classes), and write `serializeCall` / `deserializeCall` from its real API (e.g. `AppSerializer.Instance.Serialize({value})`). Set `dateStyle` from what it does (no `DateTimeFormat` on `DataContractJsonSerializer` → `msajax`; ISO format → `iso`).
7. Write `sandbox-audit.json` at the repo root (format: `references/config.md`). It must be **plain JSON — no `//` or `/* */` comments** (Windows PowerShell 5.1 rejects them); put any explanation, e.g. why each skip pattern exists, in the `notes` field as text. Then validate it: run `scan.ps1 -Project "<one plug-in project>" -SolutionRoot "<repo root>"` and confirm `Settings.Errors` is empty and, for `existing`, `SerializerCheck.SandboxSafe` is true. Fix and re-run until it is clean.
8. Show the final file and tell the developer to commit / check it in so the whole team uses it. Mention it can be edited by hand later — every setting is described in `references/config.md`.

## Report-Only Mode

An assessment without touching code — for estimating effort, reviewing before migrating, or showing a tech lead.

1. Step 1 (project, target, report question) and Step 2 (scanner) as usual. Skip Step 3 — nothing is edited.
2. Step 4 **analysis only**: read the files with hits, apply the Scope, Accepted, Shared File and Caller Verification rules, and decide what *would* be fixed. Do not edit any file and do not create the serializer.
3. Skip Steps 5–6. In Step 7, use the scanner's data: dependencies come from `DependencyCandidates` (say they are not confirmed by a build), version and signing from the scan. If a Release DLL already exists in the output folder, `build.ps1 -InspectOnly -Dll <path>` may be used to confirm dependencies, signature and size.
4. Summary (Step 8) with **"Would change"** instead of "Changes made" — every file, what would be replaced, and the lines — plus all the other sections. Start with: "Report only — no files were changed."
5. Step 9 if a report was requested: same data (no `ChangedPaths`, so no diff), with `Changes` describing the planned changes and the summary's first line in `NeedsDecision` or `NextSteps` ("Run the skill in migrate mode to apply these changes").
