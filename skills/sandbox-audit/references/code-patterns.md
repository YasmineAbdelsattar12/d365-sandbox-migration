# Code Patterns & Replacements

Reusable patterns for common Sandbox migration scenarios.

## HTTP Hardening (apply to every outbound call)

Every `HttpWebRequest`, `WebClient`, or `HttpClient` call in a plugin must follow these rules:

```csharp
public string CallExternalApi(string url, string payload, ITracingService tracer)
{
    // 1. Force TLS 1.2
    ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;

    var request = (HttpWebRequest)WebRequest.Create(url);
    request.Method = "POST";
    request.ContentType = "application/json";
    request.Timeout = 90000; // 2. Max 90 seconds (platform kills at 120s)

    // Write request body
    using (var writer = new StreamWriter(request.GetRequestStream()))
    {
        writer.Write(payload);
    }

    string responseBody;
    try
    {
        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream()))
        {
            // 3. Read body BEFORE checking status
            responseBody = reader.ReadToEnd();

            // 4. Log with tracer
            tracer.Trace("HTTP {0} to {1} — Status: {2}", request.Method, url, (int)response.StatusCode);
            tracer.Trace("Response: {0}", responseBody.Length > 2000 ? responseBody.Substring(0, 2000) : responseBody);
        }
    }
    catch (WebException ex)
    {
        string errorBody = string.Empty;
        if (ex.Response != null)
        {
            using (var reader = new StreamReader(ex.Response.GetResponseStream()))
            {
                errorBody = reader.ReadToEnd();
            }
        }
        tracer.Trace("HTTP error: {0} — Body: {1}", ex.Message, errorBody);

        // 5. Throw InvalidPluginExecutionException, never generic Exception
        throw new InvalidPluginExecutionException(
            $"External API call failed: {ex.Message}. Response: {errorBody}", ex);
    }

    return responseBody;
}
```

### Async HTTP with GetAwaiter().GetResult()

```csharp
// WRONG — .Result wraps exceptions in AggregateException, losing stack trace
var result = httpClient.GetAsync(url).Result;

// CORRECT — preserves original exception
var result = httpClient.GetAsync(url).GetAwaiter().GetResult();
```

### HttpClient Note

`HttpClient` is safe in Sandbox but should be created per-call (not static) because plugin instances may be reused across different execution contexts:

```csharp
using (var client = new HttpClient())
{
    client.Timeout = TimeSpan.FromSeconds(90);
    // ... use client
}
```

## System.Web Replacement: MimeMapping

```csharp
// BEFORE (blocked — System.Web)
string mimeType = MimeMapping.GetMimeMapping(fileName);

// AFTER — local helper
public static string GetMimeType(string fileName)
{
    string ext = Path.GetExtension(fileName)?.ToLowerInvariant();
    switch (ext)
    {
        case ".pdf":  return "application/pdf";
        case ".doc":  return "application/msword";
        case ".docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
        case ".xls":  return "application/vnd.ms-excel";
        case ".xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        case ".ppt":  return "application/vnd.ms-powerpoint";
        case ".pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation";
        case ".png":  return "image/png";
        case ".jpg":
        case ".jpeg": return "image/jpeg";
        case ".gif":  return "image/gif";
        case ".bmp":  return "image/bmp";
        case ".svg":  return "image/svg+xml";
        case ".txt":  return "text/plain";
        case ".csv":  return "text/csv";
        case ".html": return "text/html";
        case ".xml":  return "application/xml";
        case ".json": return "application/json";
        case ".zip":  return "application/zip";
        default:      return "application/octet-stream";
    }
}
```

## System.Web Replacement: ParseQueryString

```csharp
// BEFORE (blocked — System.Web)
var qs = HttpUtility.ParseQueryString(url.Query);
string value = qs["key"];

// AFTER
public static Dictionary<string, string> ParseQueryString(string query)
{
    var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    if (string.IsNullOrEmpty(query)) return result;

    // Remove leading '?'
    if (query.StartsWith("?")) query = query.Substring(1);

    foreach (var pair in query.Split('&'))
    {
        var parts = pair.Split(new[] { '=' }, 2);
        if (parts.Length == 2)
        {
            result[Uri.UnescapeDataString(parts[0])] = Uri.UnescapeDataString(parts[1]);
        }
        else if (parts.Length == 1 && !string.IsNullOrEmpty(parts[0]))
        {
            result[Uri.UnescapeDataString(parts[0])] = string.Empty;
        }
    }
    return result;
}
```

## CSharpCodeProvider Reflection Pattern

```csharp
// BEFORE (blocked — runtime compilation)
var provider = new CSharpCodeProvider();
var results = provider.CompileAssemblyFromSource(parameters, sourceCode);
var instance = results.CompiledAssembly.CreateInstance("MyClass");

// AFTER — precompile the class and use reflection
// 1. Include the class in your plugin assembly at build time
// 2. Use reflection to instantiate if needed dynamically:
var type = Assembly.GetExecutingAssembly().GetType("MyNamespace.MyClass");
var instance = Activator.CreateInstance(type);
var method = type.GetMethod("Execute");
var result = method.Invoke(instance, new object[] { param1, param2 });
```

**Important**: Only reflect on **public** members. Accessing private/internal members of framework types is blocked.

## WCF Client Pattern

```csharp
// BEFORE (blocked — non-HTTP binding)
var binding = new NetTcpBinding();
var endpoint = new EndpointAddress("net.tcp://server:9000/Service");

// AFTER — BasicHttpsBinding only
var binding = new BasicHttpsBinding();
binding.Security.Mode = BasicHttpsSecurityMode.Transport;
binding.MaxReceivedMessageSize = 1048576; // 1 MB
binding.OpenTimeout = TimeSpan.FromSeconds(30);
binding.SendTimeout = TimeSpan.FromSeconds(90);
binding.CloseTimeout = TimeSpan.FromSeconds(15);

var endpoint = new EndpointAddress("https://server/Service.svc");
var client = new MyServiceClient(binding, endpoint);

// Force TLS 1.2
ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;

try
{
    var result = client.MyOperation(request);
    client.Close();
    return result;
}
catch (Exception)
{
    client.Abort();
    throw;
}
```

## ILMerge Considerations

When a plugin references external assemblies (Newtonsoft.Json, helper libraries), they must be ILMerged into a single assembly for Sandbox registration.

**Post-ILMerge checklist**:
- Verify merged assembly is under 16 MB size limit
- Ensure no blocked APIs were pulled in from merged assemblies
- Test all serialization — type names may change after merge
- Sign the merged assembly if required by CRM registration
- `Assembly.GetExecutingAssembly().GetType("...")` may need namespace updates after merge

**Common ILMerge issues**:
- Newtonsoft.Json ILMerged into plugin → all Newtonsoft calls are now Sandbox-scoped and blocked
- Helper library with `System.Drawing` reference ILMerged → pulls in blocked GDI+ types
- ILMerged assembly exceeds 16 MB → split into multiple plugin assemblies

## Plugin Secure / Unsecure Configuration

Replace `ConfigurationManager` with plugin step registration configuration:

```csharp
// In the plugin constructor, receive configuration strings
public class MyPlugin : IPlugin
{
    private readonly string _unsecureConfig;
    private readonly string _secureConfig;

    public MyPlugin(string unsecureConfig, string secureConfig)
    {
        _unsecureConfig = unsecureConfig;
        _secureConfig = secureConfig;
    }

    public void Execute(IServiceProvider serviceProvider)
    {
        // Parse XML or JSON configuration
        var config = AppSerializer.Deserialize<PluginConfig>(_unsecureConfig);
        
        // Secure config for API keys, connection strings
        var secrets = AppSerializer.Deserialize<SecureConfig>(_secureConfig);
        string apiKey = secrets.ApiKey;
    }
}
```

**Unsecure config**: Visible to anyone who can export the solution. Use for non-sensitive settings (URLs, feature flags, entity names).

**Secure config**: Encrypted at rest, not included in solution exports. Use for API keys, tokens, passwords.

## D365 Environment Variables (v9.1+)

For configuration that changes between environments (dev/test/prod):

```csharp
public static string GetEnvironmentVariable(IOrganizationService service, string schemaName)
{
    var query = new QueryExpression("environmentvariabledefinition")
    {
        ColumnSet = new ColumnSet("defaultvalue"),
        Criteria = new FilterExpression
        {
            Conditions =
            {
                new ConditionExpression("schemaname", ConditionOperator.Equal, schemaName)
            }
        }
    };

    // Link to value override
    var valueLink = query.AddLink("environmentvariablevalue", "environmentvariabledefinitionid", "environmentvariabledefinitionid", JoinOperator.LeftOuter);
    valueLink.EntityAlias = "val";
    valueLink.Columns = new ColumnSet("value");

    var result = service.RetrieveMultiple(query);
    if (result.Entities.Count == 0) return null;

    var entity = result.Entities[0];
    // Value override takes precedence over default
    var overrideValue = entity.GetAttributeValue<AliasedValue>("val.value");
    if (overrideValue != null) return overrideValue.Value?.ToString();
    return entity.GetAttributeValue<string>("defaultvalue");
}
```

## Assembly Re-Registration Checklist

After fixing a file that is shared across assemblies:

1. **Rebuild all referencing assemblies** — every `.csproj` that includes or references the changed file
2. **Update Plugin Registration Tool**:
   - Unregister old assembly version
   - Register new assembly (Sandbox isolation mode)
   - Re-register all plugin steps and images
3. **Check for `<Link>` references** in `.csproj` files: `<Compile Include="..\Shared\MyHelper.cs"><Link>Shared\MyHelper.cs</Link></Compile>`
4. **Check for Shared Projects**: `<Import Project="..\Shared\Shared.projitems" />` — all consuming projects must be rebuilt
5. **Update ILMerge output** if the changed file is in an ILMerged assembly
6. **Test in a Sandbox environment** before deploying to production

## Pre-Migration Checklist

Before starting migration:

- [ ] Identify all plugin and workflow activity assemblies (check Plugin Registration Tool)
- [ ] List all assemblies currently registered as **None** isolation mode
- [ ] Map shared code dependencies (which class libraries are used by plugins?)
- [ ] Back up current solution as managed and unmanaged
- [ ] Set up a Sandbox test environment
- [ ] Review ILMerge configurations for each assembly
- [ ] Document all plugin step registrations (message, entity, stage, order)
- [ ] Verify outbound HTTP endpoints are reachable on ports 80/443
- [ ] Plan assembly-by-assembly migration order (leaf dependencies first)

## Common Runtime Errors After Migration

| Error | Cause | Fix |
|---|---|---|
| `System.Security.SecurityException` | Called a blocked API | Replace with Sandbox-safe alternative (see `blocked-apis.md`) |
| `SerializationException: not public` | Internal DTO class | Make the class `public` |
| `InvalidPluginExecutionException: Timeout` | Plugin exceeded 2-minute limit | Optimize queries, reduce HTTP calls, use async step |
| `Assembly size exceeds maximum` | ILMerged assembly > 16 MB | Split into multiple assemblies, remove unused dependencies |
| `SecurityException: Request for permission failed` | Blocked namespace at load time | Remove `using` + all code references, or move to Azure Function |
| `MethodAccessException` | Reflecting on private/internal member | Use public API only |
| `FileNotFoundException` on merged type | ILMerge changed type namespace | Update `GetType()` calls with new fully qualified name |
| `Depth exceeded` | Plugin triggers another plugin 8+ levels | Redesign trigger chain, use pre/post images instead of re-queries |
| `Socket connection refused` | Outbound call on non-80/443 port | Change endpoint to port 80 or 443 |
