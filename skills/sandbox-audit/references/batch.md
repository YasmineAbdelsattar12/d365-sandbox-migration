# Batch Mode — a whole folder of projects

Read this when Step 0 selects **batch report** or **batch migrate**. The developer gives a folder (e.g. `D:\Repo\Crm\Cs`) that contains many plug-in / workflow activity projects.

| Invocation | Mode |
|---|---|
| `batch report <folder>` / `report batch <folder>` | **Batch report** — every project analysed from scanner data, one combined report, **no code changes** |
| `batch <folder>` / `batch migrate <folder>` | **Batch migrate** — the projects are migrated one after another |

## 1. Scan the folder (both modes)

1. Settings, target and report questions as in Step 1 — **once for the whole batch**.
2. Run:
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\batch-scan.ps1" -Folder "<folder>" -OutFile "<scratchpad or %TEMP%>\sandbox-batch.json"
   ```
   It runs `scan.ps1` on every `.csproj` under the folder (seconds per project) and writes:
   - `Projects[]` — per project: `Status` (`scanned` / `skipped` / `error`), `SkipReason`, `Kind`, `Framework`, files, `Blocked` / `Avoid` / `Review` (local files only, accepted findings excluded), `HttpCalls`, `UrlProblems`, `UrlsToConfirm`, `LoopRisks`, `DependencyCandidates`, `Signing`, `Effort` (Low / Medium / High), `OnlineEstimate` (`ok` / `warn` / `fail`) with `OnlineWhy`, and `ScanFile` (the full scanner JSON)
   - `SharedProblems[]` — linked / shared files with blocked APIs that several projects in the batch compile: `File`, `Apis`, `Members`, `Projects`
   - `RecommendedOrder` — easy projects first
   Skipped automatically: projects in `skipProjects`, projects with no plug-in / workflow classes, and names that look like full trust (API / Portal / web / test / console). Mention them; `-IncludeAll` scans them anyway if the developer insists.
3. Show the developer a compact table (project, effort, online estimate, main reason) and the shared problem files. Effort and online readiness are **estimates from raw scanner findings** — say so.

## 2. Batch report (no code changes)

1. For `SharedProblems`, read each file once and say whether the blocked member is reachable from plug-in code (Shared File Rule) — this is analysis only.
2. Optionally deepen a few projects the developer names: run Report-Only Mode (`modes.md`) on them.
3. Summary in chat: totals, the project table in recommended order, shared files to decide first, what blocks Dataverse Online and where, skipped projects with reasons, and the suggested next step (e.g. "migrate the 6 Low-effort projects first").
4. PDF (if requested or `report.enabled: true`):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\make-report.ps1" -BatchData "<sandbox-batch.json>" -OutDir "<report folder>" -Open
   ```

## 3. Batch migrate

### 3.1 Confirm the batch

- AskUserQuestion: **All N projects** / **Low-effort projects first (M)** / **Let me choose** (the developer then types names in chat). Recommend **5–10 projects per run**; for more, suggest several runs (the progress file makes that easy).
- Say the expected duration (roughly 10–20 minutes per project) and that Claude Code will ask permission for commands and edits unless the developer has allowed them (PowerShell scripts in the skill folder, edits in the repo).

### 3.2 Version control (before any edit)

**git**
- The working tree must be clean. If not → ask the developer to commit or stash first (never do it for them).
- Ask (AskUserQuestion), because batch mode commits on its own only with explicit permission:
  - **New branch + one commit per project** (recommended): `git switch -c sandbox/batch-<yyyyMMdd>`, then after each successful project `git add <only that project's changed files>` and `git commit -m "Sandbox migration: <Project>"`
  - **One commit per project on the current branch**
  - **No commits** — all changes stay uncommitted; the report lists the files per project
- Record the base commit and `git config user.name`.

**tfvc** — never check in automatically. Offer **Shelve each project** (`tf shelve "Sandbox <Project>" <changed files> /noprompt`) or **Leave all changes pending**. **none** — warn and ask to continue.

### 3.3 Progress file (resume)

Keep the batch state in `%LOCALAPPDATA%\sandbox-audit\batch-<repo name>-<folder name>.json` (outside the repo). Write it after every step:

```json
{
  "Mode": "migrate", "Folder": "D:\\Repo\\Crm\\Cs", "Target": "Dataverse Online",
  "Started": "2026-11-02T23:40:00", "Author": "<git user.name>", "SkillVersion": "<plugin version>",
  "Branch": "sandbox/batch-20261102", "BaseCommit": "a1b2c3d", "CommitMode": "per-project",
  "BatchScan": "<path of sandbox-batch.json>",
  "SharedDecisions": [ { "File": "<absolute path>", "Decision": "Fixed once / Left in place / Needs decision", "Reason": "..." } ],
  "Projects": [
    { "Name": "Contoso.Crm.Cs.Documents", "Status": "pending | migrated | needs-work | build-failed | error | stopped",
      "Commit": "e5f6071", "FilesModified": 2, "ChangedPaths": ["..."], "Build": "Success - 277 KB, signed",
      "OnlineVerdict": "ok | warn | fail", "OnlineVerdictText": "Needs work (1 item)",
      "Changes": ["..."], "NeedsVerification": ["..."], "NeedsDecision": ["..."], "Report": "<project PDF path>", "Notes": "..." }
  ],
  "Decisions": ["Collected at the end for the team"]
}
```

At the start of a batch migrate, if a progress file for the same folder exists with `pending` projects, ask: **Resume** (skip projects already done) / **Start over**.

### 3.4 Shared files first

For each entry in `SharedProblems`, decide **once**, following the Shared File Rule (`SKILL.md`), across all projects in the batch:
- reachable from plug-in code in any batch project → fix it once now (behaviour-identical fix), build-check one project that compiles it, and — with per-project commits — commit it alone as `Sandbox migration: shared files`
- not reachable anywhere → `Left in place`, with the evidence
- unclear, or linked by many projects outside the batch → `Needs decision`; projects leave it untouched

Record each in `SharedDecisions`. Every project then gets the same answer.

### 3.5 One project at a time, each in its own sub-agent

Process the projects **in order, one at a time** (never in parallel — they share helper files and the build). For each project, start a fresh sub-agent with the Agent tool (`general-purpose`) so long batches don't exhaust the conversation, with a self-contained prompt like:

```
Migrate one Dynamics 365 plug-in / workflow project to Sandbox using the d365-sandbox-migration skill.
Skill instructions: read <skill base dir>\SKILL.md and follow Migrate mode, Steps 2 and 4-8 (skip Step 1 questions, Step 3 and Step 9).
Project: <absolute .csproj path>   Repo root: <root>   Target: <Dataverse Online | on-prem>
Settings file: <path or none> (the scanner finds it).
Shared-file decisions already made for this batch - follow them, do not re-decide:
  - <file>: <Fixed once | Left in place | Needs decision> - <reason>
Do NOT ask questions: anything that needs a decision goes into NeedsDecision. Do NOT commit, check in or shelve.
Do NOT create a PDF report.
When done, reply with ONLY this JSON:
{ "Name": "...", "Status": "migrated|needs-work|build-failed|error", "FilesModified": n, "ChangedPaths": [...],
  "Build": "...", "OnlineVerdict": "ok|warn|fail", "OnlineVerdictText": "...",
  "Changes": [...], "NeedsVerification": [...], "NeedsDecision": [...], "Notes": "..." }
```

`Status`: `migrated` = built, nothing open · `needs-work` = built, with Needs decision / verification items or online ⚠️ / ❌ · `build-failed` = still failing after 5 attempts · `error` = could not run.

After each sub-agent:
1. **Check, don't trust**: confirm the build JSON / DLL exists for `migrated` and `needs-work`, and that `ChangedPaths` match `git status` for that project's files.
2. Commit per the chosen mode — only that project's `ChangedPaths`. For `build-failed`, do **not** commit; leave the changes for review and say so.
3. Update the progress file and tell the developer one line: "3/8 Contoso.Crm.Cs.Documents — needs work (1 URL to confirm), committed e5f6071".
4. If the developer interrupts, or usage limits are near, stop cleanly: mark the current project `stopped`, keep the progress file, and explain how to resume.

### 3.6 End of the batch

1. Collect every `NeedsDecision` item across projects into `Decisions`, deduplicate, and ask the developer about them **together** (or list them for the team if they prefer).
2. Summary in chat: per-project result table (status, commit, main open item), shared decisions, decisions for the team, projects to rebuild beyond the batch (from shared-file edits), and next steps (register each assembly in Sandbox; test list).
3. PDF (if requested or `report.enabled: true`):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\make-report.ps1" -BatchData "<sandbox-batch.json>" -BatchProgress "<progress file>" -OutDir "<report folder>" -Open
   ```
   For a detailed report of a single project, run the normal Step 9 for it afterwards.
