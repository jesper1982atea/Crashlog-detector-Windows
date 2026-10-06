#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateRange(1, 365)][int]$LookbackDays = 30,
    [ValidateRange(100, 100000)][int]$MaxEvents = 2000,
    [ValidateRange(1, 50)][int]$MaxDumps = 10,
    [string]$OutputDirectory = "$env:ProgramData\CrashlogDetector\Reports\Latest",
    [string]$DebuggerPath,
    [string]$SymbolCache = "$env:ProgramData\CrashlogDetector\Symbols",
    [switch]$AllowSymbolDownload,
    [switch]$VerifyWindows,
    [uri]$ReportEndpoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Agenten kan endast köras på Windows.' }
Import-Module (Join-Path $PSScriptRoot 'Crashlog.Diagnostics.psm1') -Force

$mutex = New-Object Threading.Mutex($false, 'Global\CrashlogDetectorDiagnostics')
$acquired = $false
try {
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'En diagnostikkörning pågår redan.' }
    $installationRoot = Join-Path $env:ProgramData 'CrashlogDetector'
    $defaultReportsRoot = [IO.Path]::GetFullPath((Join-Path $installationRoot 'Reports')) + '\'
    $resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory) + '\'
    if ($resolvedOutput.StartsWith($defaultReportsRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $securityModule = Join-Path $PSScriptRoot 'Deployment.Common.psm1'
        if (-not (Test-Path -LiteralPath $securityModule)) {
            $securityModule = Join-Path $PSScriptRoot '..\intune\Deployment.Common.psm1'
        }
        Import-Module $securityModule -Force
        Protect-InstallationDirectory $installationRoot
    }
    $data = Get-DiagnosticData -LookbackDays $LookbackDays -MaxEvents $MaxEvents -MaxDumps $MaxDumps `
        -DebuggerPath $DebuggerPath -SymbolCache $SymbolCache -AllowSymbolDownload:$AllowSymbolDownload `
        -VerifyWindows:$VerifyWindows
    $status = if (@($data.CollectionErrors).Count -gt 0 -or
        ($null -ne $data.Events -and $data.Events.QueryLimitReached)) { 'Partial' } else { 'Complete' }
    $report = [pscustomobject]@{
        SchemaVersion = 1
        AgentVersion = '1.0.0'
        ReportId = [guid]::NewGuid().ToString()
        GeneratedUtc = [datetime]::UtcNow.ToString('o')
        LookbackDays = $LookbackDays
        Status = $status
        Findings = @(Get-DiagnosticFindings $data)
        Data = $data
        Upload = [pscustomobject]@{ Status = 'Disabled'; Error = $null }
    }
    Save-DiagnosticReport $report $OutputDirectory
    $exitCode = if ($status -eq 'Partial') { 2 } else { 0 }
    if ($ReportEndpoint) {
        try {
            Send-DiagnosticReport $report $ReportEndpoint
            $report.Upload.Status = 'Sent'
        }
        catch {
            $report.Upload.Status = 'Failed'
            # Do not persist HTTP bodies/URLs which may contain secrets.
            $report.Upload.Error = 'Central rapportering misslyckades. Kontrollera HTTPS-mottagare, token, identity salt och nätverksåtkomst.'
            Write-Warning $report.Upload.Error
            $exitCode = 3
        }
        Save-DiagnosticReport $report $OutputDirectory
    }
    Write-Output "Status=$status; Findings=$($report.Findings.Count); Report=$(Join-Path $OutputDirectory 'report.html'); Upload=$($report.Upload.Status)"
    exit $exitCode
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
