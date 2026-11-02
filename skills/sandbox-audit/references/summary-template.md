# Summary Template (Step 8)

Use these sections in this order. Leave out sections that are empty, except Migration Summary, Changes Made and Next Steps.

## Migration Summary

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
Baseline: git commit <hash> / TFVC workspace version / no version control — clean or with prior uncommitted changes
Settings: <path of sandbox-audit.json> / none (defaults)
Target: Dataverse Online / On-premises Sandbox
Online readiness: ✅ Ready / ⚠️ Needs work (N items) / ❌ Blocked (N items)
```

## Linked & Shared Files Scanned

List every linked/shared file with **[LINKED]** / **[SHARED]**, its status, and `SharedBy` count when known.

## Changes Made

For each modified file: path (with **[LINKED]** / **[SHARED]** when applicable), what changed, lines affected.

## Accepted Findings

Every finding with `Accepted`, with file, line, API and the team's reason. Say where each acceptance comes from (`sandbox-audit.json` or inline comment).

## Blocked APIs Left in Place

Table: location · blocked API · evidence it never runs in this assembly.

## Shared Helper Decisions

Only when serialization or a shared helper (`references/shared-helpers.md`) was involved. One line per helper used, and one per same-named class elsewhere that was not used (with its `Reasons`). Example:

```
Strategy: builtin (sandbox-audit.json) / existing team class / default
Used:     Shared\Crm.Common\AppSerializer.cs (Contoso.Crm.Common) — linked, upgraded to JsonDateStyle version
Not used: Shared\Contoso.Common.Utilities\AppSerializer.cs (Contoso.Common.Utilities) — instance/IJsonSerializer design in its own DLL,
          still uses JavaScriptSerializer. Left unchanged (owned by Contoso.Common.Utilities).
Calls:    3 JavaScriptSerializer calls → AppSerializer.Serialize(x, JsonDateStyle.MsAjax) — JSON unchanged
Helper:   MimeTypeHelper — created in Shared\Crm.Common (Contoso.Crm.Common), linked; replaces 2 MimeMapping calls
Not used: ProjB\Utils\QueryStringHelper.cs — returns Dictionary, not a drop-in for HttpUtility.ParseQueryString; left unchanged
```

## Left As-Is On Purpose

E.g. `.Result` kept because of an `AggregateException` catch — with the one-line change on offer.

## Needs Verification

Deserialized DTOs whose JSON casing was not confirmed; serialized classes whose DateTime format changed. Say exactly what to check.

## Needs Decision

Shared-file violations not edited because of their reach (rule 4 of the Shared File Rule).

## Projects to Rebuild

Every project in `SharedBy` of any shared file that was edited — they all compile the changed file.

## References & Packages

Removed / kept (with reason) / added.

## Online Readiness

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

## Next Steps for Developer

1. **If a file was added to the `.csproj`** (e.g. `AppSerializer.cs` linked or created): in Visual Studio, right-click the project → **Reload Project** (or reopen the solution) — Solution Explorer does not show files added outside VS until it reloads.
2. Review the diff and commit / check in this project's migration on its own.
3. Open **XrmToolBox → Plugin Registration Tool** (connected to the target environment), update the assembly with the `.dll` from `bin\Release\`, set Isolation Mode to **Sandbox** (online: always Sandbox), and confirm all steps are still registered.
4. Online: enable the **Plug-in Trace Log** (Settings → Administration → System Settings → Customization) for the first test runs — it replaces Event Log / file logging.
5. Rebuild and re-register every project under "Projects to rebuild".
6. Test: [list key scenarios based on what changed — every HTTP call, every serialized payload, every "Needs verification" item].
