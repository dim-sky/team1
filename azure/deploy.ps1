# Builds both images, pushes them to Azure Container Registry, and deploys
# the frontend and backend as Azure Container Apps.
#
# Run from anywhere, e.g. from the project folder:
#   .\azure\deploy.ps1 -ResourceGroup "rg-instructor-01" -Location "westeurope" -AcrName "team1acr12345"

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
    [string]$AppPrefix = "team1",

    # Local image names, as set by "image:" in docker-compose.yml
    [string]$BackendImage = "team1-backend",
    [string]$FrontendImage = "team1-frontend",

    # Path to the backend's .env file, relative to the project folder
    [string]$EnvFile = "team1_backend\.env"
)

$ErrorActionPreference = "Stop"

function Assert-LastCommand {
    if ($LASTEXITCODE -ne 0) {
        throw "The previous command failed with exit code $LASTEXITCODE"
    }
}

# This script lives in project\azure, so the project folder is one level up
$ProjectRoot = Split-Path $PSScriptRoot -Parent
$EnvFile = Join-Path $ProjectRoot $EnvFile

# A new tag on every deploy, so Azure always starts a new revision with the new image
$Tag = Get-Date -Format "yyyyMMddHHmmss"

# ---------- 1. Registry, log workspace, Container Apps environment ----------
Write-Host "Deploying infrastructure..."
az deployment group create `
    --resource-group $ResourceGroup `
    --template-file (Join-Path $PSScriptRoot "infrastructure.bicep") `
    --parameters `
        location=$Location `
        acrName=$AcrName `
        environmentName=$EnvironmentName `
        workspaceName=$WorkspaceName `
    --output none
Assert-LastCommand

# ---------- 2. Build both images with docker compose ----------
Write-Host "Building images..."
docker compose -f (Join-Path $ProjectRoot "docker-compose.yml") build
Assert-LastCommand

# ---------- 3. Push both images to the registry ----------
Write-Host "Pushing images..."
az acr login --name $AcrName
Assert-LastCommand

$LoginServer = az acr show --name $AcrName --query loginServer --output tsv
Assert-LastCommand

foreach ($Image in @($BackendImage, $FrontendImage)) {
    docker tag $Image "${LoginServer}/${Image}:${Tag}"
    Assert-LastCommand
    docker push "${LoginServer}/${Image}:${Tag}"
    Assert-LastCommand
}

# ---------- 4. Read the backend's .env into a temporary parameters file ----------
if (-not (Test-Path $EnvFile)) {
    throw "Could not find $EnvFile"
}

$BackendEnv = [ordered]@{}
foreach ($Line in Get-Content $EnvFile) {
    $Line = $Line.Trim()
    if ($Line -eq "" -or $Line.StartsWith("#")) { continue }

    $Parts = $Line -split "=", 2
    if ($Parts.Count -ne 2) { continue }

    $Key = $Parts[0].Trim()
    if ($Key.StartsWith("export ")) { $Key = $Key.Substring(7).Trim() }
    $Value = $Parts[1].Trim().Trim('"').Trim("'")

    if ($Value -ne "") { $BackendEnv[$Key] = $Value }
}

$ParamFile = Join-Path ([System.IO.Path]::GetTempPath()) "team1-backend-env.json"
$ParamJson = @{
    '$schema'      = "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#"
    contentVersion = "1.0.0.0"
    parameters     = @{ backendEnv = @{ value = $BackendEnv } }
} | ConvertTo-Json -Depth 5

# UTF-8 without BOM, which the Azure CLI reads reliably
[System.IO.File]::WriteAllText($ParamFile, $ParamJson)

# ---------- 5. Identity, pull permission, and the two Container Apps ----------
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
        --query "properties.outputs.url.value" `
        --output tsv
    Assert-LastCommand
}
finally {
    # The file holds your API key, so never leave it lying around
    Remove-Item $ParamFile -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Deployed! Open: $Url"