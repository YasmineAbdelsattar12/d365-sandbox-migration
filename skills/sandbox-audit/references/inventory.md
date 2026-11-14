# Inventory Mode — what is registered in CRM vs. what is in the code

Read this when Step 0 selects **inventory**, or at the start of a batch (`batch.md`). It answers the first questions a developer has before migrating anything:

- How many custom plug-in assemblies are registered, and is each one **Isolation None** or **Sandbox**?
- Which registered assemblies have **no source code** in this repository?
- Which projects in the repository are **not registered** in this organization?
- Where do CRM and the code **differ** (version, classes), and what is stored on **Disk / GAC** (not allowed Online)?

It **only reads** from the organization (plug-in assemblies, plug-in types, steps) and changes nothing — not in CRM, not in the code.

## 1. Ask how to connect

Settings first: `crm.environment`, `crm.url` and `crm.auth` in `sandbox-audit.json` (`config.md`) answer the questions below — say which ones were used.

1. **Environment** — AskUserQuestion: **On-premises** / **Dataverse Online**.
2. **Address** — ask as a normal chat message (not AskUserQuestion):
   > What is the address of the CRM organization? On-premises usually `https://<server>/<OrgName>`; Online `https://<org>.crm<N>.dynamics.com`.
3. **Sign-in** — AskUserQuestion with the options for that environment:

   | Environment | Option | `-Auth` | Notes |
   |---|---|---|---|
   | On-premises | **My Windows login** (recommended) | `windows` | The account the developer is signed in with. Works for normal (Active Directory) on-premises |
   | On-premises | **Another account** | `credential` | A Windows password window opens on the developer's machine |
   | On-premises | **Login window** | `interactive` | For IFD / claims-based sites. Needs `Microsoft.Xrm.Data.PowerShell` and Windows PowerShell 5.1 |
   | Online | **Login window** (recommended) | `interactive` | Microsoft sign-in window (MFA works). Needs `Microsoft.Xrm.Data.PowerShell` and Windows PowerShell 5.1 |
   | Online | **Azure CLI** | `azcli` | Only if the developer already ran `az login` with an account that has access |

**Never ask for a password, client secret or token in the chat, and never put one on a command line or in a file.** If the developer pastes one anyway, don't use it — tell them to change it if it is a real password, and use a sign-in window instead.

The account needs read access to plug-in registrations (for example the **System Customizer** or **System Administrator** role).

**Module.** For `interactive`, check first: `powershell -NoProfile -Command "Get-Module -ListAvailable Microsoft.Xrm.Data.PowerShell"`. If it is missing, ask before installing (AskUserQuestion: **Install it for my user** / **Use another sign-in option**). Install with `powershell -NoProfile -Command "Install-Module Microsoft.Xrm.Data.PowerShell -Scope CurrentUser -Force"` — it comes from the PowerShell Gallery; the company may need to allow it.

## 2. Run it

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\crm-inventory.ps1" -Environment <onprem|online> -Url "<address>" -Auth <windows|credential|interactive|azcli> -SolutionRoot "<repo root>" -OutFile "<scratchpad or %TEMP%>\crm-inventory.json"
```

- Use `powershell.exe` (Windows PowerShell 5.1), not `pwsh`, for `interactive` — the login window needs it.
- Before running `credential` or `interactive`, tell the developer a sign-in window will open on their screen and to complete it.
- `-SolutionRoot` = the repository root (or the folder the developer gave). It runs `scan.ps1 -ListProjects` and compares. Without it only the CRM side is listed.
- Exit code 1 = the connection failed. Show `Error` and `ErrorHint` from the JSON, and offer another sign-in option or a URL fix. Never turn certificate checks off.

## 3. How the comparison works (say this when it matters)

| Status | Meaning |
|---|---|
| **Registered, with source** | A project builds an assembly with the same name (`AssemblyName` in the `.csproj`), or — if no name matches — a project contains the same plug-in / workflow class full names (`Namespace.Class`); then the note says the names differ |
| **Registered, no source** | No project matched. **Managed** = from a managed solution (Microsoft, an ISV, another team). **Unmanaged** = the source may be in another repository or branch, or lost — the team must find it before go-live, or confirm the assembly is not needed |
| **Source, not registered** | A project with plug-in / workflow classes that no registered assembly matched — new work, retired code, or registered in another organization. Projects in `skipProjects` and projects without plug-in classes are left out |
| **Version difference** | `AssemblyVersion` in the code ≠ the registered version. Major/minor different = the Plugin Registration Tool treats the new build as a **new assembly** (steps must be moved); build/revision = code changed since the last deployment |
| **Class difference** | Registered classes missing from the code (deleted or renamed — their steps break when the new build is registered), or classes in the code not registered yet |
| **Stored on Disk / GAC** | Must be re-registered in the **Database** — Sandbox and Online accept only Database |
| **Possibly unused** | No steps (plug-ins) or all steps disabled — ask the team whether it can be retired instead of migrated |

Only custom registrations are read (`customizationlevel = 1`), so Microsoft's own system assemblies are not listed. When the code builds the same assembly name in two projects, the note says so — check which one is deployed.

## 4. Tell the developer

In chat, short:

1. One line: organization, environment, how it connected.
2. Totals for **the team's own assemblies** (unmanaged, or built from this repository): N — X **None**, Y **Sandbox** · stored Database / Disk / GAC · steps. Then one separate line for **Microsoft / vendor** assemblies (managed, no source here): how many, how many None. Never mix the two: Microsoft's own are replaced by the Online versions, and a vendor's must come from the vendor — they are not migration work for the team and must not be counted as "no source".
3. If compared with source: with source / **no source** / **not registered** / version and class differences.
4. A table of the **Isolation None** assemblies (these are the migration work list): assembly, version, source project (or "no source"), steps, notes.
5. Lists for **Registered, no source** and **Source, not registered**, and anything on Disk / GAC.
6. Next step, for example: "8 projects need migration — run `batch report <folder>` for effort, or migrate one with `/d365-sandbox-migration:sandbox-audit <project>`." Projects already **Sandbox** in CRM are probably migrated — mention them as lower priority, not as done (the code may still have blocked APIs on paths not yet used).

**PDF** (ask, unless `report.enabled` decides):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill base dir>\scripts\make-report.ps1" -Inventory "<crm-inventory.json>" -OutDir "<report folder>" -Open
```

**Save the connection** — if no `crm` setting exists, offer once to save `environment`, `url` and `auth` into `sandbox-audit.json` so the team is not asked again. Never save passwords or tokens. Validate the file afterwards (`scan.ps1` reports settings errors).

## 5. With batch mode

At the start of **batch report** and **batch migrate** (after the folder is known), ask once: **Start with the CRM inventory?** — **Yes** / **No, only the code**. **Always ask** — never add the inventory silently, also when an inventory was already run earlier in the chat (then offer **Yes — reuse the one from <time>** / **Yes — read CRM again** / **No, only the code**).

If yes, run sections 1–2 with `-SolutionRoot "<repo root>"` (the whole repository, so assemblies from other folders are matched correctly), and:

- in chat, show **only the projects of this batch**: registered or not, None or Sandbox, differences. Do not list assemblies that belong to other folders (for example `Cs` assemblies in a batch on `Plugin`) — say in one line how many more the organization has and that `inventory` mode shows them all;
- pass `-Inventory "<crm-inventory.json>"` to `make-report.ps1` together with `-BatchData` — the report then starts with one section, **CRM registration of the projects in this batch** (one row per batch project). The full organization lists are only in the inventory report;
- in batch migrate, show which batch projects are already **Sandbox** in CRM and let the developer leave them out (AskUserQuestion), and mention registered assemblies with no source — they cannot be migrated by this tool.
