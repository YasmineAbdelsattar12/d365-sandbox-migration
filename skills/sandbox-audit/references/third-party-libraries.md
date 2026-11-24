# Third-Party Libraries in Sandbox

Read this when the scan has entries in `OnlineReadiness.ThirdPartyLibraries`, `OnlineReadiness.MergeTool`, or `ThirdParty` hits.

The scanner reads **your** source code. A library can call a blocked API **inside its own DLL** — your code never mentions `System.Drawing`, but the library draws with it. Such a project scans clean and still fails in Sandbox when that feature runs. This list closes that gap for libraries seen in D365 projects.

Two separate questions for every library:

1. **Is its code allowed in Sandbox?** — this file (status below). Packaging does not change the answer: an ILMerged library runs exactly the same code.
2. **How does the DLL reach CRM?** — `online-checklist.md` section 4 (plug-in package, linked source, or — on-premises only — ILMerge).

## Status

| Status | Meaning | What the skill does |
|---|---|---|
| **Blocked** | The library (or the feature the code uses) calls blocked APIs on its normal path | Fix only when a behaviour-identical replacement exists in this file (e.g. QRCoder); otherwise **Needs decision** |
| **Review** | Depends on which features are used | Read how the code uses it; list it under **Needs verification** with the feature to test in Sandbox |
| **OK** | Plain managed code | Only packaging matters |
| **Handled** | Covered by another rule (Newtonsoft → serializer migration) | Follow that rule |

## Libraries

| Library | Status | Why | Fix / what to test |
|---|---|---|---|
| **QRCoder** | Review (Blocked for `QRCode`, `Base64QRCode`, `ArtQRCode`) | The encoder is plain C#; those image classes draw with System.Drawing | Replace with `PngByteQRCode` — see below. `SvgQRCode`, `AsciiQRCode`, `BitmapByteQRCode` and `PayloadGenerator` are safe |
| **System.Drawing / System.Drawing.Common** | Review (any use is Blocked) | GDI+ is blocked | Remove the reference if unused; replace the code that uses it |
| **Syncfusion** DocIO → PDF (`DocToPDFConverter`), XlsIO / Presentation renderers, HTML → PDF | Review — likely to fail | Page rendering draws with System.Drawing (GDI+) in the .NET Framework builds; large DLLs | Test the exact conversion in a Sandbox plug-in or confirm with Syncfusion. If it fails: convert outside the plug-in (Azure Function, Power Automate "Word template" + "Convert file" actions) |
| **Syncfusion** (other: Pdf, DocIO without conversion, Compression, Licensing) | Review | Mostly managed; some features use System.Drawing or files | Test the features used; load the licence key from CRM data (it already is in most projects), never from a file |
| **iTextSharp / iText 7** | Review | PDF writing is managed; `FontFactory.Register*` reads the Windows fonts folder (blocked); `System.Drawing.Image` overloads are blocked | Fonts from embedded resources / byte arrays; images as `byte[]`. AGPL licence — check it is covered |
| **PDFsharp / MigraDoc** (GDI or WPF builds) | Review | Draw with GDI+ / WPF | Use the Core builds; fonts from embedded resources |
| **EPPlus** | Review | Cells are fine; `AutoFitColumns`, pictures and charts use System.Drawing | Set column widths instead of `AutoFitColumns`; EPPlus 5+ needs a commercial licence |
| **ClosedXML** | Review | `AdjustToContents` and images use System.Drawing | Avoid them, or generate outside the plug-in |
| **DocumentFormat.OpenXml** | Review | `System.IO.Packaging` can switch to isolated storage for large parts (about 10 MB) — blocked | Test with the largest real document |
| **ZXing.Net** | Review (Blocked for `BarcodeWriter` → `Bitmap`) | Bitmap output uses System.Drawing | `BarcodeWriterSvg` or `BarcodeWriterPixelData` |
| **Aspose.\*** | Review | Rendering uses System.Drawing in .NET Framework builds; licence from a file is blocked | Licence from a stream / embedded resource; test rendering |
| **ReportViewer** (`Microsoft.ReportViewer.*`, `LocalReport`) | Blocked | Local report rendering needs full trust and GDI+ | See "Report rendering" in `online-checklist.md` |
| **log4net / NLog / Serilog** | Blocked | Files / event log | `ITracingService` (`blocked-apis.md`) |
| **Dapper / Entity Framework** | Blocked | Direct SQL | `IOrganizationService` |
| **Newtonsoft.Json** | Handled | — | `serializer-rules.md` |
| **RestSharp, HtmlAgilityPack, CsvHelper, Polly** | OK | Managed code; HTTP calls get the usual hardening | Packaging only — or replace with built-in .NET code |
| **Azure SDKs** (Storage, Service Bus, Event Hubs) | Review | HTTP-based, large dependency trees | Prefer a registered service endpoint (`IServiceEndpointNotificationService`) for Service Bus / Event Hubs |

A library not in this list: say so, list it under **Needs verification** ("test <feature> in a Sandbox plug-in"), and never claim it is safe.

## QRCoder: `Base64QRCode` → `PngByteQRCode`

Before (System.Drawing — fails in Sandbox):

```csharp
var qrGenerator = new QRCodeGenerator();
QRCodeData qrCodeData = qrGenerator.CreateQrCode(text, QRCodeGenerator.ECCLevel.Q);
var qrCode = new Base64QRCode(qrCodeData);
string base64 = qrCode.GetGraphic(20);
```

After (no System.Drawing):

```csharp
var qrGenerator = new QRCodeGenerator();
QRCodeData qrCodeData = qrGenerator.CreateQrCode(text, QRCodeGenerator.ECCLevel.Q);
var qrCode = new PngByteQRCode(qrCodeData);
string base64 = Convert.ToBase64String(qrCode.GetGraphic(20));
```

- With the defaults (black on white, quiet zone on) this should give the same QR image as a base64 PNG. The bytes can differ (different PNG encoder), so list under **Needs verification**: "compare the QR image before / after; scan it with a phone".
- `PngByteQRCode` only exists in newer QRCoder versions (1.3.x and later). Check the version in `packages.config`: if the build says the class does not exist, the package must be updated too — a **Needs decision** item, not something to do silently.
- `QRCode.GetGraphic(...)` returning a `Bitmap`, or `Base64QRCode` with a logo / custom colours: no identical replacement → **Needs decision**.
- QRCoder itself is still a dependency: plug-ins → plug-in package (Online) or keep it merged (on-premises); workflow activities → see `online-checklist.md` section 4.

## Merge tools (ILMerge, ILRepack, Costura)

`OnlineReadiness.MergeTool` is set when the project merges libraries into its DLL (packages, imported targets, build events, `ILMergeConfig.json`, `FodyWeavers.xml`).

- The built DLL then shows **no runtime dependencies**, so `Dll.RuntimeDependencies` is empty — **use `MergeTool.MergedLibraries` as the dependency list**, never report "no dependencies ✅" for a merged project.
- Every merged library is checked against the list above; merging does not make it Sandbox-safe.
- Microsoft does not support ILMerge-style merging for plug-ins. **On-premises Sandbox**: it is the usual workaround — keep it, and say so. **Dataverse Online**: plug-ins → plug-in package; workflow activities → replace the library or compile its source in.
- The skill never adds, removes or changes a merge setup — it reports it.
- Merged DLL size counts against the 16 MB limit: compare `Dll.Size`.
