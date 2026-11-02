# Team Settings — `sandbox-audit.json`

One optional file per repository that tells the skill how **this team** works. Commit it, so every developer gets the same behaviour. Without it, the skill uses the defaults below and detects what it can.

**Format**: plain JSON — no comments (use `notes` instead), double-quoted names and strings.

**Where**: the repository root (or any folder above the project — the scanner looks in the project folder and every parent folder up to the solution root). Paths inside the file are relative to the file's folder. Create it with **setup mode** (`/d365-sandbox-migration:sandbox-audit setup`) or copy one of the files in the plugin's `examples/` folder.

## All settings

| Setting | Values | Default | What it does |
|---|---|---|---|
| `version` | `1` | `1` | Format version of this file |
| `target` | `online` / `onprem` / `ask` | `ask` | Target environment. `online` / `onprem` skip the question at the start of every run |
| `report.enabled` | `true` / `false` / `ask` | `ask` | PDF report. `true` = always create, `false` = never (and don't ask), `ask` = ask at the start (and once more at the end) |
| `report.location` | `repo` / `documents` / a folder path / `ask` | `ask` | `repo` = `<repo root>/docs/sandbox-migration`, `documents` = `Documents/Sandbox Migration Reports` |
| `sharedHelperFolder` | folder path | detected | Where **every** shared helper file is created and linked from — the serializer and the helpers in `shared-helpers.md` (`MimeTypeHelper`, `QueryStringHelper`, `EnvironmentVariableHelper`) |
| `sharedHelperNamespace` | namespace | `serializer.namespace`, else the folder's namespace | Namespace for new shared helper files |
| `serializer.strategy` | `builtin` / `existing` | `builtin` | `builtin` = the skill's own Sandbox-safe helper. `existing` = the team's own class |
| `serializer.className` | C# name | `AppSerializer` | Class name the skill looks for / creates |
| `serializer.namespace` | namespace | folder's namespace | `builtin` only — namespace of the created helper |
| `serializer.file` | file path | `<sharedHelperFolder>/<className>.cs` | `builtin` only — exact file to create / reuse |
| `serializer.files` | list of file paths | — | `existing` only — **every** source file the class needs (the class and its interfaces / base types). They are linked into each plug-in project |
| `serializer.serializeCall` | template | — | `existing` only — how to call it. Placeholders: `{value}` |
| `serializer.deserializeCall` | template | — | `existing` only. Placeholders: `{type}`, `{json}` |
| `serializer.usings` | list of namespaces | — | `existing` only — `using` lines to add where it is called |
| `serializer.dateStyle` | `msajax` / `iso` | — | `existing` only — which date format the class writes (`msajax` = `\/Date(...)\/` like JavaScriptSerializer, `iso` = like Newtonsoft). Used to warn when a replacement would change the JSON |
| `skipProjects` | list of project-name patterns (`*` wildcard) | — | Projects that are never migrated or suggested (API, Portal, tests) |
| `http.timeoutSeconds` | 1–110 | `90` | Timeout set on outbound HTTP calls (the platform stops a plug-in at 120 s) |
| `acceptedFindings` | list (below) | — | Findings the team reviewed and accepted — they are reported as **Accepted**, not fixed |
| `notes` | text or list of texts | — | Free text for the team (ignored by the skill). Use it for explanations — JSON does not allow `//` comments |

### `acceptedFindings` entries

```json
{ "file": "Helper/Logger/Logger.cs", "api": "EventLog", "line": 0, "reason": "Never called from plug-ins - reviewed by A. Hassan, 2026-11-02" }
```

| Field | Required | Meaning |
|---|---|---|
| `file` | yes | Path relative to this file, or a pattern with `*` (e.g. `**/Legacy*.cs`) |
| `api` | no | Finding name or category as the scanner reports it (`EventLog`, `File.*`, `FileSystem`, `URL`, `HTTP call`, ...). Empty = every finding in the file |
| `line` | no | Only this line. `0` / missing = any line |
| `reason` | strongly recommended | Why it is acceptable — shown in the summary and the PDF |

**Inline alternative** — a comment on the same line or the line above:

```csharp
// sandbox-ignore: only used by the on-prem test harness
File.WriteAllText(path, json);

var url = "http://10.0.0.5/api"; // sandbox-ignore: replaced by the release pipeline
```

Use accepted findings for things the team decided on, not to hide problems: every accepted item is still listed, with its reason, in the summary and the report.

## Serializer strategy — which one to choose

| Situation | Choose |
|---|---|
| No team serializer, or the team's one uses `JavaScriptSerializer` / Newtonsoft | `builtin` |
| The team already has a **Sandbox-safe** serializer (uses `DataContractJsonSerializer`) and wants it everywhere | `existing` |

For `existing`, the scanner checks the listed files before every run: no blocked APIs, and every non-`System` namespace they use must be declared in one of the listed files (so linking them is enough). If the check fails, the skill does not touch the class and asks whether to use `builtin` for that run.

Linking a `public` class into many plug-in assemblies is fine as long as no single project references two of those assemblies and uses the class from both; if that happens the compiler reports `CS0433` — make the class `internal` or keep one assembly per project.

## Example — builtin serializer

```json
{
  "version": 1,
  "target": "online",
  "report": { "enabled": "ask", "location": "repo" },
  "sharedHelperFolder": "Shared/Crm.Common",
  "sharedHelperNamespace": "Contoso.Crm.Common",
  "serializer": { "strategy": "builtin", "className": "AppSerializer", "namespace": "Contoso.Crm.Common" },
  "skipProjects": ["*.Api", "*.Portal", "*.Tests"],
  "http": { "timeoutSeconds": 90 },
  "acceptedFindings": []
}
```

## Example — the team's own serializer

```json
{
  "version": 1,
  "target": "online",
  "report": { "enabled": true, "location": "repo" },
  "sharedHelperFolder": "Helper/Contoso.Common.Crm.Utilities",
  "serializer": {
    "strategy": "existing",
    "className": "AppSerializer",
    "files": [
      "Helper/Contoso.Common.Utilities/AppSerializer.cs",
      "Helper/Contoso.Common.Utilities/Interfaces/IJsonSerializer.cs"
    ],
    "serializeCall": "AppSerializer.Instance.Serialize({value})",
    "deserializeCall": "AppSerializer.Instance.Deserialize<{type}>({json})",
    "usings": ["Contoso.Common.Utilities"],
    "dateStyle": "msajax"
  },
  "skipProjects": ["*.Api", "*.Portal", "Contoso.Common.Utilities"],
  "acceptedFindings": [
    { "file": "Helper/Logger/Logger.cs", "api": "EventLog", "reason": "Never called from plug-ins - reviewed 2026-11-02" }
  ]
}
```

The scanner reports problems in this file at the top of every run: **errors** (invalid values, missing required fields — the skill stops and shows them) and **warnings** (unknown settings, accepted findings without a reason).
