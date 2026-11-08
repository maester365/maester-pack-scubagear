function Get-MtScubaGearInstance {
    <#
    .SYNOPSIS
    Returns one MP.SCUBA.M365 instance per policy result of a CISA ScubaGear assessment.

    .DESCRIPTION
    Instance source of the MP.SCUBA.M365 family. Reads the ScubaResults JSON that Invoke-SCuBA wrote, from the
    ScubaGear.ReportPath setting when one is set (import), otherwise runs ScubaGear in a child PowerShell process
    (collect), then returns one instance per policy result. Skips the whole family, with the reason, when neither
    is possible.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $reportPath = [string](Get-MtSetting -Name 'ScubaGear.ReportPath' -Default '')
    $collected = $null
    if ([string]::IsNullOrWhiteSpace($reportPath)) {
        $collected = Invoke-MtScubaGearCollection
        $reportPath = $collected.OutputPath
    }

    try {
        $file = Resolve-MtScubaGearResultFile -Path $reportPath
        $report = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        if (-not $report.PSObject.Properties['Results'] -or -not $report.PSObject.Properties['MetaData']) {
            throw "$file is not a ScubaGear results file: it has no MetaData or Results."
        }
        if ([string]$report.MetaData.Tool -ne 'ScubaGear') {
            Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason "$file was written by $($report.MetaData.Tool), not ScubaGear."
        }

        $context = if (Get-Command -Name Get-MgContext -ErrorAction Ignore) { Get-MgContext } else { $null }
        if ($context -and $context.TenantId -and $report.MetaData.TenantId -and $report.MetaData.TenantId -ne $context.TenantId) {
            Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason "The ScubaGear results at $file are for tenant $($report.MetaData.TenantId), but Maester is connected to tenant $($context.TenantId)."
        }

        $maxAgeDays = [int](Get-MtSetting -Name 'ScubaGear.MaxReportAgeDays' -Default 7)
        # ConvertFrom-Json reads the ISO date as a DateTime already; text is parsed invariantly, never in the current culture.
        $written = [datetime]::MinValue
        $hasDate = if ($report.MetaData.TimestampZulu -is [datetime]) { $written = $report.MetaData.TimestampZulu; $true }
        else {
            [datetime]::TryParse([string]$report.MetaData.TimestampZulu, [cultureinfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$written)
        }
        if ($maxAgeDays -gt 0 -and $hasDate -and $written.ToUniversalTime() -lt [datetime]::UtcNow.AddDays(-$maxAgeDays)) {
            Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason "The ScubaGear results at $file were written on $($written.ToString('yyyy-MM-dd')), more than $maxAgeDays days ago. Run Invoke-SCuBA again, or raise the ScubaGear.MaxReportAgeDays setting."
        }

        ConvertTo-MtScubaGearInstance -Report $report -Catalog (Get-MtScubaGearCatalog)
    } finally {
        # A run into a temporary folder leaves nothing behind: ScubaGear's provider export holds raw tenant data.
        if ($collected -and $collected.Temporary -and (Test-Path -LiteralPath $collected.OutputPath)) {
            Remove-Item -LiteralPath $collected.OutputPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-MtScubaGearResultFile {
    <#
    .SYNOPSIS
    Returns the ScubaResults file at Path: the file itself, the newest in the folder, or the newest in a folder in it.

    .DESCRIPTION
    Invoke-SCuBA writes ScubaResults_<uuid>.json in a new M365BaselineConformance_<time> folder under its -OutPath on
    every run, so Path can be the file, that run's folder, or the -OutPath folder, where the newest run wins.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Resolve-Path -LiteralPath $Path).ProviderPath }
    $file = $null
    if (Test-Path -LiteralPath $Path -PathType Container) {
        $file = Get-ChildItem -LiteralPath $Path -Filter 'ScubaResults*.json' -File -ErrorAction SilentlyContinue |
            Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1
        if (-not $file) {
            $file = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter 'ScubaResults*.json' -File -ErrorAction SilentlyContinue } |
                Sort-Object -Property LastWriteTimeUtc -Descending | Select-Object -First 1
        }
    }
    if (-not $file) {
        Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason "No ScubaGear results file (ScubaResults_<id>.json) was found at $Path. Point the ScubaGear.ReportPath setting at the file or the folder Invoke-SCuBA wrote, or clear it to let Maester run ScubaGear."
    }
    $file.FullName
}

function Get-MtScubaGearCatalog {
    <#
    .SYNOPSIS
    Returns the pack's catalog of ScubaGear policies, by policy ID without its version (MS.AAD.1.1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $catalog = @{}
    $path = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'catalog.json'
    if (Test-Path -LiteralPath $path) {
        foreach ($entry in @((Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json).Tests)) {
            $catalog[([string]$entry.ControlId -replace 'v\d+$', '')] = $entry
        }
    }
    $catalog
}

function ConvertTo-MtScubaGearInstance {
    <#
    .SYNOPSIS
    Turns the Results of a ScubaResults file into MP.SCUBA.M365 instances.

    .DESCRIPTION
    The instance suffix is the policy ID without its version, such as MS.AAD.1.1 for MS.AAD.1.1v1, so a result
    keeps its ID when CISA revises a policy. Controls ScubaGear writes with the result '-' (a policy removed from
    the baseline, or one it could not read) are left out.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        # A ScubaResults file read with ConvertFrom-Json.
        [Parameter(Mandatory)] $Report,

        # The catalog from Get-MtScubaGearCatalog.
        [hashtable] $Catalog = @{}
    )

    # The Security Suite baseline covers Defender for Office 365, data loss prevention, alerts and audit logging.
    $baselineProduct = @{
        AAD = 'entra'; EXO = 'exchange'; SECURITYSUITE = 'defender'; DEFENDER = 'defender'
        SHAREPOINT = 'sharepoint'; TEAMS = 'teams'; POWERBI = 'fabric'
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($product in $Report.Results.PSObject.Properties) {
        foreach ($group in @($product.Value)) {
            foreach ($control in @($group.Controls)) {
                if (-not $control -or [string]$control.Result -in '', '-') { continue }
                if ([string]$control.'Control ID' -notmatch '^(MS\.[A-Za-z]+\.\d+\.\d+)(v\d+)?$') { continue }
                $id = $Matches[1].ToUpperInvariant()
                if (-not $seen.Add($id)) { continue }
                $policy = $Catalog[$id]

                $requirement = ConvertFrom-MtScubaGearHtml -Html ([string]$control.Requirement -replace "(?is)<div class=['""]policy-indicators['""].*?</div>", '')
                $criticality = [string]$control.Criticality
                if (-not $criticality -or $criticality -eq '-') { $criticality = if ($policy) { [string]$policy.Criticality } else { '' } }
                # The baseline is the policy ID's second part (AAD in MS.AAD.1.1), as the ScubaGoggles pack tags GWS.GMAIL.1.1 SCuBA.GMAIL.
                $baseline = $id.Split('.')[1]
                $tags = @('SCuBA', "SCuBA.$baseline")
                if ([string]$control.Requirement -match 'indicator-bod' -or ($policy -and $policy.Badges -contains 'BOD 25-01 Requirement')) { $tags += 'BOD-25-01' }

                $instance = [ordered]@{
                    Id      = $id
                    Title   = if ($requirement) { $requirement } elseif ($policy) { [string]$policy.Title } else { [string]$control.'Control ID' }
                    Tag     = $tags
                    # The row is filed under the built-in CISA suite's requirement, so the report's framework view shows
                    # ScubaGear's result next to Maester's own CISA test. Maester leaves out a requirement it does not know.
                    Control = "cisa-scuba:$id"
                    Data  = [pscustomobject]@{
                        Product  = $product.Name
                        Group    = [string]$group.GroupName
                        GroupUrl = [string]$group.GroupReferenceURL
                        Control  = $control
                        Policy   = $policy
                    }
                }
                if ($criticality -like 'Shall*') { $instance.Severity = 'High' }
                elseif ($criticality -like 'Should*') { $instance.Severity = 'Medium' }
                # Maester's product for the baseline; Power Platform has none, so its rows keep the family's.
                $productKey = $baselineProduct[$baseline]
                if ($productKey) { $instance.Product = $productKey }
                if ($policy -and @($policy.Mitre).Count -gt 0) { $instance.Mitre = [string[]]@($policy.Mitre) }
                [pscustomobject]$instance
            }
        }
    }
}

function ConvertFrom-MtScubaGearHtml {
    <#
    .SYNOPSIS
    Turns the HTML ScubaGear puts in a result's requirement and details into Markdown text.

    .DESCRIPTION
    ScubaGear writes its details for its own HTML report: links, line breaks, bold text and the odd list. Links to
    a web page are kept as Markdown links; links to an anchor in ScubaGear's report, which Maester does not have,
    keep only their text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()] [string] $Html
    )

    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $text = $Html -replace '(?i)<br\s*/?>', "`n" -replace '(?i)</(p|div|tr|ul|ol)>', "`n" -replace '(?i)<li[^>]*>', "`n- "
    $text = $text -replace "(?is)<a\s[^>]*?href\s*=\s*['""]([^'""]*)['""][^>]*>(.*?)</a>", {
        $label = ($_.Groups[2].Value -replace '<[^>]+>', '').Trim()
        $url = $_.Groups[1].Value
        if ($url -match '^https?://' -and $label) { "[$label]($url)" } else { $label }
    }
    $text = $text -replace '(?is)<(strong|b)>(.*?)</\1>', {
        $inner = $_.Groups[2].Value.Trim()
        if ($inner) { "**$inner** " } else { '' }
    }
    $text = [System.Net.WebUtility]::HtmlDecode(($text -replace '<[^>]+>', ''))
    $lines = foreach ($line in $text -split "`r?`n") { ($line -replace '[ \t ]+', ' ').Trim() }
    (($lines -join "`n") -replace "`n{3,}", "`n`n").Trim()
}

function Get-MtScubaGearDescription {
    <#
    .SYNOPSIS
    Returns the Markdown description of a result: the policy, why it matters, and how to meet it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        # The Data of an MP.SCUBA.M365 instance.
        [Parameter(Mandatory)] $Data
    )

    $control = $Data.Control
    $policy = $Data.Policy
    $controlId = [string]$control.'Control ID'
    $anchor = ($controlId -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
    $baseline = if ($Data.GroupUrl -match '^(https://[^#]+)') { "$($Matches[1])#$anchor" } else { '' }
    $heading = if ($baseline) { "[$controlId]($baseline)" } else { $controlId }
    $criticality = [string]$control.Criticality
    if (-not $criticality -or $criticality -eq '-') { $criticality = if ($policy) { [string]$policy.Criticality } else { '' } }

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add((@($heading, $criticality.ToUpperInvariant(), $Data.Group) | Where-Object { $_ }) -join ' · ')
    if ($policy -and $policy.Rationale) { $parts.Add([string]$policy.Rationale) }
    if ($policy -and @($policy.License).Count -gt 0) { $parts.Add("**Licence:** $(@($policy.License) -join ' ')") }
    if ($policy -and $policy.Implementation) { $parts.Add("#### Remediation`n`n$($policy.Implementation)") }
    if ($policy -and @($policy.Notes).Count -gt 0) { $parts.Add((@($policy.Notes | ForEach-Object { "- $_" }) -join "`n")) }
    if ($policy -and @($policy.Resources).Count -gt 0) {
        $parts.Add("#### Learn more`n`n" + (@($policy.Resources | ForEach-Object { "- [$($_.Name)]($($_.Url))" }) -join "`n"))
    }
    $parts -join "`n`n"
}

function Get-MtScubaGearOrganization {
    <#
    .SYNOPSIS
    Returns the tenant's initial domain (contoso.onmicrosoft.com), which Invoke-SCuBA -Organization takes.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $organization = @(Invoke-MtGraphRequest -RelativeUri 'organization' -ErrorAction Stop) | Select-Object -First 1
    @($organization.verifiedDomains | Where-Object { $_.isInitial }) | Select-Object -First 1 -ExpandProperty name
}

function Invoke-MtScubaGearCollection {
    <#
    .SYNOPSIS
    Runs CISA's ScubaGear in a child PowerShell process and returns the folder it wrote its results in.

    .DESCRIPTION
    ScubaGear 2.0 runs in Windows PowerShell 5.1, and Maester in PowerShell 7, so it cannot share Maester's
    process. Even where it imports, it pins its own Microsoft.Graph.Authentication version and connects and
    disconnects Graph sessions of its own. So it runs in a separate process: powershell.exe on Windows by default,
    or the PowerShell the ScubaGear.PowerShell setting names. The child signs in with Invoke-SCuBA and Maester
    reads the ScubaResults file it writes.

    The child signs in to the tenant Maester is connected to when Maester is connected to Graph app-only with a
    certificate: it uses the same app and certificate, found by its thumbprint in the certificate store, and the
    tenant's initial domain. Otherwise ScubaGear signs in interactively, with a sign-in window. The
    ScubaGear.Parameters setting passes any other Invoke-SCuBA parameters.

    The child's output is read line by line and shown with Write-MtTestOutput, its progress bars as one line that
    updates in place.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $powershell = [string](Get-MtSetting -Name 'ScubaGear.PowerShell' -Default '')
    if ([string]::IsNullOrWhiteSpace($powershell)) {
        if (-not $IsWindows) {
            Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason 'ScubaGear 2.0 runs only on Windows, in Windows PowerShell 5.1. Run Invoke-SCuBA on a Windows computer and set ScubaGear.ReportPath to the folder it wrote, or set ScubaGear.PowerShell to pwsh once a version of ScubaGear runs in PowerShell 7 on this platform.'
        }
        $powershell = 'powershell'
    }
    $executable = Get-Command -Name $powershell -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    if (-not $executable) {
        Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason "Maester cannot find '$powershell' to run ScubaGear in. Set ScubaGear.PowerShell to powershell, pwsh or the full path of a PowerShell executable, or set ScubaGear.ReportPath to results you already have."
    }

    $outputPath = [string](Get-MtSetting -Name 'ScubaGear.OutputPath' -Default '')
    $temporary = [string]::IsNullOrWhiteSpace($outputPath)
    if ($temporary) {
        $outputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("maester-scubagear-{0}" -f [guid]::NewGuid().ToString('n'))
    }
    $outputPath = [System.IO.Path]::GetFullPath($outputPath)
    $null = New-Item -ItemType Directory -Path $outputPath -Force

    # Quiet: ScubaGear opens its HTML report in the browser unless told not to.
    $parameters = [ordered]@{ OutPath = $outputPath; Quiet = $true }
    # Invoke-SCuBA compares product names case-sensitively, in lower case.
    $products = @(@(Get-MtSetting -Name 'ScubaGear.ProductNames' -Default @()) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if ($products.Count -gt 0) { $parameters.ProductNames = [string[]]$products }
    $configFile = [string](Get-MtSetting -Name 'ScubaGear.ConfigFilePath' -Default '')
    if ($configFile) { $parameters.ConfigFilePath = [System.IO.Path]::GetFullPath($configFile) }

    $context = if (Get-Command -Name Get-MgContext -ErrorAction Ignore) { Get-MgContext } else { $null }
    $environment = [string](Get-MtSetting -Name 'ScubaGear.M365Environment' -Default '')
    # Graph's USGov and USGovDoD clouds are ScubaGear's gcchigh and dod. Global is commercial or gcc, which
    # ScubaGear tells apart itself, so it is not passed.
    if (-not $environment -and $context) { $environment = switch ([string]$context.Environment) { 'USGov' { 'gcchigh' } 'USGovDoD' { 'dod' } default { '' } } }
    if ($environment) { $parameters.M365Environment = $environment.ToLowerInvariant() }

    $parameterSetting = Get-MtSetting -Name 'ScubaGear.Parameters' -Default $null
    if ($context -and [string]$context.AuthType -eq 'AppOnly') {
        # Connected with a certificate object, the context names it in Certificate rather than CertificateThumbprint.
        $thumbprint = [string]$context.CertificateThumbprint
        if (-not $thumbprint -and $context.PSObject.Properties['Certificate'] -and $context.Certificate) { $thumbprint = [string]$context.Certificate.Thumbprint }
        if ($thumbprint) {
            $parameters.AppID = $context.ClientId
            $parameters.CertificateThumbprint = $thumbprint
            if (-not ($parameterSetting -and $parameterSetting.PSObject.Properties['Organization'])) {
                $organization = Get-MtScubaGearOrganization
                if ($organization) { $parameters.Organization = $organization }
            }
        } elseif (-not $parameterSetting) {
            # Invoke-SCuBA signs in app-only only with a certificate; without one the child would wait for a person to sign in.
            if ($temporary) { Remove-Item -LiteralPath $outputPath -Recurse -Force -ErrorAction SilentlyContinue }
            Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason 'Maester is connected app-only without a certificate (a client secret, a managed identity or workload identity federation), and ScubaGear signs in app-only only with a certificate in the certificate store. Connect Maester with a certificate, set ScubaGear.Parameters, or run Invoke-SCuBA as its own step and set ScubaGear.ReportPath.'
            return
        }
    }
    if ($parameterSetting) {
        foreach ($property in $parameterSetting.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    }

    $request = Join-Path ([System.IO.Path]::GetTempPath()) ("maester-scubagear-request-{0}.json" -f [guid]::NewGuid().ToString('n'))
    [ordered]@{
        ModulePath     = [string](Get-MtSetting -Name 'ScubaGear.ModulePath' -Default '')
        MinimumVersion = '2.0.0'
        Parameters     = $parameters
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $request -Encoding utf8

    # The child reads its parameters from the request file, so nothing from the config is put on a command line.
    # It must run in Windows PowerShell 5.1 as well as PowerShell 7. Its output is read by Maester as lines of
    # plain text. Its progress bars cannot be drawn there, so each change of one is written as a line that starts
    # with a marker (ScubaGear's own Write-Progress calls find this function before the cmdlet), which Maester
    # shows as one line that updates in place. Exit code 3 means ScubaGear is not installed for that PowerShell,
    # 4 that the installed version is too old.
    $progressMarker = "[maester-progress-$([guid]::NewGuid().ToString('n').Substring(0, 8))] "
    $script = @'
param([string] $RequestPath, [string] $ProgressMarker)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
function global:Write-Progress {
    # Not an advanced function: a parameter it does not declare goes to $args instead of failing the call.
    param([string] $Activity, [string] $Status, [int] $Id, [int] $PercentComplete = -1, [string] $CurrentOperation, [switch] $Completed)
    if ($Completed) {
        # An empty line of progress takes the line away.
        if ($global:__MtScubaGearProgress) { [Console]::Out.WriteLine($ProgressMarker) }
        $global:__MtScubaGearProgress = $null
        return
    }
    $text = @($Activity, $Status, $CurrentOperation) | Where-Object { $_ }
    $text = $text -join ': '
    if ($PercentComplete -ge 0) { $text += " ($PercentComplete%)" }
    if ($text -and $text -ne $global:__MtScubaGearProgress) {
        $global:__MtScubaGearProgress = $text
        [Console]::Out.WriteLine($ProgressMarker + $text)
    }
}
$request = Get-Content -LiteralPath $RequestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$module = if ($request.ModulePath) {
    # Get-Module -ListAvailable reports a path that does not exist as a module of version 0.0.
    if (Test-Path -LiteralPath $request.ModulePath) { Get-Module -ListAvailable -Name $request.ModulePath }
} else {
    Get-Module -ListAvailable -Name ScubaGear | Sort-Object -Property Version -Descending | Select-Object -First 1
}
if (-not $module) {
    [Console]::Error.WriteLine("ScubaGear is not installed for PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition)).")
    exit 3
}
if ($module.Version -lt [version] $request.MinimumVersion) {
    [Console]::Error.WriteLine("ScubaGear $($module.Version) is installed; the Maester pack needs $($request.MinimumVersion) or later. Run Update-Module ScubaGear.")
    exit 4
}
[Console]::Out.WriteLine("ScubaGear $($module.Version) in PowerShell $($PSVersionTable.PSVersion)")
Import-Module -Name $module.Path
# Windows PowerShell has no ConvertFrom-Json -AsHashtable; lists become string arrays for parameters such as -ProductNames.
$parameters = @{}
foreach ($property in $request.Parameters.PSObject.Properties) {
    $value = $property.Value
    if ($value -is [array]) { $value = [string[]] $value }
    $parameters[$property.Name] = $value
}
Invoke-SCuBA @parameters
'@
    $scriptPath = Join-Path ([System.IO.Path]::GetTempPath()) ("maester-scubagear-run-{0}.ps1" -f [guid]::NewGuid().ToString('n'))
    # With a byte order mark, Windows PowerShell reads the script as UTF-8.
    Set-Content -LiteralPath $scriptPath -Value $script -Encoding utf8BOM

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($executable.Source)
    # The execution policy applies to this process only: Windows PowerShell refuses to run a script file on a
    # computer whose policy is Restricted, the default on Windows clients.
    foreach ($argument in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RequestPath', $request, '-ProgressMarker', $progressMarker) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    # The child must not write to the console itself: while Maester's dashboard has the screen, that would
    # draw over it. Maester shows what it writes instead.
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    # The last lines it wrote, for the error when it fails.
    $tail = [System.Collections.Generic.Queue[string]]::new()
    $show = {
        param([string] $Line)
        $progress = $Line.StartsWith($progressMarker)
        if ($progress) {
            $Line = $Line.Substring($progressMarker.Length)
        } elseif ($Line.Trim() -and -not $Line.StartsWith('##maester[progress]')) {
            # The error message gets the line without its colours and other control characters.
            $tail.Enqueue(($Line -replace "`e\[[0-9;?]*[ -/]*[@-~]", '' -replace '[\x00-\x08\x0B-\x1F\x7F]', '').TrimEnd())
            if ($tail.Count -gt 15) { $null = $tail.Dequeue() }
        }
        Write-MtTestOutput -InputObject $Line -Progress:$progress
    }
    $process = $null
    $completed = $false
    $exitCode = $null
    try {
        $signIn = if ($parameters.Contains('CertificateThumbprint')) { 'It signs in with the app and certificate Maester uses.' } else { 'ScubaGear asks you to sign in, in a window of its own, for the products it checks.' }
        Write-MtTestOutput -Title 'CISA ScubaGear' -InputObject "Running ScubaGear in $([System.IO.Path]::GetFileNameWithoutExtension($executable.Source)), a separate PowerShell process. $signIn"
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $readers = @($process.StandardOutput, $process.StandardError)
        $reads = [System.Threading.Tasks.Task[]]@($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
        $exited = $null
        while ($reads[0] -or $reads[1]) {
            # Wait in short steps so a stop request (a timeout or Ctrl+C) is seen between them.
            $null = [System.Threading.Tasks.Task]::WaitAny([System.Threading.Tasks.Task[]]@($reads | Where-Object { $_ }), 1000)
            for ($i = 0; $i -lt 2; $i++) {
                if (-not $reads[$i] -or -not $reads[$i].IsCompleted) { continue }
                $line = $reads[$i].GetAwaiter().GetResult()
                if ($null -eq $line) { $reads[$i] = $null; continue }
                $reads[$i] = $readers[$i].ReadLineAsync()
                & $show $line
            }
            # A process the child started can keep its output open after it ends: give it a few seconds.
            if ($process.HasExited) {
                if (-not $exited) { $exited = [System.Diagnostics.Stopwatch]::StartNew() }
                elseif ($exited.Elapsed.TotalSeconds -gt 5) { break }
            }
        }
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $completed = $exitCode -eq 0
    } finally {
        # Stopping the Maester run (a timeout or Ctrl+C) stops ScubaGear too.
        if ($process -and -not $process.HasExited) { $process.Kill($true); $null = $process.WaitForExit(5000) }
        Write-MtTestOutput -Complete
        Remove-Item -LiteralPath $request, $scriptPath -Force -ErrorAction SilentlyContinue
        # The provider export holds tenant data. Get-MtScubaGearInstance removes it after a run that completed; this removes what a failed or stopped run left.
        if ($temporary -and -not $completed) { Remove-Item -LiteralPath $outputPath -Recurse -Force -ErrorAction SilentlyContinue }
    }

    $last = if ($tail.Count -gt 0) { $tail.ToArray()[-1] } else { '' }
    switch ($exitCode) {
        0 { }
        3 {
            Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason "ScubaGear is not installed for $($executable.Source). $last In Windows PowerShell, run Install-Module ScubaGear -Scope CurrentUser and then Initialize-SCuBA, or set ScubaGear.ReportPath to results you already have."
        }
        4 { Add-MtTestResultDetail -SkippedBecause Custom -SkippedCustomReason $last }
        default {
            $where = if ($temporary) { '' } else { " Its output is in $outputPath." }
            $lines = if ($tail.Count -gt 0) { " Its last lines:`n" + ($tail.ToArray() -join "`n") } else { '' }
            throw "ScubaGear ended with exit code $exitCode.$where$lines"
        }
    }

    [pscustomobject]@{
        OutputPath = $outputPath
        Temporary  = $temporary
    }
}

function Test-MtScubaGear {
    [MaesterTest(
        Id = 'MP.SCUBA.M365',
        Title = 'CISA ScubaGear for Microsoft 365',
        Product = 'ScubaGear',
        LongRunning = $true,
        InstanceSource = 'Get-MtScubaGearInstance',
        Tag = 'SCuBA',
        Author = 'merill',
        HelpUrl = 'https://github.com/maester365/maester-pack-scubagear'
    )]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        # One policy result of ScubaGear, supplied by the engine.
        $Instance
    )

    $control = $Instance.Data.Control
    $description = Get-MtScubaGearDescription -Data $Instance.Data
    $details = ConvertFrom-MtScubaGearHtml -Html ([string]$control.Details)

    switch -Wildcard ([string]$control.Result) {
        'Pass' {
            Add-MtTestResultDetail -Description $description -Result $details
            return $true
        }
        'Fail' {
            Add-MtTestResultDetail -Description $description -Result $details
            return $false
        }
        'Warning' {
            # A SHOULD policy that is not met. Its severity is Medium; a SHALL policy that fails is High.
            Add-MtTestResultDetail -Description $description -Result $details
            return $false
        }
        'N/A' {
            # A policy ScubaGear does not check itself: a manual check, or one a third-party product can meet.
            $reason = if ($details) { $details } else { 'ScubaGear does not check this policy automatically.' }
            Add-MtTestResultDetail -Description $description -SkippedBecause Custom -SkippedCustomReason $reason
        }
        'Omitted' {
            $reason = if ($details) { "Omitted in the ScubaGear configuration file. $details" } else { 'Omitted in the ScubaGear configuration file.' }
            Add-MtTestResultDetail -Description $description -SkippedBecause Custom -SkippedCustomReason $reason
        }
        'Incorrect result' {
            $original = [string]$control.IncorrectResult
            $reason = "Marked as an incorrect result in the ScubaGear configuration file$(if ($original -and $original -ne 'N/A') { "; ScubaGear's own result was $original" })."
            Add-MtTestResultDetail -Description $description -SkippedBecause Custom -SkippedCustomReason $reason
        }
        default {
            # Error, Error - Test results missing, or a result this version of the pack does not know.
            Add-MtTestResultDetail -Description $description -Result $details -SkippedBecause Error
        }
    }
}
