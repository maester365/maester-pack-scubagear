# Changelog

Every release of the pack, newest first. Install-MtPack shows the version; Update-MtPack moves to a newer one.

## 0.1.0

- The first release: one result per ScubaGear policy, `MP.SCUBA.M365.<policy ID>`, read from the ScubaResults file
  Invoke-SCuBA wrote, or from a run of ScubaGear 2.0 in Windows PowerShell 5.1 that Maester starts. The catalog is
  built from ScubaGear 2.0.0 (baselines 2.10.20).
- Each row of the AAD, EXO, Security Suite and SharePoint baselines names its policy as a `cisa-scuba` requirement,
  so the report's framework view shows it next to Maester's own CISA test. Each row is filed under Maester's product
  for its baseline (Power Platform rows stay under ScubaGear, which has no Maester product) with the policy's MITRE
  ATT&CK techniques. This needs Maester 3.0.0-rc59 or later.
