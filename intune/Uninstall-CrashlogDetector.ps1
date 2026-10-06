#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$RemoveReports)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.Common.psm1') -Force
$root = Join-Path $env:ProgramData 'CrashlogDetector'
$mutex = New-Object Threading.Mutex($false, 'Global\CrashlogDetectorInstalledRun')
$acquired = $false
try {
    Assert-NativePowerShell
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Diagnostik pågår. Vänta tills körningen är klar innan avinstallation.' }
    $task = Get-ScheduledTask -TaskName 'CrashlogDetector-Daily' -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName 'CrashlogDetector-Daily' -Confirm:$false }
    if (Test-Path -LiteralPath $root) {
        Assert-NoReparsePoints $root
        foreach ($name in @('Agent', 'Symbols', 'settings.json', 'reporting.json', 'version.txt', 'last-run.json')) {
            $path = Join-Path $root $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        if ($RemoveReports) {
            $reports = Join-Path $root 'Reports'
            if (Test-Path -LiteralPath $reports) { Remove-Item -LiteralPath $reports -Recurse -Force }
        }
    }
    Write-Output "Agent och rapporteringsuppgifter borttagna. RemoveReports=$([bool]$RemoveReports)."
    exit 0
}
catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
finally {
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
