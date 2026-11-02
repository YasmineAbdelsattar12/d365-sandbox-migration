# Serializer Replacement Guide

Replace `JavaScriptSerializer` (System.Web) and `Newtonsoft.Json` with `DataContractJsonSerializer` (safe in Sandbox).

## Quick Reference: Attribute Mapping

| Newtonsoft / JavaScriptSerializer | DataContract Equivalent |
|---|---|
| `[JsonProperty("name")]` | `[DataMember(Name = "name")]` |
| `[JsonIgnore]` | Omit `[DataMember]` (class must have `[DataContract]`) |
| `[JsonRequired]` | `[DataMember(IsRequired = true)]` |
| `[JsonConverter]` | `[KnownType(typeof(...))]` on base class |
| `[JsonConstructor]` | Parameterless constructor (required) |
| `[ScriptIgnore]` | Omit `[DataMember]` (class must have `[DataContract]`) |
| No attribute needed | `[DataMember]` required on every property to serialize |

## Critical Rule: [DataContract] Is Opt-In

Once `[DataContract]` is added to a class, **only** properties marked with `[DataMember]` will serialize. Forgetting `[DataMember]` on a property means it silently disappears from the JSON output.

```csharp
// WRONG — Name will be missing from JSON output!
[DataContract]
public class Contact
{
    [DataMember]
    public string Id { get; set; }
    
    public string Name { get; set; }  // NOT serialized!
}

// CORRECT
[DataContract]
public class Contact
{
    [DataMember(Name = "id")]
    public string Id { get; set; }
    
    [DataMember(Name = "name")]
    public string Name { get; set; }
}
```

## Critical Rule: Property Names Are Case-Sensitive

`JavaScriptSerializer` and Newtonsoft match JSON property names **case-insensitively** when deserializing. `DataContractJsonSerializer` is **case-sensitive**. A mismatch throws no error — the property silently comes back `null` / default.

```csharp
// JSON from the API: {"fileIds":"abc"}

// Newtonsoft / JavaScriptSerializer: FileIds = "abc" (case-insensitive match)
// DataContractJsonSerializer:        FileIds = null  (no match, no error!)
public List<Guid> FileIds;

// CORRECT — Name must match the JSON exactly
[DataMember(Name = "fileIds")]
public List<Guid> FileIds;
```

How to choose the `Name` value:

| Situation | `Name` to use |
|---|---|
| Class is only **serialized** (we send it) | The C# member name as written — `JavaScriptSerializer` and Newtonsoft (default settings) output member names unchanged, so the JSON stays identical |
| Class is **deserialized** (we receive it) | The exact casing of the JSON the other side sends. Find it from: `[JsonProperty("x")]` if present, sample JSON / tests / API docs in the repo, or the code that produces the JSON |
| Newtonsoft used `CamelCasePropertyNamesContractResolver` or `NamingStrategy` | The transformed name (e.g. `FileIds` → `fileIds`) — check the `JsonSerializerSettings` in use |
| Casing of incoming JSON cannot be determined | Use the C# member name AND list the class under **"Needs verification"** in the summary so the developer checks it against a real payload |

## DTO Visibility Rule

In partial trust, DTO classes used with `DataContractJsonSerializer` **must be public**. Internal or private classes throw:

```
SerializationException: Type 'MyNamespace.MyDto' cannot be serialized in partial trust because it is not public.
```

Fix: Change `internal class` to `public class`.

## Reusable AppSerializer Helper

Use this helper throughout the codebase to replace all `JsonConvert` / `JavaScriptSerializer` calls.

**Where it goes**: never create a new copy per project without checking first. Follow "Placing AppSerializer" in `SKILL.md` — reuse an existing copy in the solution, or create one in the shared helper folder and add it to each project as a linked file.

**Why `internal`**: the same file gets linked into many assemblies. If it were `public`, a project that references two of those assemblies would get `CS0433: type exists in both` errors. `internal` keeps each copy private to its own assembly.

**Namespace**: use the namespace of the folder it lives in (e.g. the shared helper library's root namespace), and add the matching `using` to every file that calls it.

**Two date styles** (`JsonDateStyle`), so the JSON on the wire stays the same as before the migration:

| Call | Dates written as | `null` object | Use when replacing |
|---|---|---|---|
| `AppSerializer.Serialize(x)` / `Deserialize<T>(json)` | ISO 8601 `"2026-11-02T08:00:00Z"` | `null` | Newtonsoft (`JsonConvert`) |
| `AppSerializer.Serialize(x, JsonDateStyle.MsAjax)` / `Deserialize<T>(json, JsonDateStyle.MsAjax)` | `"\/Date(1793606400000)\/"` | `"null"` | `JavaScriptSerializer` |

Tested output: a UTC `DateTime` in `MsAjax` style is byte-for-byte what `JavaScriptSerializer` wrote. A **local** `DateTime` gets the same timestamp plus an offset suffix (`"\/Date(1793606400000+0200)\/"`) — `DataContractJsonSerializer` reads it back correctly (tested), and Newtonsoft and `JavaScriptSerializer` parse the offset suffix too. If a serialized class has **local** `DateTime` members and the receiver is not .NET, list it under "Needs verification". `MsAjax` deserialization accepts both the plain and the suffixed form.

```csharp
using System;
using System.IO;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;

namespace <Shared.Helper.Namespace>
{
    /// <summary>How DateTime values are written and read.</summary>
    internal enum JsonDateStyle
    {
        /// <summary>ISO 8601, e.g. "2026-11-02T10:00:00Z". Same as Newtonsoft.Json defaults.</summary>
        Iso8601 = 0,

        /// <summary>Microsoft AJAX format, e.g. "\/Date(1793613600000)\/". Same as JavaScriptSerializer.
        /// Also returns "null" (not null) for a null object, like JavaScriptSerializer.</summary>
        MsAjax = 1
    }

    /// <summary>Sandbox-safe JSON helper (DataContractJsonSerializer).</summary>
    internal static class AppSerializer
    {
        private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

        // 'FFFFFFF' = optional fractional seconds; 'K' = "Z" for UTC, "+03:00" for local, nothing for Unspecified.
        private const string IsoDateFormat = "yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK";

        private static DataContractJsonSerializerSettings CreateSettings(JsonDateStyle dates)
        {
            var settings = new DataContractJsonSerializerSettings { UseSimpleDictionaryFormat = true };
            if (dates == JsonDateStyle.Iso8601)
            {
                settings.DateTimeFormat = new DateTimeFormat(IsoDateFormat);
            }
            return settings;
        }

        public static string Serialize<T>(T obj)
        {
            return Serialize(obj, JsonDateStyle.Iso8601);
        }

        public static string Serialize<T>(T obj, JsonDateStyle dates)
        {
            if (obj == null) return dates == JsonDateStyle.MsAjax ? "null" : null;
            var serializer = new DataContractJsonSerializer(typeof(T), CreateSettings(dates));
            using (var ms = new MemoryStream())
            {
                serializer.WriteObject(ms, obj);
                return Utf8NoBom.GetString(ms.ToArray());
            }
        }

        public static T Deserialize<T>(string json)
        {
            return Deserialize<T>(json, JsonDateStyle.Iso8601);
        }

        public static T Deserialize<T>(string json, JsonDateStyle dates)
        {
            if (string.IsNullOrEmpty(json) || json == "null") return default(T);
            var serializer = new DataContractJsonSerializer(typeof(T), CreateSettings(dates));
            using (var ms = new MemoryStream(Utf8NoBom.GetBytes(json)))
            {
                return (T)serializer.ReadObject(ms);
            }
        }
    }
}
```

**If the solution already has an `AppSerializer`** that the scanner marks `Upgrade` (old `...fffZ` format, or no `JsonDateStyle`): replace its whole content with the version above, keeping its namespace. The public API is unchanged (`Serialize<T>(T)` / `Deserialize<T>(string)` still exist), so existing callers keep compiling and behave the same; only the new overloads are added. The old `...fffZ` format wrote local times with a `Z` suffix (wrong by the UTC offset) and threw on dates without exactly 3 fractional digits.

## Replacing JavaScriptSerializer

```csharp
// BEFORE (blocked — System.Web)
using System.Web.Script.Serialization;
var serializer = new JavaScriptSerializer();
string json = serializer.Serialize(myObject);
var obj = serializer.Deserialize<MyType>(json);

// AFTER — MsAjax keeps JavaScriptSerializer's \/Date(...)\/ dates and "null" output
string json = AppSerializer.Serialize(myObject, JsonDateStyle.MsAjax);
var obj = AppSerializer.Deserialize<MyType>(json, JsonDateStyle.MsAjax);
```

Also different from `JavaScriptSerializer` (both styles): property names are case-sensitive when deserializing (see above), and members are written in alphabetical order unless `[DataMember(Order = n)]` is set — JSON receivers normally don't care about order.

## Replacing Newtonsoft.Json

```csharp
// BEFORE (blocked if ILMerged)
using Newtonsoft.Json;
string json = JsonConvert.SerializeObject(myObject);
var obj = JsonConvert.DeserializeObject<MyType>(json);

// AFTER
string json = AppSerializer.Serialize(myObject);
var obj = AppSerializer.Deserialize<MyType>(json);
```

### Replacing JObject / JArray / JToken

Dynamic JSON access with `JObject` has no direct equivalent. Convert to typed DTOs:

```csharp
// BEFORE
var jobj = JObject.Parse(json);
string name = (string)jobj["contact"]["name"];
var items = jobj["items"].ToObject<List<Item>>();

// AFTER — define typed DTOs
[DataContract]
public class ApiResponse
{
    [DataMember(Name = "contact")]
    public ContactDto Contact { get; set; }

    [DataMember(Name = "items")]
    public List<Item> Items { get; set; }
}

[DataContract]
public class ContactDto
{
    [DataMember(Name = "name")]
    public string Name { get; set; }
}

// Usage
var response = AppSerializer.Deserialize<ApiResponse>(json);
string name = response.Contact.Name;
```

## DateTime Handling

`DataContractJsonSerializer` defaults to `\/Date(1234567890000)\/` format. `AppSerializer` uses ISO 8601 (`yyyy-MM-dd'T'HH:mm:ss.FFFFFFFK`) by default, and the `\/Date(...)\/` format with `JsonDateStyle.MsAjax`.

**The original serializer decides what the wire format was — keep it the same:**

| Original serializer | Its DateTime format | What to do |
|---|---|---|
| Newtonsoft (default) | ISO 8601 | `AppSerializer.Serialize(x)` — output matches |
| `JavaScriptSerializer` | `"\/Date(1730196000000)\/"` | `AppSerializer.Serialize(x, JsonDateStyle.MsAjax)` — output matches (see the local-time note above). **Never** switch a JavaScriptSerializer call to the ISO default: the receiving API may reject or misread ISO dates |
| External API sends `\/Date(...)\/` | — | `AppSerializer.Deserialize<T>(json, JsonDateStyle.MsAjax)` |
| External API sends ISO dates | — | `AppSerializer.Deserialize<T>(json)` |

Never use a format ending in a literal `Z` (e.g. `"...ss.fffZ"`): `Z` is not a .NET format specifier, so it is written as a plain letter and a local time gets labelled as UTC.

## Dictionary Serialization

Without `UseSimpleDictionaryFormat = true`, dictionaries serialize as arrays of key-value pairs instead of JSON objects:

```json
// WITHOUT UseSimpleDictionaryFormat (wrong)
[{"Key":"name","Value":"John"},{"Key":"age","Value":"30"}]

// WITH UseSimpleDictionaryFormat = true (correct)
{"name":"John","age":"30"}
```

Already set in the `AppSerializer` helper.

## Polymorphic / Inheritance Serialization

Use `[KnownType]` on the base class for polymorphic deserialization:

```csharp
// BEFORE (Newtonsoft with TypeNameHandling)
[JsonProperty("type")]
public string Type { get; set; }
var settings = new JsonSerializerSettings { TypeNameHandling = TypeNameHandling.Auto };

// AFTER
[DataContract]
[KnownType(typeof(EmailActivity))]
[KnownType(typeof(PhoneActivity))]
public class ActivityBase
{
    [DataMember(Name = "type")]
    public string Type { get; set; }
}

[DataContract]
public class EmailActivity : ActivityBase
{
    [DataMember(Name = "subject")]
    public string Subject { get; set; }
}

[DataContract]
public class PhoneActivity : ActivityBase
{
    [DataMember(Name = "phoneNumber")]
    public string PhoneNumber { get; set; }
}
```

`DataContractJsonSerializer` adds a `__type` hint to the JSON. If the external API does not send `__type`, deserialize as the base type and switch manually:

```csharp
var baseObj = AppSerializer.Deserialize<ActivityBase>(json);
switch (baseObj.Type)
{
    case "email":
        return AppSerializer.Deserialize<EmailActivity>(json);
    case "phone":
        return AppSerializer.Deserialize<PhoneActivity>(json);
}
```

## Enum Serialization

By default, `DataContractJsonSerializer` serializes enums as integers. For string values:

```csharp
[DataContract]
public enum Priority
{
    [EnumMember(Value = "low")]
    Low = 0,

    [EnumMember(Value = "medium")]
    Medium = 1,

    [EnumMember(Value = "high")]
    High = 2
}
```

If you need string representation without `[EnumMember]`, use a `string` property wrapper:

```csharp
[DataContract]
public class Task
{
    [IgnoreDataMember]
    public Priority Priority { get; set; }

    [DataMember(Name = "priority")]
    public string PriorityString
    {
        get => Priority.ToString().ToLower();
        set => Priority = (Priority)Enum.Parse(typeof(Priority), value, true);
    }
}
```

## Nullable Types

`DataContractJsonSerializer` handles `Nullable<T>` correctly. No special handling needed:

```csharp
[DataContract]
public class Record
{
    [DataMember(Name = "count")]
    public int? Count { get; set; }  // Serializes as null or number
}
```

## Shared DTO Strategy

When a DTO class is used by both plugin code and full-trust API projects:

1. Keep the class in a shared class library project.
2. Add `[DataContract]` and `[DataMember]` attributes (safe everywhere).
3. Remove Newtonsoft attributes (`[JsonProperty]`, etc.) from the shared code.
4. If the API project still needs Newtonsoft, use a separate DTO or add Newtonsoft attributes only in the API project's partial class.

```csharp
// Shared project — safe for both plugin and API
[DataContract]
public class CustomerDto
{
    [DataMember(Name = "id")]
    public string Id { get; set; }

    [DataMember(Name = "fullName")]
    public string FullName { get; set; }
}

// API project only (partial class extending shared DTO)
// This file is NOT in the plugin assembly
public partial class CustomerDto
{
    [JsonProperty("legacyId")]  // Newtonsoft, API-only
    public string LegacyId { get; set; }
}
```

## Common Migration Errors

| Error Message | Cause | Fix |
|---|---|---|
| `not serializable in partial trust because it is not public` | DTO class is `internal` | Change to `public class` |
| Property silently missing from JSON | `[DataContract]` on class but `[DataMember]` missing on property | Add `[DataMember]` to every property that should serialize |
| `DateTime` shows as `\/Date(...)\/` but ISO was expected | `JsonDateStyle.MsAjax` used for a Newtonsoft replacement | Use the default `AppSerializer.Serialize(x)` |
| Receiving API rejects dates after replacing `JavaScriptSerializer` | ISO default used instead of `JsonDateStyle.MsAjax` | Use `AppSerializer.Serialize(x, JsonDateStyle.MsAjax)` |
| Property is `null` after deserialize, no error | JSON name casing differs from `[DataMember(Name)]` | Set `Name` to the exact JSON casing (see "Property Names Are Case-Sensitive") |
| `SerializationException` parsing a date | Fixed format like `.fff` and the JSON has no / different fractional seconds | Use `FFFFFFFK` format from the `AppSerializer` helper |
| Time off by the UTC offset | Format ends in literal `Z` | Use `K` instead of `Z` |
| Dictionary shows as array of Key/Value | `UseSimpleDictionaryFormat` not set | Add `UseSimpleDictionaryFormat = true` |
| `InvalidDataContractException` | No parameterless constructor | Add `public MyClass() { }` |
| `SerializationException` on derived type | Missing `[KnownType]` | Add `[KnownType(typeof(Derived))]` on base |
