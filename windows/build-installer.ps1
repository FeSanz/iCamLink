<#
  Builds the distributable Windows installer: dist\iCamLink-Setup-<version>.exe

  Steps: publish the self-contained app into a clean staging folder -> drop debug-only files ->
  sign the app binaries -> compile installer\iCamLink.iss with Inno Setup (which signs the setup and
  uninstaller through installer\sign-file.ps1) -> copy the public certificate and the Android
  release APK (if built) next to the setup.
#>

$ErrorActionPreference = "Stop"
$windowsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $windowsDir
$csproj = Join-Path $windowsDir "ICamLink.App\ICamLink.App.csproj"
$outDir = Join-Path $repoRoot "dist"
$stagingDir = Join-Path $outDir "staging"
$certFile = Join-Path $outDir "iCamLink-Signing.cer"
$signScript = Join-Path $windowsDir "installer\sign-file.ps1"

$iscc = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found. Install it with: winget install JRSoftware.InnoSetup" }

$version = ([xml](Get-Content $csproj)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
if (-not $version) { $version = "1.0.0" }
Write-Host "iCamLink $version"

$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq "CN=iCamLink Dev Signing" -and $_.HasPrivateKey } | Select-Object -First 1
if (-not $cert) { throw "iCamLink Dev Signing certificate not found in Cert:\CurrentUser\My" }

New-Item -ItemType Directory -Force -Path $outDir | Out-Null
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }

Write-Host "Publishing (Release, self-contained)..."
dotnet publish $csproj -c Release -r win-x64 --self-contained true -o $stagingDir
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
Get-ChildItem $stagingDir -File | Where-Object { $_.Extension -eq ".pdb" } | Remove-Item -Force

Write-Host "Signing app binaries..."
foreach ($name in @("ICamLink.App.exe", "ICamLink.App.dll", "ICamLink.Core.dll")) {
    & $signScript -Path (Join-Path $stagingDir $name)
    if ($LASTEXITCODE -ne 0) { throw "Signing $name failed" }
}

Write-Host "Exporting public signing certificate..."
Export-Certificate -Cert $cert -FilePath $certFile -Type CERT | Out-Null

Write-Host "Compiling installer..."
$signCmd = "iclsign=powershell.exe -NoProfile -ExecutionPolicy Bypass -File `$q$signScript`$q -Path `$f"
& $iscc "/DAppVersion=$version" "/DStagingDir=$stagingDir" "/DOutputDir=$outDir" `
    "/DCertFile=$certFile" "/S$signCmd" (Join-Path $windowsDir "installer\iCamLink.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed" }

$apk = Join-Path $repoRoot "app\build\outputs\apk\release\app-release.apk"
if (Test-Path $apk) {
    Copy-Item $apk (Join-Path $outDir "iCamLink-Android-$version.apk") -Force
    Write-Host "Android APK copied next to the installer."
}

Remove-Item $stagingDir -Recurse -Force
$setup = Join-Path $outDir "iCamLink-Setup-$version.exe"
$sizeMb = [math]::Round((Get-Item $setup).Length / 1MB, 1)
Write-Host ""
Write-Host "Installer: $setup ($sizeMb MB)"
Write-Host "Signature: $((Get-AuthenticodeSignature $setup).Status)"
