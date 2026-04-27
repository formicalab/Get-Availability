# Modules Directory

This folder holds the PowerShell modules required by the function app at runtime.

Since the Flex Consumption plan **does not support managed dependencies**, modules
must be saved here manually using `Save-Module`:

```powershell
Save-Module -Name Az.Accounts      -Path . -Repository PSGallery -Force
Save-Module -Name Az.ResourceGraph  -Path . -Repository PSGallery -Force
```

The `get-availability.ps1` script requires:
- **Az.Accounts** — `Get-AzAccessToken`, `Get-AzContext`, `Connect-AzAccount`
- **Az.ResourceGraph** — `Search-AzGraph`

> Do not commit the module folders themselves to source control — they are large
> and version-pinned. Instead, run `Save-Module` as part of your deployment pipeline
> or locally before publishing with `func azure functionapp publish`.
