$ErrorActionPreference = "Stop"

$projectPath = Join-Path $PSScriptRoot "..\src\SteamOsWin.Shell\SteamOsWin.Shell.csproj"
$outputPath = Join-Path $PSScriptRoot "..\publish\win-x64"

dotnet publish $projectPath `
    --configuration Release `
    --runtime win-x64 `
    --self-contained true `
    --output $outputPath

Write-Host "Version publiée dans : $outputPath" -ForegroundColor Green
