# Blocked APIs in Sandbox (Partial Trust)

These APIs throw `SecurityException` at runtime when called from a Sandbox-registered plugin or workflow activity assembly.

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

**D365 Environment Variables** (v9.1+): Use `RetrieveMultiple` on `environmentvariabledefinition` and `environmentvariablevalue` entities.

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
| `[JsonConverter]` | `Newtonsoft.Json` | `[KnownType]` + `[DataContract]` hierarchy |
| `[JsonConstructor]` | `Newtonsoft.Json` | Parameterless constructor (required by `DataContractJsonSerializer`) |
| `[JsonRequired]` | `Newtonsoft.Json` | `[DataMember(IsRequired = true)]` |

**Note**: Newtonsoft.Json is only blocked if ILMerged into the plugin assembly. If it's a separate NuGet not deployed to CRM, it's not a concern.

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
| Non-standard ports (not 80/443) | — | Use ports 80 (HTTP) or 443 (HTTPS) only |

**Safe**: `HttpWebRequest`, `WebClient`, `HttpClient` to external URLs on ports 80/443 with TLS 1.2.

## Threading & Async

| Blocked API | Namespace | Replacement |
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
