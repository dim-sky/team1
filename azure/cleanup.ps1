# Deletes everything deploy.ps1 created, one resource at a time
# (the resource group itself is kept, since it may be shared).
# Resources that don't exist are skipped, so this also works on a deployment
# made with the older version of deploy.ps1.
#
#   .\azure\cleanup.ps1 -ResourceGroup "rg-instructor-01" -AcrName "team1acr12345"

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$AcrName,

    [string]$EnvironmentName = "team1-env",
    [string]$WorkspaceName = "team1-logs",
    [string]$VnetName = "team1-vnet",
    [string]$AppPrefix = "team1"
)

function Assert-Success {
    if ($LASTEXITCODE -ne 0) {
        throw "Deletion failed with exit code $LASTEXITCODE"
    }
}

function Remove-IfExists([string]$Label, [string]$Name, [string]$Type) {
    $Ids = az resource list `
        --resource-group $ResourceGroup `
        --name $Name `
        --resource-type $Type `
        --query "[].id" `
        --output tsv
    Assert-Success

    if (-not $Ids) {
        Write-Host "Skipping $Label ($Name does not exist)"
        return
    }

    Write-Host "Deleting $Label ($Name)..."

    # A few tries, because Azure can take a moment to release a subnet after
    # the environment that used it is gone
    for ($Attempt = 1; $Attempt -le 3; $Attempt++) {
        az resource delete --ids $Ids --output none
        if ($LASTEXITCODE -eq 0) { return }

        if ($Attempt -lt 3) {
            Write-Host "  Not deleted yet, trying again in 30 seconds..."
            Start-Sleep -Seconds 30
        }
    }
    Assert-Success
}

# Apps and the job first, because they live inside the environment
Remove-IfExists "graph loader job" "$AppPrefix-graph-loader" "Microsoft.App/jobs"
Remove-IfExists "frontend Container App" "$AppPrefix-frontend" "Microsoft.App/containerApps"
Remove-IfExists "backend Container App" "$AppPrefix-backend" "Microsoft.App/containerApps"
Remove-IfExists "Neo4j Container App" "$AppPrefix-neo4j" "Microsoft.App/containerApps"

# The environment before the virtual network it uses
Remove-IfExists "Container Apps environment" $EnvironmentName "Microsoft.App/managedEnvironments"
Remove-IfExists "virtual network" $VnetName "Microsoft.Network/virtualNetworks"

Remove-IfExists "managed identity" "$AppPrefix-acr-pull" "Microsoft.ManagedIdentity/userAssignedIdentities"
Remove-IfExists "container registry" $AcrName "Microsoft.ContainerRegistry/registries"
Remove-IfExists "Log Analytics workspace" $WorkspaceName "Microsoft.OperationalInsights/workspaces"

Write-Host "Cleanup complete. Remaining resources:"
az resource list --resource-group $ResourceGroup --output table
