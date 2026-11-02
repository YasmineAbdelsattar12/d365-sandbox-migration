# Serializer Migration Rules

Read this whenever a file in scope uses `JavaScriptSerializer`, Newtonsoft.Json (`JsonConvert`, `JObject`, `[JsonProperty]` ...) or a wrapper around them. The code and format details are in `serializer-guide.md`.

## Serializer Migration

When a file uses `Newtonsoft.Json` or `JavaScriptSerializer`:

**Which serializer to call** comes from **Placing the Serializer** below — the team's configured class (`existing` strategy) or the builtin helper. The examples here use the builtin `AppSerializer`; with a custom `className`, use that name.

1. Replace, keeping the wire format identical (see `references/serializer-guide.md` → "Two date styles"):
   - `JsonConvert.SerializeObject(x)` / `DeserializeObject<T>(json)` → `AppSerializer.Serialize(x)` / `AppSerializer.Deserialize<T>(json)` (ISO dates, like Newtonsoft)
   - `JavaScriptSerializer.Serialize(x)` / `Deserialize<T>(json)` → `AppSerializer.Serialize(x, JsonDateStyle.MsAjax)` / `AppSerializer.Deserialize<T>(json, JsonDateStyle.MsAjax)` (`\/Date(...)\/` dates and `"null"`, like JavaScriptSerializer). **Never** use the ISO default for a JavaScriptSerializer replacement.
   - Calls through a wrapper that used one of these internally (e.g. `AppSerializer.Instance.Serialize(x)` from a separate helper DLL) → the same rule, based on which serializer the wrapper used.
2. Replace `[JsonProperty("x")]` → `[DataMember(Name = "x")]`
3. Remove `[JsonIgnore]` / `[ScriptIgnore]` (with `[DataContract]` on the class, unannotated members are excluded)
4. Add `[DataContract]` to the class and `[DataMember]` to EVERY member that should serialize
5. **Choose `Name` values carefully** — `DataContractJsonSerializer` is case-sensitive; the old serializers were not. Follow the table in `references/serializer-guide.md` → "Property Names Are Case-Sensitive". For any **deserialized** class whose real JSON casing you could not confirm, list it under **"Needs verification"**.
6. **DateTime members**: with the style rule in step 1 the format stays the same. Only a class with **local** `DateTime` members sent with `MsAjax` to a non-.NET receiver goes under **"Needs verification"** (the timestamp gets an offset suffix — see serializer-guide → "DateTime Handling").
7. Replace `JObject.Parse` → typed DTO + `AppSerializer.Deserialize<T>`
8. Get the serializer from **Placing the Serializer** below — never write a new copy without checking.

## Placing the Serializer

**First: the team's strategy (`SerializerCheck.Strategy`).**

**`existing`** — the team chose its own class in `sandbox-audit.json`:
1. If `SandboxSafe` is false → do **not** use it and do **not** edit it. Show its `Problems`, and ask (AskUserQuestion): **Use the builtin helper for this run** / **Stop — the team will fix its serializer first**. Note the decision under "Serializer decisions".
2. Otherwise, link **every** file in `SerializerCheck.Files` into the `.csproj` (unless `CompiledIntoThisProject`), using the project's existing `<Link>` folder convention, and add `SerializerCheck.Usings` to each calling file.
3. Replace calls using the templates: `SerializeCall` with `{value}` = the object expression; `DeserializeCall` with `{type}` = the target type and `{json}` = the JSON expression.
4. Read the class once and compare its behaviour with the serializer being replaced (date format vs `DateStyle`, dictionary format, `null` handling, runtime vs declared type). Every difference that affects a DTO being serialized goes under **"Needs verification"** — e.g. "the team serializer writes ISO dates; JavaScriptSerializer wrote `\/Date(...)\/` for `WorkOrderDto.DueDate`".
5. Never create the builtin helper when the strategy is `existing` and the class is Sandbox-safe.

**`builtin`** — the skill's helper from `references/serializer-guide.md`, with `SerializerCheck.ClassName` as the class name and `SerializerCheck.Namespace` (if set) as the namespace. If `SerializerCheck.File` is set, that is the file to reuse or create; if `Settings.SharedHelperFolder` is set, create it there. Otherwise continue with the rules below.

Check `ExistingAppSerializers` from the scan (or search the solution for `class AppSerializer` if the scanner could not run). A class is only **reusable** (`Reusable: true`) when it can be linked as one self-contained source file: static `Serialize<T>` / `Deserialize<T>` API, only `System.*` dependencies, no interface/base class, and no `JavaScriptSerializer` / Newtonsoft inside. Classes with the same name but a different design — typically a `public` instance class with `AppSerializer.Instance` and an `IJsonSerializer` interface in its own helper **project** — are **not** reusable for plug-ins: referencing that DLL would be a runtime dependency (❌ online for workflow activities), and its interface can't be linked on its own. **Never modify such a class** — it belongs to the projects that own it (often full-trust API/Portal code).

1. **A reusable one is already compiled into this project** (`CompiledIntoThisProject`) → use it. If `Upgrade` is true, replace its content with the current version from `references/serializer-guide.md` (same API plus `JsonDateStyle`), keep its namespace, and list its `LinkedBy` projects under "Projects to rebuild".
2. **A reusable one exists elsewhere** → add it to this `.csproj` as a linked file, using the same `<Link>` folder convention as the project's other linked files:
   ```xml
   <Compile Include="..\..\Shared\Crm.Common\AppSerializer.cs">
     <Link>Shared\AppSerializer.cs</Link>
   </Compile>
   ```
   If it is `public`, and this assembly references another assembly that also compiles it, change it to `internal` to avoid `CS0433` (list affected projects). Apply the `Upgrade` as in 1.
3. **No reusable one exists** → if `Settings.SharedHelperFolder` is set, create it there; else if the project already links files from a shared helper folder (most `linked` entries share a parent folder), create `AppSerializer.cs` there using the `internal` version from `references/serializer-guide.md`, with that folder's namespace, and link it. Only if the project has no linked files at all, create it in the project folder.
4. Add the matching `using <namespace>;` to every file that calls it. If a non-reusable `AppSerializer` in another namespace is also visible in that file, use the fully-qualified name to avoid ambiguity.
5. **Always explain the choice** in the summary section **"Serializer decisions"**: which `AppSerializer` was used (path, namespace, new / linked / upgraded) and, for every other `AppSerializer` in the solution, one line on why it was not used — taken from its `Reasons`. Developers see several classes with the same name in Solution Explorer, so this must never be silent.
