# Azure Functions profile.ps1
#
# Runs on every "cold start" of the Function App. Sets up Azure context
# so subsequent function invocations can call Az cmdlets immediately.

# Authenticate with Azure PowerShell using the Function App's managed identity.
if ($env:FUNCTIONS_WORKER_RUNTIME -eq 'powershell') {
    Disable-AzContextAutosave -Scope Process | Out-Null
    Connect-AzAccount -Identity
}
