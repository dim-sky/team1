# Deletes everything deploy.ps1 created, one resource at a time
# (the resource group itself is kept, since it may be shared).
#
#   .\azure\cleanup.ps1 -ResourceGroup "rg-instructor-01" -AcrName "team1acr12345"

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$AcrName,

    [string]$EnvironmentName = "team1-env",
    [string]$WorkspaceName = "team1-logs",
    [string]$AppPrefix = "team1"
)

function Assert-Success {
    if ($LASTEXITCODE -ne 0) {
        throw "Deletion failed with exit code $LASTEXITCODE"
    }
}

Write-Host "Deleting frontend Container App..."
az containerapp delete --name "$AppPrefix-frontend" --resource-group $ResourceGroup --yes
Assert-Success

Write-Host "Deleting backend Container App..."
az containerapp delete --name "$AppPrefix-backend" --resource-group $ResourceGroup --yes
Assert-Success

Write-Host "Deleting Container Apps environment..."
az containerapp env delete --name $EnvironmentName --resource-group $ResourceGroup --yes
Assert-Success

Write-Host "Deleting managed identity..."
az identity delete --name "$AppPrefix-acr-pull" --resource-group $ResourceGroup
Assert-Success

Write-Host "Deleting container registry..."
az acr delete --name $AcrName --resource-group $ResourceGroup --yes
Assert-Success

Write-Host "Deleting Log Analytics workspace..."
az monitor log-analytics workspace delete --workspace-name $WorkspaceName --resource-group $ResourceGroup --yes
Assert-Success

Write-Host "Cleanup complete. Remaining resources:"
az resource list --resource-group $ResourceGroup --output table
