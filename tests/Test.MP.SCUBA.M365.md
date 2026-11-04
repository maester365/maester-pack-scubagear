Runs CISA's [ScubaGear](https://github.com/cisagov/ScubaGear) and reports each of its policy results in the
Maester report, with the policy's rationale, remediation steps and ScubaGear's findings.

ScubaGear checks a Microsoft 365 tenant against CISA's Secure Cloud Business Applications (SCuBA) baselines for
Entra ID, Exchange Online, Defender and Purview (the security suite), SharePoint, Teams, Power Platform and Power BI.
Each result is its own row, `MP.SCUBA.M365.<policy ID>` (for example `MP.SCUBA.M365.MS.AAD.1.1`).

#### Running it

The pack is long-running and does not run by default. Run it with `Invoke-Maester -Pack SCUBA.M365` or
`-IncludeLongRunning`. It reads results ScubaGear already wrote when the `ScubaGear.ReportPath` setting names
them; otherwise, on Windows, it runs ScubaGear in Windows PowerShell, which needs the `ScubaGear` module installed
there.

<!--- Results --->
%TestResult%
