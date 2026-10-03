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

## DTO Visibility Rule

In partial trust, DTO classes used with `DataContractJsonSerializer` **must be public**. Internal or private classes throw:

```
SerializationException: Type 'MyNamespace.MyDto' cannot be serialized in partial trust because it is not public.
```

Fix: Change `internal class` to `public class`.

## Reusable AppSerializer Helper

Use this helper throughout the codebase to replace all `JsonConvert` / `JavaScriptSerializer` calls:

```csharp
using System.IO;
using System.Runtime.Serialization.Json;
using System.Text;

public static class AppSerializer
{
    private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

    public static string Serialize<T>(T obj)
    {
        if (obj == null) return null;
        var settings = new DataContractJsonSerializerSettings
        {
            UseSimpleDictionaryFormat = true,
            DateTimeFormat = new System.Runtime.Serialization.DateTimeFormat("yyyy-MM-dd'T'HH:mm:ss.fffZ")
        };
        var serializer = new DataContractJsonSerializer(typeof(T), settings);
        using (var ms = new MemoryStream())
        {
            serializer.WriteObject(ms, obj);
            return Utf8NoBom.GetString(ms.ToArray());
        }
    }

    public static T Deserialize<T>(string json)
    {
        if (string.IsNullOrEmpty(json)) return default(T);
        var serializer = new DataContractJsonSerializer(typeof(T), new DataContractJsonSerializerSettings
        {
            UseSimpleDictionaryFormat = true,
            DateTimeFormat = new System.Runtime.Serialization.DateTimeFormat("yyyy-MM-dd'T'HH:mm:ss.fffZ")
        });
        using (var ms = new MemoryStream(Utf8NoBom.GetBytes(json)))
        {
            return (T)serializer.ReadObject(ms);
        }
    }
}
```

## Replacing JavaScriptSerializer

```csharp
// BEFORE (blocked — System.Web)
using System.Web.Script.Serialization;
var serializer = new JavaScriptSerializer();
string json = serializer.Serialize(myObject);
var obj = serializer.Deserialize<MyType>(json);

// AFTER
string json = AppSerializer.Serialize(myObject);
var obj = AppSerializer.Deserialize<MyType>(json);
```

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

`DataContractJsonSerializer` defaults to `/Date(1234567890000)/` format, not ISO 8601. Fix with `DateTimeFormat` in settings (already included in the `AppSerializer` helper above):

```csharp
var settings = new DataContractJsonSerializerSettings
{
    DateTimeFormat = new System.Runtime.Serialization.DateTimeFormat("yyyy-MM-dd'T'HH:mm:ss.fffZ")
};
```

If the external API sends `/Date(...)/` format, omit the `DateTimeFormat` setting.

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
| `DateTime` shows as `/Date(...)` | Default format, not ISO 8601 | Add `DateTimeFormat` to settings |
| Dictionary shows as array of Key/Value | `UseSimpleDictionaryFormat` not set | Add `UseSimpleDictionaryFormat = true` |
| `InvalidDataContractException` | No parameterless constructor | Add `public MyClass() { }` |
| `SerializationException` on derived type | Missing `[KnownType]` | Add `[KnownType(typeof(Derived))]` on base |
