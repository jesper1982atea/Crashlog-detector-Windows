#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { exit 1 }
    $root = Join-Path $env:ProgramData 'CrashlogDetector'
    foreach ($file in @('version.txt', 'settings.json', 'Agent\Invoke-CrashlogDiagnostics.ps1',
            'Agent\Crashlog.Diagnostics.psm1', 'Agent\Run-InstalledDiagnostics.ps1',
            'Agent\Deployment.Common.psm1', 'Agent\Set-ReportingConfiguration.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $file) -PathType Leaf)) { exit 1 }
    }
    if ((Get-Content -LiteralPath "$root\version.txt" -Raw).Trim() -ne '1.0.0') { exit 1 }
    $task = Get-ScheduledTask -TaskName 'CrashlogDetector-Daily' -ErrorAction Stop
    if ($task.State -eq 'Disabled' -or $task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) { exit 1 }
    $expectedExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (@($task.Actions).Count -ne 1 -or $task.Actions[0].Execute -ine $expectedExe -or
        $task.Actions[0].Arguments -notlike "*`"$root\Agent\Run-InstalledDiagnostics.ps1`"*") { exit 1 }
    Write-Output 'CrashlogDetector 1.0.0 installed'
    exit 0
}
catch {
    Write-Output "Detection failed: $($_.Exception.Message)"
    exit 1
}
