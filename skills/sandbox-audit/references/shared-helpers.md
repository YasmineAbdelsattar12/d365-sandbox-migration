# Shared Helpers

Some Sandbox fixes need a small helper method instead of a one-line replacement. These helpers are **shared**: one file each, in the team's shared helper folder, linked into every project that needs it — never a private copy per project. The serializer (`AppSerializer`) follows the same idea and has its own rules in `serializer-rules.md`.

## The helpers

| Helper (class / file) | Replaces | Call |
|---|---|---|
| `MimeTypeHelper` | `MimeMapping.GetMimeMapping(fileName)` (System.Web) | `MimeTypeHelper.GetMimeType(fileName)` |
| `QueryStringHelper` | `HttpUtility.ParseQueryString(query)` (System.Web) | `QueryStringHelper.ParseQueryString(query)` |
| `EnvironmentVariableHelper` | `ConfigurationManager.AppSettings[...]`, `app.config` / `Settings.Default`, `Environment.GetEnvironmentVariable` — **only when the team decides** the value moves to a Dataverse environment variable | `EnvironmentVariableHelper.Get(service, "schema_name")` |

Rules for every helper:

- `internal static class`, one class per file, file name = class name. `internal` so the same file can be linked into many assemblies without `CS0433`.
- Depends only on `System.*` and the CRM SDK (`Microsoft.Xrm.Sdk*`), so linking the single file is enough.
- Behaves like the API it replaces (tested in .NET): same return type and the same results for missing values, so callers don't change behaviour.
- Use exactly the code below; set the namespace (see placement). Don't add more helpers than the fixes need.

## Placement — same for every helper

The scanner lists every class with these names anywhere in the solution in `ExistingHelpers[]` (`Name`, `Path`, `Namespace`, `CompiledIntoThisProject`, `LinkedBy`, `OwnedBy`, `Reusable`, `Reasons[]`).

1. **Already compiled into this project and `Reusable`** → use it.
2. **Exists elsewhere and `Reusable`** → link that file into this `.csproj` (same `<Link>` folder convention as the project's other linked files). Never copy it.
3. **Exists but not `Reusable`** (blocked APIs inside, external dependencies) → don't use it and **don't modify it**; say why under "Shared helper decisions".
4. **Doesn't exist** → create `<ClassName>.cs` in `Settings.SharedHelperFolder` (if set; otherwise the folder most linked files of this project come from; only if the project links nothing, the project folder), with namespace `Settings.SharedHelperNamespace` → else the serializer namespace → else the folder's namespace. Then link it.
5. Add the `using` for the helper's namespace to every file that calls it.
6. Changing a helper file that already existed is a shared-file edit: list every project in its `LinkedBy` under "Projects to rebuild".
7. Report every helper decision under **"Shared helper decisions"** in the summary: created / linked / reused, path, and for helpers not used, why.

## Behaviour notes for "Needs verification"

- `MimeTypeHelper` knows the common document, image, audio, video and archive types. Anything else returns `application/octet-stream` — the same fallback as `MimeMapping`, but `MimeMapping` knew more rare types. If the code depends on a specific rare type, list it under "Needs verification".
- `QueryStringHelper` returns a `NameValueCollection` exactly like `HttpUtility.ParseQueryString` (missing key → `null`, repeated key → `"a,b"`, case-insensitive keys, `+` → space). Code that used the result keeps working unchanged.
- `EnvironmentVariableHelper` needs the value to exist as an environment variable in every environment (dev / test / prod) — moving a setting there is a team decision. Until it is made, report `ConfigurationManager` / `app.config` reads under "Needs decision" instead of replacing them.

## MimeTypeHelper.cs

```csharp
using System;
using System.Collections.Generic;
using System.IO;

namespace Shared.Helper.Namespace
{
    /// <summary>Sandbox-safe replacement for System.Web.MimeMapping.GetMimeMapping.</summary>
    internal static class MimeTypeHelper
    {
        private static readonly Dictionary<string, string> Types = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { ".pdf", "application/pdf" }, { ".rtf", "application/rtf" }, { ".txt", "text/plain" }, { ".csv", "text/csv" },
            { ".htm", "text/html" }, { ".html", "text/html" }, { ".xml", "text/xml" }, { ".json", "application/json" },
            { ".js", "application/javascript" }, { ".css", "text/css" },
            { ".doc", "application/msword" }, { ".dot", "application/msword" },
            { ".docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
            { ".xls", "application/vnd.ms-excel" },
            { ".xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
            { ".ppt", "application/vnd.ms-powerpoint" },
            { ".pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
            { ".odt", "application/vnd.oasis.opendocument.text" }, { ".ods", "application/vnd.oasis.opendocument.spreadsheet" },
            { ".msg", "application/vnd.ms-outlook" }, { ".eml", "message/rfc822" },
            { ".png", "image/png" }, { ".jpg", "image/jpeg" }, { ".jpeg", "image/jpeg" }, { ".jpe", "image/jpeg" },
            { ".gif", "image/gif" }, { ".bmp", "image/bmp" }, { ".tif", "image/tiff" }, { ".tiff", "image/tiff" },
            { ".svg", "image/svg+xml" }, { ".ico", "image/x-icon" }, { ".webp", "image/webp" },
            { ".mp3", "audio/mpeg" }, { ".wav", "audio/wav" }, { ".mp4", "video/mp4" }, { ".avi", "video/x-msvideo" },
            { ".mov", "video/quicktime" }, { ".wmv", "video/x-ms-wmv" },
            { ".zip", "application/x-zip-compressed" }, { ".7z", "application/x-7z-compressed" },
            { ".rar", "application/x-rar-compressed" }, { ".gz", "application/x-gzip" }
        };

        /// <summary>Returns the MIME type for a file name or extension; "application/octet-stream" when unknown (same fallback as MimeMapping).</summary>
        public static string GetMimeType(string fileName)
        {
            if (string.IsNullOrEmpty(fileName)) return "application/octet-stream";
            string ext = fileName.StartsWith(".") && fileName.IndexOf('.', 1) < 0 ? fileName : Path.GetExtension(fileName);
            string type;
            return !string.IsNullOrEmpty(ext) && Types.TryGetValue(ext, out type) ? type : "application/octet-stream";
        }
    }
}
```

## QueryStringHelper.cs

```csharp
using System;
using System.Collections.Specialized;

namespace Shared.Helper.Namespace
{
    /// <summary>Sandbox-safe replacement for System.Web.HttpUtility.ParseQueryString.</summary>
    internal static class QueryStringHelper
    {
        /// <summary>
        /// Same behaviour as HttpUtility.ParseQueryString: returns a NameValueCollection (missing key -> null,
        /// repeated keys -> "a,b"), case-insensitive keys, '+' decoded as a space, leading '?' ignored.
        /// </summary>
        public static NameValueCollection ParseQueryString(string query)
        {
            var result = new NameValueCollection(StringComparer.OrdinalIgnoreCase);
            if (string.IsNullOrEmpty(query)) return result;
            if (query[0] == '?') query = query.Substring(1);

            foreach (var pair in query.Split('&'))
            {
                if (pair.Length == 0) continue;
                int eq = pair.IndexOf('=');
                if (eq < 0)
                {
                    result.Add(null, Decode(pair));
                }
                else
                {
                    result.Add(Decode(pair.Substring(0, eq)), Decode(pair.Substring(eq + 1)));
                }
            }
            return result;
        }

        private static string Decode(string s)
        {
            return Uri.UnescapeDataString(s.Replace('+', ' '));
        }
    }
}
```

## EnvironmentVariableHelper.cs

```csharp
using Microsoft.Xrm.Sdk;
using Microsoft.Xrm.Sdk.Query;

namespace Shared.Helper.Namespace
{
    /// <summary>Reads a Dataverse environment variable (replacement for ConfigurationManager / app.config / Environment.GetEnvironmentVariable).</summary>
    internal static class EnvironmentVariableHelper
    {
        /// <summary>Returns the current value (environmentvariablevalue) or, if none, the default value. Null when the variable does not exist.</summary>
        public static string Get(IOrganizationService service, string schemaName)
        {
            var query = new QueryExpression("environmentvariabledefinition")
            {
                ColumnSet = new ColumnSet("defaultvalue"),
                TopCount = 1
            };
            query.Criteria.AddCondition("schemaname", ConditionOperator.Equal, schemaName);
            var valueLink = query.AddLink("environmentvariablevalue", "environmentvariabledefinitionid", "environmentvariabledefinitionid", JoinOperator.LeftOuter);
            valueLink.EntityAlias = "v";
            valueLink.Columns = new ColumnSet("value");

            var result = service.RetrieveMultiple(query);
            if (result.Entities.Count == 0) return null;

            var entity = result.Entities[0];
            var current = entity.GetAttributeValue<AliasedValue>("v.value");
            if (current != null && current.Value != null) return current.Value.ToString();
            return entity.GetAttributeValue<string>("defaultvalue");
        }
    }
}
```
