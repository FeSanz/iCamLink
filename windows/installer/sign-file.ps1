param([Parameter(Mandatory)][string]$Path)

# Signing hook for Inno Setup ("iclsign" tool, see build-installer.ps1): signs one file with the
# iCamLink code-signing certificate, timestamped so the signature stays valid after the
# certificate itself expires. Fails loudly - an unsigned installer is worse than a failed build.
$ErrorActionPreference = "Stop"

$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -eq "CN=iCamLink Dev Signing" -and $_.HasPrivateKey } |
    Select-Object -First 1
if (-not $cert) { Write-Error "iCamLink Dev Signing certificate not found in Cert:\CurrentUser\My"; exit 1 }

$result = $null
try {
    $result = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert -HashAlgorithm SHA256 `
        -TimestampServer "http://timestamp.digicert.com"
} catch {
    Write-Warning "Timestamped signing failed ($($_.Exception.Message)); signing without timestamp."
}
if (-not $result -or -not $result.SignerCertificate) {
    $result = Set-AuthenticodeSignature -FilePath $Path -Certificate $cert -HashAlgorithm SHA256
}
# A self-signed certificate reports UnknownError until it is trusted on the machine, but the
# signature itself is still written - only a missing signature is a failure here.
if (-not $result.SignerCertificate) { Write-Error "Signing $Path failed: $($result.StatusMessage)"; exit 1 }
exit 0
