# Unit tests of the pack, run with Pester against an installed Maester (see .github/workflows/check-pack.yml):
#   Invoke-Pester ./spec
# Set MAESTER_MODULE to a Maester.psd1 to test against a checkout of Maester instead.
Describe 'ScubaGear pack' {
    BeforeAll {
        $maester = if ($env:MAESTER_MODULE) { $env:MAESTER_MODULE } else { 'Maester' }
        Import-Module $maester -Force -WarningAction SilentlyContinue
        $script:PackRoot = (Resolve-Path "$PSScriptRoot/..").Path
        $script:TestsPath = Join-Path $script:PackRoot 'tests'
        $script:Fixture = (Resolve-Path "$PSScriptRoot/fixtures").Path
        $script:FixtureFile = Get-ChildItem -LiteralPath $script:Fixture -Filter 'ScubaResults*.json' -File -Recurse | Select-Object -First 1 -ExpandProperty FullName

        # The fixture is a cut of ScubaGear's own sample results, with one control of each result it writes: Pass,
        # Fail, Warning and N/A from the sample, and Omitted, Incorrect result, Error and a deleted control ('-') in
        # the shapes its report module writes them.
        function Invoke-ScubaGearPack {
            param([hashtable] $Setting = @{})
            $globalSettings = @{ 'ScubaGear.ReportPath' = $script:Fixture; 'ScubaGear.MaxReportAgeDays' = 0 }
            foreach ($key in $Setting.Keys) { $globalSettings[$key] = $Setting[$key] }
            $config = [pscustomobject]@{
                GlobalSettings = [pscustomobject]$globalSettings
                Environment    = [pscustomobject]@{ Enforce = [pscustomobject]@{ Service = $false } }
            }
            @(Invoke-MtTest -Path $script:TestsPath -Id MP.SCUBA.M365 -Config $config)
        }

        $script:Rows = Invoke-ScubaGearPack
    }

    AfterEach {
        # Removes only the stand-in a test defined, never a Get-MgContext a module exports.
        Get-Item -Path function:Get-MgContext -ErrorAction SilentlyContinue | Where-Object { -not $_.Module } | Remove-Item
    }

    Context 'the pack files' {
        It 'has a valid native test' {
            $test = Get-MtTest -Path (Join-Path $script:TestsPath 'Test.MP.SCUBA.M365.ps1')
            $test.IsValid | Should -BeTrue
            $test.Errors | Should -BeNullOrEmpty
            $test.LongRunning | Should -BeTrue
            $test.InstanceSource | Should -Be 'Get-MtScubaGearInstance'
            $test.Suite | Should -Be 'SCUBA.M365'
        }

        It 'passes the checks Install-MtPack runs, on the files it ships' {
            # Install-MtPack checks GitHub's archive of the release, which leaves out the export-ignore paths of
            # .gitattributes (the catalog builder and these tests). Check a copy without them.
            $ignored = @(Get-Content -LiteralPath (Join-Path $script:PackRoot '.gitattributes') |
                    Where-Object { $_ -match '^/(\S+)\s+export-ignore\b' } | ForEach-Object { $Matches[1] })
            $shipped = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'shipped') -Force
            Get-ChildItem -LiteralPath $script:PackRoot -Force | Where-Object { $_.Name -ne '.git' -and $_.Name -notin $ignored } |
                Copy-Item -Destination $shipped -Recurse -Force
            $check = Test-MtPack $shipped.FullName -Official
            $check.IsValid | Should -BeTrue
            $check.Errors | Should -BeNullOrEmpty
            $check.Id | Should -Be 'maester365.scubagear'
            $check.TestIds | Should -Be @('MP.SCUBA.M365')
        }

        It 'has a catalog of unique policy IDs' {
            $catalog = Get-Content (Join-Path $script:PackRoot 'catalog.json') -Raw | ConvertFrom-Json
            $catalog.ModuleVersion | Should -Not -BeNullOrEmpty
            $catalog.Tests.Count | Should -BeGreaterThan 0
            @($catalog.Tests.Id | Where-Object { $_ -notmatch '^MP\.SCUBA\.M365\.MS\.[A-Z]+\.\d+\.\d+$' }) | Should -BeNullOrEmpty
            @($catalog.Tests.Id | Sort-Object -Unique).Count | Should -Be $catalog.Tests.Count
            @($catalog.Tests | Where-Object { [string]::IsNullOrWhiteSpace($_.Title) }) | Should -BeNullOrEmpty
        }
    }

    Context 'reading results' {
        It 'writes one row per policy result and leaves out deleted policies' {
            $script:Rows.Count | Should -Be 7
            $script:Rows.Id | Should -Not -Contain 'MP.SCUBA.M365.MS.TEAMS.1.4'
            @($script:Rows | Where-Object ParentId -ne 'MP.SCUBA.M365') | Should -BeNullOrEmpty
        }

        It 'maps <Id> to <Result>' -ForEach @(
            @{ Id = 'MP.SCUBA.M365.MS.AAD.2.1'; Result = 'Passed' }
            @{ Id = 'MP.SCUBA.M365.MS.AAD.1.1'; Result = 'Failed' }
            @{ Id = 'MP.SCUBA.M365.MS.AAD.3.7'; Result = 'Failed' }
            @{ Id = 'MP.SCUBA.M365.MS.AAD.2.2'; Result = 'Skipped' }
            @{ Id = 'MP.SCUBA.M365.MS.TEAMS.1.1'; Result = 'Skipped' }
            @{ Id = 'MP.SCUBA.M365.MS.TEAMS.1.2'; Result = 'Skipped' }
            @{ Id = 'MP.SCUBA.M365.MS.TEAMS.1.3'; Result = 'Error' }
        ) {
            ($script:Rows | Where-Object Id -eq $Id).Result | Should -Be $Result
        }

        It 'rates a SHALL policy High and a SHOULD policy Medium' {
            ($script:Rows | Where-Object Id -eq 'MP.SCUBA.M365.MS.AAD.1.1').Severity | Should -Be 'High'
            ($script:Rows | Where-Object Id -eq 'MP.SCUBA.M365.MS.AAD.3.7').Severity | Should -Be 'Medium'
        }

        It 'keeps the requirement as the title, without the HTML of its badges' {
            $row = $script:Rows | Where-Object Id -eq 'MP.SCUBA.M365.MS.AAD.1.1'
            $row.Title | Should -Be 'Legacy authentication SHALL be blocked.'
            $row.Tag | Should -Contain 'SCuBA.AAD'
            $row.Tag | Should -Contain 'BOD25-01'
        }

        It 'describes the policy from the catalog and turns the details into Markdown' {
            $row = $script:Rows | Where-Object Id -eq 'MP.SCUBA.M365.MS.AAD.1.1'
            $row.ResultDetail.TestDescription | Should -BeLike '*MS.AAD.1.1v1*'
            $row.ResultDetail.TestDescription | Should -BeLike '*#### Remediation*'
            $row.ResultDetail.TestResult | Should -BeLike '*0 conditional access policy(s) found*'
            $row.ResultDetail.TestResult | Should -BeLike '***Near miss:** *'
            $row.ResultDetail.TestResult | Should -Not -Match '<[a-z]+[ >]'
        }

        It 'gives the reason for a policy ScubaGear omitted, does not check or was told is wrong' {
            ($script:Rows | Where-Object Id -eq 'MP.SCUBA.M365.MS.AAD.2.2').ReasonDetail | Should -BeLike '*does not currently have the capability*'
            ($script:Rows | Where-Object Id -eq 'MP.SCUBA.M365.MS.TEAMS.1.1').ReasonDetail | Should -BeLike 'Omitted in the ScubaGear configuration file.*Handled by a third-party tool*'
            ($script:Rows | Where-Object Id -eq 'MP.SCUBA.M365.MS.TEAMS.1.2').ReasonDetail | Should -BeLike "*ScubaGear's own result was Fail."
        }

        It 'reads the results file itself, the folder of the run, or the folder above it' {
            (Invoke-ScubaGearPack -Setting @{ 'ScubaGear.ReportPath' = $script:FixtureFile }).Count | Should -Be 7
            (Invoke-ScubaGearPack -Setting @{ 'ScubaGear.ReportPath' = (Split-Path $script:FixtureFile -Parent) }).Count | Should -Be 7
        }

        It 'skips the family when there are no results' {
            $rows = Invoke-ScubaGearPack -Setting @{ 'ScubaGear.ReportPath' = (Join-Path $TestDrive 'none') }
            $rows.Count | Should -Be 1
            $rows[0].Result | Should -Be 'Skipped'
            $rows[0].ReasonDetail | Should -BeLike '*No ScubaGear results file*'
        }

        It 'skips the family when the results are too old' {
            $rows = Invoke-ScubaGearPack -Setting @{ 'ScubaGear.MaxReportAgeDays' = 7 }
            $rows.Count | Should -Be 1
            $rows[0].ReasonDetail | Should -BeLike '*written on 2026-01-15, more than 7 days ago*'
        }

        It 'skips the family when the results are for another tenant' {
            function global:Get-MgContext { [pscustomobject]@{ TenantId = '00000000-0000-0000-0000-000000000001' } }
            $rows = Invoke-ScubaGearPack
            $rows.Count | Should -Be 1
            $rows[0].Result | Should -Be 'Skipped'
            $rows[0].ReasonDetail | Should -BeLike '*are for tenant 22222222-2222-2222-2222-222222222222*'
        }
    }

    Context 'running ScubaGear' {
        BeforeAll {
            # A stand-in for the ScubaGear module: it records what Invoke-SCuBA was called with and writes the
            # fixture where Invoke-SCuBA writes its own results. It runs in this PowerShell, so the test runs on
            # any platform; on Windows the pack runs Windows PowerShell by default.
            $script:FakeModule = New-Item -ItemType Directory -Path (Join-Path -Path $TestDrive -ChildPath 'modules' -AdditionalChildPath 'ScubaGear', '9.9.9') -Force
            $script:CallLog = Join-Path $TestDrive 'calls.json'
            Set-Content -LiteralPath (Join-Path $script:FakeModule 'ScubaGear.psd1') -Value "@{ RootModule = 'ScubaGear.psm1'; ModuleVersion = '9.9.9'; CompatiblePSEditions = 'Desktop'; FunctionsToExport = 'Invoke-SCuBA' }"
            Set-Content -LiteralPath (Join-Path $script:FakeModule 'ScubaGear.psm1') -Value @"
function Invoke-SCuBA {
    param([string[]] `$ProductNames, [string] `$M365Environment, [string] `$OutPath, [switch] `$Quiet, [string] `$ConfigFilePath, [string] `$AppID, [string] `$CertificateThumbprint, [string] `$Organization)
    Write-Host 'Connecting to the tenant'
    Write-Progress -Activity 'Running providers' -Status 'aad' -PercentComplete 50
    `$run = New-Item -ItemType Directory -Path (Join-Path `$OutPath 'M365BaselineConformance_2026_10_29_08_00_00') -Force
    Copy-Item -LiteralPath '$($script:FixtureFile)' -Destination `$run
    `$PSBoundParameters | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath '$($script:CallLog)'
}
"@
            $script:Child = @{
                'ScubaGear.ReportPath' = ''
                'ScubaGear.PowerShell' = (Get-Process -Id $PID).Path
                'ScubaGear.ModulePath' = (Join-Path $script:FakeModule 'ScubaGear.psd1')
            }
            # Write-MtTestOutput writes to the host, not to a stream Pester can read. Maester's own line writer is
            # internal, so the test of what is shown runs only where Maester still has it.
            $script:CanSeeOutput = [bool](& (Get-Module Maester) { Get-Command -Name Write-MtHostLine -ErrorAction Ignore })
        }

        It 'runs Invoke-SCuBA in a child process and reads its results' {
            $output = Join-Path $TestDrive 'scuba-output'
            $rows = Invoke-ScubaGearPack -Setting ($script:Child + @{
                    'ScubaGear.OutputPath'      = $output
                    'ScubaGear.ProductNames'    = @('AAD', 'teams')
                    'ScubaGear.M365Environment' = 'GCC'
                })
            $rows.Count | Should -Be 7
            Test-Path (Join-Path $output 'M365BaselineConformance_2026_10_29_08_00_00') | Should -BeTrue

            $call = Get-Content -LiteralPath $script:CallLog -Raw | ConvertFrom-Json
            $call.OutPath | Should -Be ([System.IO.Path]::GetFullPath($output))
            $call.Quiet | Should -BeTrue
            # Invoke-SCuBA compares product names and environments in lower case.
            $call.ProductNames | Should -Be @('aad', 'teams')
            $call.M365Environment | Should -Be 'gcc'
        }

        It 'shows what the child writes while it runs, its progress as a line of progress' {
            if (-not $script:CanSeeOutput) { Set-ItResult -Skipped -Because 'this Maester has no Write-MtHostLine to watch' }
            $script:Shown = [System.Collections.Generic.List[object]]::new()
            Mock -ModuleName Maester Write-MtHostLine { $script:Shown.Add($Text) }
            $rows = Invoke-ScubaGearPack -Setting $script:Child
            $rows.Count | Should -Be 7
            $shown = @($script:Shown -replace "`e\[[0-9;]*m", '')
            $shown | Should -Contain '  CISA ScubaGear'
            $shown | Should -Contain ('    ScubaGear 9.9.9 in PowerShell ' + $PSVersionTable.PSVersion)
            $shown | Should -Contain '    Connecting to the tenant'
            $shown | Should -Contain '    Running providers: aad (50%)'
            @($shown | Where-Object { $_ -match 'maester-progress' }) | Should -BeNullOrEmpty
        }

        It 'signs the child in with the app and certificate Maester uses' {
            function global:Get-MgContext {
                [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222'; AuthType = 'AppOnly'; ClientId = 'app-id'; CertificateThumbprint = 'ABC123'; Environment = 'USGov' }
            }
            $null = Invoke-ScubaGearPack -Setting ($script:Child + @{ 'ScubaGear.Parameters' = [pscustomobject]@{ Organization = 'contoso.onmicrosoft.com' } })
            $call = Get-Content -LiteralPath $script:CallLog -Raw | ConvertFrom-Json
            $call.AppID | Should -Be 'app-id'
            $call.CertificateThumbprint | Should -Be 'ABC123'
            $call.Organization | Should -Be 'contoso.onmicrosoft.com'
            $call.M365Environment | Should -Be 'gcchigh'
        }

        It 'skips the family, rather than wait for a sign-in, when Maester is connected app-only without a certificate' {
            function global:Get-MgContext {
                [pscustomobject]@{ TenantId = '22222222-2222-2222-2222-222222222222'; AuthType = 'AppOnly'; ClientId = 'app-id'; CertificateThumbprint = $null }
            }
            $rows = Invoke-ScubaGearPack -Setting $script:Child
            $rows.Count | Should -Be 1
            $rows[0].Result | Should -Be 'Skipped'
            $rows[0].ReasonDetail | Should -BeLike '*signs in app-only only with a certificate*'
        }

        It 'deletes a temporary output folder after reading it' {
            $before = @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'maester-scubagear-*' -ErrorAction SilentlyContinue).Count
            $rows = Invoke-ScubaGearPack -Setting $script:Child
            $rows.Count | Should -Be 7
            @(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Filter 'maester-scubagear-*' -ErrorAction SilentlyContinue).Count | Should -Be $before
        }

        It 'skips the family when ScubaGear is not installed for that PowerShell' {
            $setting = $script:Child.Clone()
            $setting['ScubaGear.ModulePath'] = Join-Path $TestDrive 'missing/ScubaGear.psd1'
            $rows = Invoke-ScubaGearPack -Setting $setting
            $rows.Count | Should -Be 1
            $rows[0].Result | Should -Be 'Skipped'
            $rows[0].ReasonDetail | Should -BeLike '*ScubaGear is not installed for*Install-Module ScubaGear*'
        }

        It 'skips the family when the PowerShell to run it in is not found' {
            $setting = $script:Child.Clone()
            $setting['ScubaGear.PowerShell'] = 'no-such-powershell'
            $rows = Invoke-ScubaGearPack -Setting $setting
            $rows.Count | Should -Be 1
            $rows[0].ReasonDetail | Should -BeLike "*cannot find 'no-such-powershell'*"
        }

        It 'says ScubaGear runs only on Windows when no PowerShell is set on another platform' {
            if ($IsWindows) { Set-ItResult -Skipped -Because 'on Windows the pack runs Windows PowerShell by default' }
            $rows = Invoke-ScubaGearPack -Setting @{ 'ScubaGear.ReportPath' = '' }
            $rows.Count | Should -Be 1
            $rows[0].Result | Should -Be 'Skipped'
            $rows[0].ReasonDetail | Should -BeLike '*runs only on Windows, in Windows PowerShell 5.1*'
        }
    }
}
