#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding(DefaultParameterSetName = 'Enable')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Enable')][uri]$ReportEndpoint,
    [Parameter(Mandatory, ParameterSetName = 'Disable')][switch]$Disable
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.Common.psm1') -Force
$root = Join-Path $env:ProgramData 'CrashlogDetector'
try {
    Assert-NativePowerShell
    if (-not (Test-Path -LiteralPath "$root\version.txt")) { throw 'Installera agenten innan rapportering konfigureras.' }
    $path = Join-Path $root 'reporting.json'
    if ($Disable) {
        Assert-NoReparsePoints $root
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        Write-Output 'Central rapportering avstängd för nästa körning.'
        exit 0
    }
    if ($ReportEndpoint.Scheme -ne 'https' -or $ReportEndpoint.UserInfo -or $ReportEndpoint.Fragment -or $ReportEndpoint.Query) {
        throw 'Använd en HTTPS-adress utan användaruppgifter, query-parametrar eller fragment.'
    }
    if ([string]::IsNullOrWhiteSpace($env:CRASHLOG_REPORT_TOKEN)) { throw 'CRASHLOG_REPORT_TOKEN saknas i processens miljö.' }
    if ([string]::IsNullOrWhiteSpace($env:CRASHLOG_IDENTITY_SALT) -or $env:CRASHLOG_IDENTITY_SALT.Length -lt 16) {
        throw 'CRASHLOG_IDENTITY_SALT måste ha minst 16 tecken. Använd samma slumpmässiga salt för kundens datorer.'
    }
    Protect-InstallationDirectory $root
    Add-Type -AssemblyName System.Security
    $json = @{ Token = $env:CRASHLOG_REPORT_TOKEN; IdentitySalt = $env:CRASHLOG_IDENTITY_SALT } | ConvertTo-Json -Compress
    $protected = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($json), $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    @{ Endpoint = $ReportEndpoint.AbsoluteUri; ProtectedCredentials = [Convert]::ToBase64String($protected) } |
        ConvertTo-Json | Set-Content -LiteralPath "$path.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
    Write-Output 'Central rapportering konfigurerad. DPAPI-krypterad konfiguration är endast åtkomlig för SYSTEM och administratörer.'
    exit 0
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
finally {
    Remove-Item Env:\CRASHLOG_REPORT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CRASHLOG_IDENTITY_SALT -ErrorAction SilentlyContinue
}
