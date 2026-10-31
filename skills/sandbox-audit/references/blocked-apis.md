# Blocked APIs in Sandbox (Partial Trust)

Two levels:

- **Blocked** — fails at runtime (usually `SecurityException`) when executed in a Sandbox-registered plug-in or workflow activity. Fix every live call.
- **Avoid** — not blocked by the Sandbox itself, but unsupported or unreliable in plug-ins (behaviour undefined, silent wrong results, or blocked by the online network rules). Fix when the replacement is mechanical and behaviour-preserving; otherwise report it.

Rows are **Blocked** unless marked *(Avoid)*. For Dataverse Online, also apply `online-checklist.md`.

## File System & I/O

| Blocked API | Namespace | Replacement |
|---|---|---|
| `File.ReadAllText`, `File.WriteAllText`, `File.Exists`, `File.Delete`, all `File.*` | `System.IO` | `MemoryStream` + CRM Note attachment / SharePoint / Azure Blob |
| `Directory.CreateDirectory`, `Directory.GetFiles`, all `Directory.*` | `System.IO` | CRM entity records or Azure Blob containers |
| `FileStream` (to disk path) | `System.IO` | `MemoryStream` wrapping byte arrays |
| `FileInfo`, `DirectoryInfo` | `System.IO` | Not applicable in Sandbox |
| `StreamReader(filePath)`, `StreamWriter(filePath)` | `System.IO` | `StreamReader(memoryStream)` — in-memory streams are safe |
| `FileSystemWatcher` | `System.IO` | CRM async plugin on entity update |
| `IsolatedStorageFile`, `IsolatedStorageFileStream` | `System.IO.IsolatedStorage` | CRM entity records for persistent storage |

**Safe**: `MemoryStream`, `StreamReader(stream)`, `StreamWriter(stream)`, `GZipStream(memoryStream, ...)`, `Path.Combine()`, `Path.GetExtension()`, `Path.GetFileName()`.

## Database & Data Access

| Blocked API | Namespace | Replacement |
|---|---|---|
| `SqlConnection` | `System.Data.SqlClient` | `IOrganizationService` with `QueryExpression` or FetchXml |
| `SqlCommand`, `SqlDataReader`, `SqlDataAdapter` | `System.Data.SqlClient` | `IOrganizationService.RetrieveMultiple()` |
| `OleDbConnection`, `OleDbCommand` | `System.Data.OleDb` | `IOrganizationService` |
| `OdbcConnection`, `OdbcCommand` | `System.Data.Odbc` | `IOrganizationService` |
| `DbContext`, `DbSet<T>` | `System.Data.Entity` / EF | `IOrganizationService` queries |
| `DataContext` (LINQ to SQL) | `System.Data.Linq` | `IOrganizationService` queries |

## Configuration

| Blocked API | Namespace | Replacement |
|---|---|---|
| `ConfigurationManager.AppSettings` | `System.Configuration` | Plugin Unsecure/Secure Configuration XML |
| `ConfigurationManager.ConnectionStrings` | `System.Configuration` | Plugin Secure Configuration (encrypted) |
| `WebConfigurationManager` | `System.Web.Configuration` | Plugin Configuration or D365 Environment Variables |
| `Environment.GetEnvironmentVariable` | `System` | Plugin Configuration or CRM entity records |
| `Properties.Settings.Default.X` / `Settings.Default` | `System.Configuration` | Reads `app.config`, which the Sandbox worker never loads — use Plugin Configuration, environment variables or configuration records |
| `app.config` / `web.config` values of any kind | — | Same as above — the file is not deployed with a plug-in |

**D365 Environment Variables** (v9.1+): Use `RetrieveMultiple` on `environmentvariabledefinition` and `environmentvariablevalue` entities.

## Caching

| Blocked API | Namespace | Replacement |
|---|---|---|
| `MemoryCache.Default`, `new MemoryCache(...)`, `ObjectCache`, `CacheItemPolicy` | `System.Runtime.Caching` | No cache (query each execution), or a `static` `ConcurrentDictionary` with your own expiry — per Sandbox worker process only, may be recycled at any time, never shared between servers |
| `HttpRuntime.Cache`, `System.Web.Caching.Cache` | `System.Web` | Same as above |

## System.Web (entire assembly blocked)

| Blocked API | Replacement |
|---|---|
| `HttpContext.Current` | `IPluginExecutionContext` |
| `HttpUtility.UrlEncode(s)` | `Uri.EscapeDataString(s)` |
| `HttpUtility.UrlDecode(s)` | `Uri.UnescapeDataString(s)` |
| `HttpUtility.HtmlEncode(s)` | `System.Net.WebUtility.HtmlEncode(s)` |
| `HttpUtility.HtmlDecode(s)` | `System.Net.WebUtility.HtmlDecode(s)` |
| `HttpUtility.ParseQueryString(s)` | Manual split on `&` and `=`, then `Uri.UnescapeDataString` each part |
| `MimeMapping.GetMimeMapping(fileName)` | Local `GetMimeType()` helper — see `code-patterns.md` |
| `JavaScriptSerializer` | `DataContractJsonSerializer` — see `serializer-guide.md` |
| `[ScriptIgnore]` | `[DataContract]`/`[DataMember]` opt-in — see `serializer-guide.md` |
| `HttpServerUtility.MapPath` | Not applicable in Sandbox |
| `System.Web.Caching.Cache` | CRM entity records or static `Dictionary` (per-execution only) |

## Serialization

| Blocked API | Namespace | Replacement |
|---|---|---|
| `JavaScriptSerializer` | `System.Web.Script.Serialization` | `DataContractJsonSerializer` |
| `JsonConvert.SerializeObject` | `Newtonsoft.Json` | `DataContractJsonSerializer` — see `serializer-guide.md` |
| `JsonConvert.DeserializeObject<T>` | `Newtonsoft.Json` | `DataContractJsonSerializer` — see `serializer-guide.md` |
| `JObject`, `JArray`, `JToken` | `Newtonsoft.Json.Linq` | `DataContractJsonSerializer` with typed DTOs |
| `[JsonProperty]` | `Newtonsoft.Json` | `[DataMember(Name = "...")]` |
| `[JsonIgnore]` | `Newtonsoft.Json` | Omit `[DataMember]` (requires `[DataContract]` on class) |
| `[JsonConverter]` | `Newtonsoft.Json` | A string-backed `[DataMember]` property that converts in its getter/setter (see Enum Serialization in `serializer-guide.md`); use `[KnownType]` only when the converter was handling polymorphism |
| `[JsonConstructor]` | `Newtonsoft.Json` | Parameterless constructor (required by `DataContractJsonSerializer`) |
| `[JsonRequired]` | `Newtonsoft.Json` | `[DataMember(IsRequired = true)]` |

**Note on Newtonsoft.Json**: it is not part of the platform. If the compiled plug-in DLL references it, the DLL has to travel with the plug-in — via ILMerge (not supported by Microsoft) or a plug-in package (online only, and **not available for custom workflow activities**). If it is neither merged nor packaged, the assembly fails to load. Newtonsoft also uses reflection that can fail in partial trust. Replace it with `DataContractJsonSerializer` in all plug-in code; it stays fine in full-trust API/Portal projects.

## Networking

| Blocked API | Namespace | Replacement |
|---|---|---|
| `FtpWebRequest` | `System.Net` | Azure Blob + Azure Function relay |
| `SmtpClient` | `System.Net.Mail` | CRM `SendEmailRequest` or external email API |
| `TcpClient`, `TcpListener` | `System.Net.Sockets` | External HTTP API endpoint |
| `UdpClient` | `System.Net.Sockets` | External HTTP API endpoint |
| `Socket` | `System.Net.Sockets` | `HttpWebRequest` to external endpoint |
| `WebSocket`, `ClientWebSocket` | `System.Net.WebSockets` | Azure SignalR or external HTTP |
| `Ping` | `System.Net.NetworkInformation` | External health-check HTTP endpoint |
| Localhost URLs (`http://localhost`, `http://127.0.0.1`) | — | External routable URL |
| **IP-address URLs** (`http://10.1.2.15/api`, even public IPs) | — | A DNS host name — Microsoft requires "a named web address that requires DNS name resolution" |
| **Windows credentials**: `UseDefaultCredentials = true`, `CredentialCache.DefaultCredentials` / `DefaultNetworkCredentials`, NTLM/Kerberos to internal services | `System.Net` | Anonymous calls with an API key / OAuth client-credentials token from Secure Configuration |
| Non-standard ports (not 80/443) *(Avoid)* | — | Not documented as blocked, but often stopped by firewalls — prefer 443 |
| Endpoints inside the company network *(Avoid on-prem, ❌ online)* | — | See `online-checklist.md` → Network Access |

**Safe**: `HttpWebRequest`, `WebClient`, `HttpClient` to DNS-named external URLs over HTTPS with TLS 1.2, anonymous or token authentication.

## Threading & Async *(Avoid — whole section)*

Microsoft does not support multi-threading in plug-ins: work started on another thread can outlive the execution, `IOrganizationService` is not thread-safe, and exceptions on background threads are lost or crash the worker. Replace when the fix is mechanical (fire-and-forget → synchronous call); otherwise report.

| API | Namespace | Replacement |
|---|---|---|
| `new Thread(work).Start()` | `System.Threading` | Synchronous execution |
| `Task.Run(() => ...)` (fire-and-forget) | `System.Threading.Tasks` | Synchronous call or async plugin step |
| `ThreadPool.QueueUserWorkItem` | `System.Threading` | Synchronous execution |
| `System.Timers.Timer` | `System.Timers` | CRM recurring workflow or Azure Timer Function |
| `System.Threading.Timer` | `System.Threading` | CRM recurring workflow or Azure Timer Function |
| `Parallel.ForEach`, `Parallel.For` | `System.Threading.Tasks` | Sequential `foreach` loop |
| `Task.Factory.StartNew` (fire-and-forget) | `System.Threading.Tasks` | Synchronous execution |

**Safe**: `async/await`, `Task.WhenAll()` (awaited), `lock`, `Monitor`, `Interlocked`, `SemaphoreSlim`, `Lazy<T>`.

**Important**: Use `.GetAwaiter().GetResult()` instead of `.Result` to preserve original exception stack trace.

## Process & OS

| Blocked API | Namespace | Replacement |
|---|---|---|
| `Process.Start` | `System.Diagnostics` | Azure Function for external process execution |
| `EventLog.WriteEntry` | `System.Diagnostics` | `ITracingService.Trace()` |
| `Registry.GetValue`, all `Registry.*` | `Microsoft.Win32` | CRM entity records or Plugin Configuration |
| `Environment.MachineName` | `System` | Not available — use `IPluginExecutionContext.OrganizationName` |
| `Environment.UserName` | `System` | `IPluginExecutionContext.InitiatingUserId` |
| `Environment.Exit` | `System` | `throw new InvalidPluginExecutionException(...)` |
| `Environment.GetFolderPath` | `System` | Not applicable in Sandbox |
| `Environment.CurrentDirectory` | `System` | Not applicable in Sandbox |

**Safe**: `Environment.NewLine`, `Environment.TickCount`.

## Interop & Native Code

| Blocked API | Namespace | Replacement |
|---|---|---|
| `[DllImport("...")]` | `System.Runtime.InteropServices` | Pure managed C# implementation |
| `extern` methods | — | Pure managed C# implementation |
| `Marshal.AllocHGlobal`, `Marshal.Copy`, all `Marshal.*` | `System.Runtime.InteropServices` | Managed byte arrays and `BitConverter` |
| `GCHandle.Alloc(..., Pinned)` | `System.Runtime.InteropServices` | Managed arrays |
| `unsafe` / `fixed` blocks (if executed) | — | Safe managed code |
| COM interop (`Activator.CreateInstance(Type.GetTypeFromProgID(...))`) | — | Managed .NET equivalent or Azure Function |

**Note**: `unsafe`/`fixed` with zero callers from plugin code is NOT a violation (dead code is safe).

## Assembly & Reflection

| Blocked API | Namespace | Replacement |
|---|---|---|
| `Assembly.LoadFrom(path)` | `System.Reflection` | ILMerge dependent assemblies into plugin |
| `Assembly.LoadFile(path)` | `System.Reflection` | ILMerge |
| `Assembly.Load(string name)` | `System.Reflection` | ILMerge |
| `Assembly.Load(byte[])` | `System.Reflection` | ILMerge |
| `AppDomain.CreateDomain` | `System` | Single AppDomain — restructure code |
| `AppDomain.CurrentDomain.AssemblyResolve` | `System` | ILMerge resolves dependencies at build time |
| `CSharpCodeProvider` | `Microsoft.CSharp` | Reflection on precompiled types — see `code-patterns.md` |
| `CompileAssemblyFromSource` | `System.CodeDom.Compiler` | Precompiled types with reflection |
| `Reflection.Emit` (`DynamicMethod`, `TypeBuilder`, `AssemblyBuilder`) | `System.Reflection.Emit` | Precompiled types with reflection |
| Reflection on private/internal members of framework types | `System.Reflection` | Use public API members only |

**Safe**: `GetType()`, `GetProperty()`, `GetMethod()`, `Invoke()` on public members. `typeof(T)`, `Activator.CreateInstance<T>()`.

## Graphics & Imaging

| Blocked API | Namespace | Replacement |
|---|---|---|
| `Bitmap`, `Graphics`, `Image` | `System.Drawing` | Azure Function for image processing |
| `Icon`, `Pen`, `Brush`, `Font` (GDI+) | `System.Drawing` | Azure Function |
| `ImageConverter` | `System.Drawing` | `Convert.ToBase64String` / `Convert.FromBase64String` |
| `System.Windows.Media.*` (WPF) | `PresentationCore` | Azure Function |

## Cryptography (partial restrictions)

| Blocked API | Namespace | Replacement |
|---|---|---|
| `RSACryptoServiceProvider` with `CspParameters` | `System.Security.Cryptography` | Ephemeral RSA (`new RSACryptoServiceProvider()` without CspParameters) |
| `X509Store` (certificate store access) | `System.Security.Cryptography.X509Certificates` | Pass certificates as byte arrays from Plugin Secure Configuration |
| `ProtectedData` (DPAPI) | `System.Security.Cryptography` | `Aes` encryption with key from Secure Configuration |

**Safe**: `SHA256`, `SHA512`, `MD5`, `HMACSHA256`, `HMACSHA512`, `Aes`, `RNGCryptoServiceProvider`, `RSACryptoServiceProvider` (ephemeral, no CspParameters), `X509Certificate2(byte[])`.

## XML (risky patterns)

| Risky Pattern | Fix |
|---|---|
| `XmlDocument` with DTD processing enabled | Set `XmlResolver = null` on `XmlDocument` |
| `XmlReaderSettings.DtdProcessing = DtdProcessing.Parse` | Use `DtdProcessing.Prohibit` (default) |
| `XslCompiledTransform` with `enableScript: true` | Use `enableScript: false` |
| `XmlTextReader` without settings | Wrap with `XmlReader.Create(stream, safeSettings)` |

**Safe**: `XmlDocument` (with `XmlResolver = null`), `XDocument`, `XElement`, `XmlReader` (defaults), `XmlSerializer`, `DataContractSerializer`.

## Logging Frameworks

| Blocked API | Replacement |
|---|---|
| `log4net` (all) | `ITracingService.Trace()` |
| `NLog` (all) | `ITracingService.Trace()` |
| `Serilog` (all) | `ITracingService.Trace()` |
| `Microsoft.Extensions.Logging` | `ITracingService.Trace()` |
| `EventLog` | `ITracingService.Trace()` |

**Note**: Trace log max is ~10 KB. Log critical info first.

## Miscellaneous

| Blocked API | Namespace | Replacement |
|---|---|---|
| `DirectoryEntry`, `DirectorySearcher` | `System.DirectoryServices` | Microsoft Graph API via HTTP |
| `PrincipalContext` | `System.DirectoryServices.AccountManagement` | Microsoft Graph API via HTTP |
| `NetTcpBinding`, `NetNamedPipeBinding` | `System.ServiceModel` | `BasicHttpsBinding` only |
| `ChannelFactory<T>` with non-HTTP binding | `System.ServiceModel` | `BasicHttpsBinding` — see `code-patterns.md` |
| `Microsoft.VisualBasic.*` | `Microsoft.VisualBasic` | Native C# equivalents |
| `System.Windows.Forms.*` | `System.Windows.Forms` | Not applicable in Sandbox |
| `System.Management.*` (WMI) | `System.Management` | Not applicable in Sandbox |
| `System.ServiceProcess.*` | `System.ServiceProcess` | Azure Function or external API |
| `System.Printing.*` | `System.Printing` | Not applicable in Sandbox |
| `System.Speech.*` | `System.Speech` | External API |
