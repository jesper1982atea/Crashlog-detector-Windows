#Requires -Version 5.1
#Requires -RunAsAdministrator
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'Deployment.Common.psm1') -Force
$mutex = New-Object Threading.Mutex($false, 'Global\CrashlogDetectorInstalledRun')
$acquired = $false
$started = [datetime]::UtcNow
$stateWritable = $false
$stage = 'Initialization'
$result = $null
try {
    Assert-NativePowerShell
    try { $acquired = $mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $acquired = $true }
    if (-not $acquired) { throw 'En installerad diagnostikkörning pågår redan.' }
    Assert-NoReparsePoints $root
    $stateWritable = $true
    $stage = 'Settings'
    @{ StartedUtc = $started.ToString('o'); Status = 'Running'; Stage = $stage } |
        ConvertTo-Json | Set-Content -LiteralPath "$root\last-run.json" -Encoding UTF8
    $settings = Get-Content -LiteralPath "$root\settings.json" -Raw | ConvertFrom-Json
    if ([int]$settings.RetainReports -lt 1 -or [int]$settings.RetainReports -gt 90) {
        throw 'RetainReports måste vara 1-90.'
    }
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'RemoteSigned', '-File',
        "$PSScriptRoot\Invoke-CrashlogDiagnostics.ps1", '-LookbackDays', [string]$settings.LookbackDays,
        '-OutputDirectory', "$root\Reports\Latest", '-SymbolCache', "$root\Symbols"
    )
    if ($settings.DebuggerPath) { $arguments += @('-DebuggerPath', [string]$settings.DebuggerPath) }
    if ($settings.AllowSymbolDownload) { $arguments += '-AllowSymbolDownload' }
    if ($settings.VerifyWindows) { $arguments += '-VerifyWindows' }
    $reportingPath = Join-Path $root 'reporting.json'
    if (Test-Path -LiteralPath $reportingPath) {
        $stage = 'ReportingCredentials'
        Add-Type -AssemblyName System.Security
        $reporting = Get-Content -LiteralPath $reportingPath -Raw | ConvertFrom-Json
        $bytes = [Convert]::FromBase64String($reporting.ProtectedCredentials)
        $plaintext = [Security.Cryptography.ProtectedData]::Unprotect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $credentials = [Text.Encoding]::UTF8.GetString($plaintext) | ConvertFrom-Json
        $env:CRASHLOG_REPORT_TOKEN = $credentials.Token
        $env:CRASHLOG_IDENTITY_SALT = $credentials.IdentitySalt
        $arguments += @('-ReportEndpoint', [string]$reporting.Endpoint)
    }
    else {
        # Installed runs report only when explicitly configured, not via inherited environment.
        Remove-Item Env:\CRASHLOG_REPORT_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:\CRASHLOG_IDENTITY_SALT -ErrorAction SilentlyContinue
    }
    $stage = 'Agent'
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" @arguments
    $result = $LASTEXITCODE
    if ($result -notin @(0, 2, 3)) { throw "Agenten misslyckades, exitkod $result. Tidigare rapport arkiveras inte som en ny körning." }
    $jsonPath = Join-Path $root 'Reports\Latest\report.json'
    $report = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    if ([datetimeoffset]::Parse($report.GeneratedUtc).UtcDateTime -lt $started) {
        throw 'Agenten producerade ingen ny rapport.'
    }
    $stage = 'Archive'
    $archiveName = '{0}-{1}' -f $started.ToString('yyyyMMddTHHmmssZ'), $report.ReportId
    $archivePath = Join-Path "$root\Reports" $archiveName
    [void][IO.Directory]::CreateDirectory($archivePath)
    Copy-Item -LiteralPath "$root\Reports\Latest\report.json", "$root\Reports\Latest\report.html" -Destination $archivePath
    $archives = @(Get-ChildItem -LiteralPath "$root\Reports" -Directory |
        Where-Object { $_.Name -match '^\d{8}T\d{6}Z-[0-9a-f-]{36}$' } | Sort-Object Name -Descending)
    foreach ($old in @($archives | Select-Object -Skip ([int]$settings.RetainReports))) {
        Assert-NoReparsePoints $old.FullName
        Remove-Item -LiteralPath $old.FullName -Recurse -Force
    }
    @{ StartedUtc = $started.ToString('o'); FinishedUtc = [datetime]::UtcNow.ToString('o')
        Status = $report.Status; Upload = $report.Upload.Status; ExitCode = $result; ReportId = $report.ReportId } |
        ConvertTo-Json | Set-Content -LiteralPath "$root\last-run.json" -Encoding UTF8
    exit $result
}
catch {
    $failure = $_
    if ($stateWritable) {
        try {
            @{ StartedUtc = $started.ToString('o'); FinishedUtc = [datetime]::UtcNow.ToString('o')
                Status = 'Failed'; Stage = $stage; ExitCode = 1; AgentExitCode = $result
                ErrorCategory = [string]$failure.CategoryInfo.Category } |
                ConvertTo-Json | Set-Content -LiteralPath "$root\last-run.json" -Encoding UTF8
        }
        catch { Write-Warning 'Kunde inte spara last-run.json. Kontrollera katalogbehörigheter och ledigt utrymme.' }
    }
    Write-Error $failure -ErrorAction Continue
    exit 1
}
finally {
    Remove-Item Env:\CRASHLOG_REPORT_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\CRASHLOG_IDENTITY_SALT -ErrorAction SilentlyContinue
    if ($acquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
