# Report Data Schema (`report-data.json`)

Written by Claude at the end of the run and passed to `scripts/make-report.ps1 -Data`. The script adds the scanner results (`-Scan`) and the real git diff (`-Repo` + `BaseCommit` + `ChangedPaths`) on its own — do not copy those into this file.

Write the file as **UTF-8**. Every field is optional; empty sections are left out of the report. Write plain text only (no Markdown, no HTML) — the script escapes everything.

**Status values** (any field named `Status`, `BuildResult`, `OnlineVerdict`): `ok` / `warn` / `fail` (also accepted: Ready / Check / Blocked / Success / ✅ / ⚠️ / ❌). They render as green / amber / red badges.

```json
{
  "Project": "LinkDev.Common.Crm.Cs.Documents",
  "Assembly": "LinkDev.Common.Crm.Cs.Documents.dll",
  "Target": "Dataverse Online",
  "SkillVersion": "1.4.0",
  "Author": "<git config user.name>",
  "BaseCommit": "<short hash recorded in Step 3>",

  "Summary": {
    "FilesScanned": 78, "Local": 16, "Linked": 62, "Shared": 0,
    "FilesModified": 5,
    "NewFiles": ["Helper\\LinkDev.Common.Crm.Utilities\\AppSerializer.cs"],
    "BuildResult": "Success",
    "DllPath": "bin\\Release\\LinkDev.Common.Crm.Cs.Documents.dll",
    "DllSize": "277 KB (limit 16 MB)",
    "DllVersion": "1.0.0.0",
    "PublicKeyToken": "a1b2c3d4e5f60718",
    "GitBaseline": "clean",
    "OnlineVerdict": "warn",
    "OnlineVerdictText": "Needs work (2 items)"
  },

  "Changes": [
    { "File": "MigrateNotesToDocuments.cs", "Tag": "",
      "Description": ["JavaScriptSerializer replaced with AppSerializer.Serialize", "TLS 1.2, 90 s timeout, KeepAlive off"],
      "Lines": "12, 88-104" },
    { "File": "Helper\\...\\Logger.cs", "Tag": "LINKED", "Description": ["..."], "Lines": "..." }
  ],

  "LeftInPlace": [ { "Location": "Tools.cs:694 GetMimeType", "Api": "Registry", "Evidence": "No call sites in the 78 compiled files" } ],
  "LeftOnPurpose": [".Result kept in MigrateFileLocations.cs:120 - code catches AggregateException"],
  "NeedsVerification": ["CreateFileLocationsModel: DateTime members now serialize as ISO 8601 - confirm the API accepts it"],
  "NeedsDecision": ["Logger.cs EventLog - linked by 64 projects, call path unclear"],
  "ProjectsToRebuild": ["LinkDev.Common.Crm.Cs.StageConfiguration"],

  "References": {
    "Removed": ["System.Web", "System.DirectoryServices"],
    "Kept": [ { "Name": "System.Web.Extensions", "Reason": "dead code in linked Logger.cs needs it to compile" } ],
    "Added": []
  },

  "Dependencies": [ { "Name": "Newtonsoft.Json", "Version": "13.0.0.0", "Status": "fail", "Note": "Workflow activities cannot use plug-in packages" } ],

  "Online": {
    "Checks": [
      { "Name": "Target framework", "Status": "ok", "Detail": ".NET 4.6.2" },
      { "Name": "Signed", "Status": "ok", "Detail": "LinkDev.Gea.Crm.SigningKey.snk" },
      { "Name": "Version", "Status": "ok", "Detail": "1.0.0.0 -> 1.0.0.0 (in-place update OK)" },
      { "Name": "Size", "Status": "ok", "Detail": "277 KB (limit 16 MB)" }
    ],
    "HttpCalls": [
      { "Location": "MigrateNotesToDocuments.Execute", "Call": "POST", "UrlSource": "Config record DocumentsApiUrl", "Status": "warn", "Note": "Confirm it is a public HTTPS DNS name" }
    ],
    "LoopRisks": [ { "Location": "MigrateNotesToDocuments.cs:140", "Call": "RetrieveMultiple + HTTP per note", "Note": "Large batches may exceed the 2-minute limit" } ],
    "GoLiveActions": ["Confirm DocumentsApiUrl points to a public HTTPS endpoint"]
  },

  "NextSteps": ["Reload the project in Visual Studio", "Commit this migration", "Update the assembly in the Plugin Registration Tool (Sandbox)"],
  "Tests": ["Run MigrateNotesToDocuments on a record with 3 notes and confirm the POST succeeds"],

  "ChangedPaths": ["D:\\Gea\\Crm\\Cs\\LinkDev.Common.Crm.Cs.Documents\\MigrateNotesToDocuments.cs", "..."]
}
```

`ChangedPaths` — every file modified **or created** during the run, absolute paths: `.cs` files, linked files, the `.csproj`, `packages.config`. New (untracked) files are shown in full as added.
