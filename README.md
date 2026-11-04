# CISA ScubaGear for Microsoft 365

A [Maester Pack](https://maester.dev/docs/packs) that runs CISA's [ScubaGear](https://github.com/cisagov/ScubaGear),
or reads the results it wrote, and shows each policy result in the Maester report, next to Maester's own checks.
ScubaGear checks a Microsoft 365 tenant against CISA's
[Secure Cloud Business Applications (SCuBA)](https://www.cisa.gov/resources-tools/services/secure-cloud-business-applications-scuba-project)
baselines for Entra ID, Exchange Online, Defender and Purview, SharePoint, Teams, Power Platform and Power BI.

Each policy result is one row, `MP.SCUBA.M365.<policy ID>` (for example `MP.SCUBA.M365.MS.AAD.1.1`), with the
policy's requirement as its title, its rationale and remediation steps, and ScubaGear's findings. A `SHALL` policy
has the severity High and a `SHOULD` policy Medium. Results are tagged `SCuBA`, `SCuBA.<product>` (`SCuBA.AAD`,
`SCuBA.EXO` and so on) and, for a policy that BOD 25-01 requires, `BOD25-01`.

The ID leaves out the policy's version (`v1`), so a row keeps its ID when CISA revises a policy. Maester's own
[CISA tests](https://maester.dev/docs/tests/cisa/) check some of the same policies in Maester's way; this pack shows
ScubaGear's own results.

## Install

```powershell
Install-MtPack maester365/maester-pack-scubagear
```

The pack needs Maester 3.0 or later. `Install-MtPack` shows what the pack reaches and asks you to approve it. It
rates the pack High risk because, when it runs ScubaGear, it runs the copy of ScubaGear you installed, which Maester
does not save or check.

## Run it

The pack gets ScubaGear's results one of two ways.

### Read results you already have

Run ScubaGear as its own step, on Windows, then point Maester at what it wrote. Maester can then run on any
platform.

```powershell
# In Windows PowerShell 5.1
Invoke-SCuBA -OutPath C:\scuba -Quiet

# In PowerShell 7, anywhere
Invoke-Maester -Pack SCUBA.M365
```

with `ScubaGear.ReportPath` set to the `ScubaResults_<id>.json` file, the run's `M365BaselineConformance_<time>`
folder, or the `-OutPath` folder, where the newest run wins:

```json
{
  "GlobalSettings": { "ScubaGear.ReportPath": "C:\\scuba" }
}
```

The pack refuses results older than seven days (`ScubaGear.MaxReportAgeDays`), and results for another tenant than
the one Maester is connected to.

### Let Maester run ScubaGear

On Windows, with `ScubaGear.ReportPath` empty, the pack runs `Invoke-SCuBA` itself. ScubaGear 2.0 runs only in
Windows PowerShell 5.1, and Maester in PowerShell 7, so the pack starts a separate Windows PowerShell process for it
and reads the results it writes. Install ScubaGear there once:

```powershell
# In Windows PowerShell 5.1
Install-Module ScubaGear -Scope CurrentUser
Initialize-SCuBA
```

Then run Maester as usual, in PowerShell 7:

```powershell
Connect-Maester
Invoke-Maester -Pack SCUBA.M365 -SkipBuiltIn    # only ScubaGear
Invoke-Maester -Pack SCUBA.M365                 # Maester's tests and ScubaGear
```

ScubaGear signs in in its own process:

- **Interactively:** it opens its own sign-in window for the products it checks. `Connect-Maester` is not needed
  for this, but with it the pack checks that ScubaGear's results are for the same tenant.
- **App-only:** when Maester is connected to Graph app-only with a certificate in the Windows certificate store,
  ScubaGear uses the same app and certificate, and the tenant's initial domain. Give the app the permissions and
  roles ScubaGear's [non-interactive guide](https://github.com/cisagov/ScubaGear/blob/main/docs/prerequisites/noninteractive.md)
  lists. Without a certificate (a client secret, a managed identity or workload identity federation) the pack is
  skipped, because ScubaGear signs in app-only only with a certificate.

The pack is a long-running test, so `Invoke-Maester` leaves it out unless you name it with `-Pack`, `-TestId
MP.SCUBA.M365` or `-IncludeLongRunning`. ScubaGear can take half an hour or more on a large tenant; give it time
with `Execution.LongRunningTimeoutSeconds`. Its output shows in Maester's console while it runs.

On macOS and Linux the pack does not run ScubaGear: read results you already have instead. ScubaGear 2.0 does not
run in PowerShell 7, because its sign-in window needs Windows PowerShell
([cisagov/ScubaGear#2411](https://github.com/cisagov/ScubaGear/pull/2411) changes that). When a version of
ScubaGear runs in PowerShell 7, set `ScubaGear.PowerShell` to `pwsh`.

## Settings

All settings go in `GlobalSettings` of `maester-config.json`.

| Setting | Default | What it does |
| --- | --- | --- |
| `ScubaGear.ReportPath` | empty | Read these results instead of running ScubaGear: the `ScubaResults` file, the run's folder or the `-OutPath` folder. |
| `ScubaGear.MaxReportAgeDays` | `7` | Refuse results older than this. `0` turns the check off. |
| `ScubaGear.ProductNames` | ScubaGear's default | The products to check: `aad`, `exo`, `securitysuite`, `sharepoint`, `teams`, `powerplatform`, `powerbi`. |
| `ScubaGear.M365Environment` | detected | `commercial`, `gcc`, `gcchigh` or `dod`. When Maester is connected to the USGov or USGovDoD cloud, `gcchigh` or `dod`. |
| `ScubaGear.ConfigFilePath` | none | A [ScubaGear configuration file](https://github.com/cisagov/ScubaGear/blob/main/docs/configuration/configuration.md), with its exclusions, omissions and annotations. |
| `ScubaGear.Parameters` | none | Further `Invoke-SCuBA` parameters, for example `{ "Organization": "contoso.onmicrosoft.com" }`. |
| `ScubaGear.OutputPath` | temporary | Where ScubaGear writes its reports. Kept when set; a temporary folder is deleted after the run, because it holds tenant data. |
| `ScubaGear.PowerShell` | `powershell` on Windows | The PowerShell that runs ScubaGear: `powershell`, `pwsh` or the full path of one. |
| `ScubaGear.ModulePath` | newest installed | Run the ScubaGear module at this path (its `ScubaGear.psd1`) instead of the newest one installed. |

## How results map

| ScubaGear result | Maester result |
| --- | --- |
| Pass | Passed |
| Fail (a `SHALL` policy) | Failed, severity High |
| Warning (a `SHOULD` policy) | Failed, severity Medium |
| N/A (a manual check, or one a third-party product can meet) | Skipped, with ScubaGear's reason |
| Omitted (in the ScubaGear configuration file) | Skipped, with the justification |
| Incorrect result (in the ScubaGear configuration file) | Skipped, with ScubaGear's own result |
| Error | Error |
| `-` (a policy removed from the baseline) | Not shown |

## Working on the pack

```text
maester-pack.json         the manifest: maester365.scubagear, code SCUBA.M365
maester-pack.guide.json   the pack's page on packs.maester.cloud
catalog.json              ScubaGear's policies, generated by build/Update-ScubaGearCatalog.ps1
tests/                    the MP.SCUBA.M365 family test
build/                    the catalog builder
spec/                     Pester tests of the pack, with a cut of ScubaGear's sample results
```

```powershell
Invoke-Pester ./spec                # the pack's own tests, against the installed Maester
Invoke-MtTest -Path ./tests -Id MP.SCUBA.M365
```

`build/` and `spec/` are marked `export-ignore` in `.gitattributes`, so they are not part of the pack:
`Install-MtPack` downloads GitHub's archive of the release, which leaves them out. Every PowerShell file in a pack
may hold only functions, so run `Test-MtPack` on what ships, not on this folder. The spec does that for you, and
so does the check workflow, on a `git archive` of the commit.

`catalog.json` lists ScubaGear's policies, titles, criticality, rationale and remediation steps, for the pack's
listing and for the description of each result. It is generated from `schemas/ScubaBaselines.json` in the ScubaGear
module; do not edit it. To move the pack to a new version of ScubaGear, run:

```powershell
./build/Update-ScubaGearCatalog.ps1 -SourcePath <ScubaGear module folder or repository clone>
```

The pack reads these parts of ScubaGear's `ScubaResults_<id>.json`, which a new version can change: `MetaData`
(`Tool`, `TenantId`, `TimestampZulu`) and `Results.<product>[].Controls[]` (`Control ID`, `Requirement`, `Result`,
`Criticality`, `Details`, `IncorrectResult`), with the result values `Pass`, `Fail`, `Warning`, `N/A`, `Omitted`,
`Incorrect result`, `Error` and `-`.

### Versions and releases

Raise `Version` in `maester-pack.json` and add its section to `CHANGELOG.md` in the pull request.
`.github/workflows/release.yml` publishes a release `v<Version>` when it is merged, once the repository variable
`PACK_RELEASES` is `true`. `Install-MtPack` installs the newest release once it is older than the install cooldown.

## Licence

The pack is published under the [MIT licence](LICENSE). ScubaGear is published by CISA under
[CC0 1.0](https://github.com/cisagov/ScubaGear/blob/main/LICENSE). This pack does not include its code: it runs the
module you install, or reads the results it wrote. The pack's catalog of policy titles, rationale and remediation
steps is generated from ScubaGear's baselines.
