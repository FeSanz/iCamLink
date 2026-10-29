<#
  Publishes ICamLink.App as a self-contained win-x64 build into windows\publish\.
  Not single-file on purpose: libvlc ships as a folder of native DLLs/plugins that must sit
  next to the exe. Run publish\ICamLink.App.exe (or pin it) - nothing is installed system-wide.
#>

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outDir = Join-Path $scriptDir "publish"

dotnet publish (Join-Path $scriptDir "ICamLink.App\ICamLink.App.csproj") `
    -c Release -r win-x64 --self-contained true -o $outDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

Write-Host "Done: $(Join-Path $outDir 'ICamLink.App.exe')"
