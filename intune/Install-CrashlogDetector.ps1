#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateRange(1, 365)][int]$LookbackDays = 30,
    [ValidateRange(0, 23)][int]$ScheduleHour = 10,
    [ValidateRange(1, 90)][int]$RetainReports = 14,
    [string]$DebuggerPath,
    [switch]$AllowSymbolDownload,
    [switch]$VerifyWindows
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Deployment.Common.psm1') -Force

$root = Join-Path $env:ProgramData 'CrashlogDetector'
$taskName = 'CrashlogDetector-Daily'
$mutex = New-Object Threading.Mutex($false, 'Global\CrashlogDetectorInstalledRun')
$acquired = $false
try {
    Assert-NativePowerShell
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'Diagnostik pågår. Vänta tills körningen är klar innan installationen uppdateras.' }
    $required = @(
        (Join-Path $PSScriptRoot '..\src\Invoke-CrashlogDiagnostics.ps1'),
        (Join-Path $PSScriptRoot '..\src\Crashlog.Diagnostics.psm1'),
        (Join-Path $PSScriptRoot 'Run-InstalledDiagnostics.ps1'),
        (Join-Path $PSScriptRoot 'Deployment.Common.psm1'),
        (Join-Path $PSScriptRoot 'Set-ReportingConfiguration.ps1')
    )
    foreach ($file in $required) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Paketfil saknas: $file" }
    }
    if ($DebuggerPath -and -not (Test-Path -LiteralPath $DebuggerPath -PathType Leaf)) {
        throw 'Angiven DebuggerPath finns inte.'
    }
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') {
        throw 'En diagnostikkörning pågår. Vänta tills den är klar innan installationen uppdateras.'
    }
    Protect-InstallationDirectory $root
    foreach ($directory in @('Agent', 'Reports', 'Symbols')) {
        [void][IO.Directory]::CreateDirectory((Join-Path $root $directory))
    }
    foreach ($file in $required) {
        Copy-Item -LiteralPath $file -Destination (Join-Path "$root\Agent" ([IO.Path]::GetFileName($file))) -Force
    }
    $settings = [ordered]@{
        LookbackDays = $LookbackDays
        RetainReports = $RetainReports
        DebuggerPath = $DebuggerPath
        AllowSymbolDownload = [bool]$AllowSymbolDownload
        VerifyWindows = [bool]$VerifyWindows
    }
    $settings | ConvertTo-Json | Set-Content -LiteralPath "$root\settings.json" -Encoding UTF8
    # Credential settings are deliberately preserved during an upgrade.
    $exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $action = New-ScheduledTaskAction -Execute $exe `
        -Argument "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File `"$root\Agent\Run-InstalledDiagnostics.ps1`""
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($ScheduleHour))
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $taskSettings -Description 'Read-only BSOD diagnostics; local reports and optional approved HTTPS reporting.' -Force | Out-Null
    '1.0.0' | Set-Content -LiteralPath "$root\version.txt" -Encoding ASCII
    $mutex.ReleaseMutex()
    $acquired = $false
    Start-ScheduledTask -TaskName $taskName
    Write-Output 'CrashlogDetector 1.0.0 installerad. Första insamlingen har startats; installation är inte ett diagnostikresultat.'
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
