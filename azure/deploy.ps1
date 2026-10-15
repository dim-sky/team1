# Builds the images, pushes them to Azure Container Registry, and deploys the
# frontend, backend and Neo4j as Azure Container Apps, plus the graph loader
# as a Container Apps Job. At the end it starts the loader once, so the graph
# is filled from Databricks right away.
#
# Run from anywhere, e.g. from the project folder:
#   .\azure\deploy.ps1 -ResourceGroup "rg-instructor-01" -Location "westeurope" -AcrName "team1acr12345"
#
# Upgrading from the version without Neo4j? Run cleanup.ps1 once first. The
# Container Apps environment now lives in a virtual network, and Azure can't
# add one to an environment that already exists.

param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [Parameter(Mandatory)]
    [string]$Location,

    # Globally unique, 5-50 lowercase letters and digits only
    [Parameter(Mandatory)]
    [string]$AcrName,

    [string]$EnvironmentName = "team1-env",
    [string]$WorkspaceName = "team1-logs",
    [string]$VnetName = "team1-vnet",
    [string]$AppPrefix = "team1",

    # Local image names, as set by "image:" in docker-compose.yml
    [string]$BackendImage = "team1-backend",
    [string]$FrontendImage = "team1-frontend",
    [string]$GraphLoaderImage = "team1-knowledge-graph",

    # Must match the neo4j "image:" in docker-compose.yml
    [string]$Neo4jImage = "neo4j:5.26",

    # .env files, relative to the project folder (the same ones docker-compose.yml uses)
    [string]$EnvFile = "backend\.env",
    [string]$GraphEnvFile = "knowledge-graph\.env",

    # Databricks schema with the gold tables (GOLD_SCHEMA in docker-compose.yml)
    [string]$GoldSchema = "data2026acc123456.team1",

    # Don't start the graph loader at the end of the deploy
    [switch]$SkipGraphLoad
)

$ErrorActionPreference = "Stop"

function Assert-LastCommand {
    if ($LASTEXITCODE -ne 0) {
        throw "The previous command failed with exit code $LASTEXITCODE"
    }
}

# Reads KEY=value lines from a .env file into an ordered dictionary
function Read-EnvFile([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Could not find $Path"
    }

    $Values = [ordered]@{}
    foreach ($Line in Get-Content $Path) {
        $Line = $Line.Trim()
        if ($Line -eq "" -or $Line.StartsWith("#")) { continue }

        $Parts = $Line -split "=", 2
        if ($Parts.Count -ne 2) { continue }

        $Key = $Parts[0].Trim()
        if ($Key.StartsWith("export ")) { $Key = $Key.Substring(7).Trim() }
        $Value = $Parts[1].Trim().Trim('"').Trim("'")

        if ($Value -ne "") { $Values[$Key] = $Value }
    }
    return $Values
}

# This script lives in project\azure, so the project folder is one level up
$ProjectRoot = Split-Path $PSScriptRoot -Parent

# A new tag on every deploy, so Azure always starts a new revision with the new image
$Tag = Get-Date -Format "yyyyMMddHHmmss"

# Inside the environment, Neo4j is reachable by its app name
$Neo4jUri = "bolt://$AppPrefix-neo4j:7687"

# ---------- 0. Read the .env files first, so a missing file fails fast ----------
$BackendEnv = Read-EnvFile (Join-Path $ProjectRoot $EnvFile)
$GraphEnv = Read-EnvFile (Join-Path $ProjectRoot $GraphEnvFile)

if (-not $GraphEnv.Contains("NEO4J_AUTH")) {
    throw "$GraphEnvFile has no NEO4J_AUTH (user/password) line"
}

# These two are set by apps.bicep for the cloud; local values such as
# bolt://localhost:7687 would point at the wrong place
$GraphEnv.Remove("NEO4J_URI")
$GraphEnv.Remove("GOLD_SCHEMA")

# If the backend talks to Neo4j too, point it at the cloud database
if ($BackendEnv.Contains("NEO4J_URI")) {
    $BackendEnv["NEO4J_URI"] = $Neo4jUri
}

# ---------- 1. Check that an existing environment has a virtual network ----------
$Environments = az containerapp env list `
    --resource-group $ResourceGroup `
    --query "[].{name:name, subnet:properties.vnetConfiguration.infrastructureSubnetId}" `
    --output json
Assert-LastCommand

$ExistingEnvironment = @(($Environments -join "`n") | ConvertFrom-Json) |
    Where-Object { $_.name -eq $EnvironmentName }

if ($ExistingEnvironment -and -not $ExistingEnvironment.subnet) {
    throw ("The environment '$EnvironmentName' was created without a virtual network, " +
        "which Neo4j needs. Run cleanup.ps1 once, then run this script again.")
}

# ---------- 2. Registry, log workspace, virtual network, Container Apps environment ----------
Write-Host "Deploying infrastructure..."
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $PSScriptRoot "infrastructure.bicep") `
    --parameters `
        location=$Location `
        acrName=$AcrName `
        environmentName=$EnvironmentName `
        workspaceName=$WorkspaceName `
        vnetName=$VnetName `
    --output none
Assert-LastCommand

# ---------- 3. Build the images with docker compose ----------
# "--profile tools" includes graph-loader, which "docker compose up" leaves out
Write-Host "Building images..."
docker compose -f (Join-Path $ProjectRoot "docker-compose.yml") --profile tools build
Assert-LastCommand

# ---------- 4. Push the images to the registry ----------
Write-Host "Pushing images..."
az acr login --name $AcrName
Assert-LastCommand

$LoginServer = az acr show --name $AcrName --query loginServer --output tsv
Assert-LastCommand

foreach ($Image in @($BackendImage, $FrontendImage, $GraphLoaderImage)) {
    docker tag $Image "${LoginServer}/${Image}:${Tag}"
    Assert-LastCommand
    docker push "${LoginServer}/${Image}:${Tag}"
    Assert-LastCommand
}

# Neo4j is not built locally: Azure copies the official image from Docker Hub
# straight into the registry
Write-Host "Importing $Neo4jImage into the registry..."
az acr import `
    --name $AcrName `
    --source "docker.io/library/$Neo4jImage" `
    --image $Neo4jImage `
    --force `
    --output none
Assert-LastCommand

# ---------- 5. Write the secrets to a temporary parameters file ----------
$ParamFile = Join-Path ([System.IO.Path]::GetTempPath()) "team1-env.json"
$ParamJson = @{
    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters     = @{
        backendEnv = @{ value = $BackendEnv }
        graphEnv   = @{ value = $GraphEnv }
    }
} | ConvertTo-Json -Depth 5

# UTF-8 without BOM, which the Azure CLI reads reliably
[System.IO.File]::WriteAllText($ParamFile, $ParamJson)

# ---------- 6. Identity, pull permission, the Container Apps and the loader job ----------
try {
    Write-Host "Deploying container apps..."
    $Url = az deployment group create `
        --resource-group $ResourceGroup `
        --template-file (Join-Path $PSScriptRoot "apps.bicep") `
        --parameters "@$ParamFile" `
        --parameters `
            location=$Location `
            acrName=$AcrName `
            environmentName=$EnvironmentName `
            appPrefix=$AppPrefix `
            backendImage="${BackendImage}:${Tag}" `
            frontendImage="${FrontendImage}:${Tag}" `
            graphLoaderImage="${GraphLoaderImage}:${Tag}" `
            neo4jImage=$Neo4jImage `
            goldSchema=$GoldSchema `
        --query "properties.outputs.url.value" `
        --output tsv
    Assert-LastCommand
}
finally {
    # The file holds your API keys and passwords, so never leave it lying around
    Remove-Item $ParamFile -ErrorAction SilentlyContinue
}

# ---------- 7. Fill the graph ----------
if (-not $SkipGraphLoad) {
    Write-Host "Starting the graph loader..."
    az containerapp job start `
        --name "$AppPrefix-graph-loader" `
        --resource-group $ResourceGroup `
        --output none
    Assert-LastCommand
}

Write-Host ""
Write-Host "Deployed! Open: $Url"
Write-Host ""
Write-Host "Neo4j (inside the environment): $Neo4jUri"
Write-Host "The graph loader runs every night, and once now unless -SkipGraphLoad was used."
Write-Host "Follow it in the Azure portal: $AppPrefix-graph-loader -> Execution history."
Write-Host "Run it again by hand with:"
Write-Host "  az containerapp job start --name $AppPrefix-graph-loader --resource-group $ResourceGroup"
