#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module "$root/src/Crashlog.Diagnostics.psm1" -Force -DisableNameChecking
$script:passed = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) { throw "ASSERTION FAILED: $Message. Expected '$Expected', got '$Actual'." }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Test)
    & $Test
    $script:passed++
    Write-Output "PASS $Name"
}
function New-Data {
    [pscustomobject]@{
        System = $null
        Events = [pscustomobject]@{
            Crashes = @(); Hardware = @(); Storage = @(); UnexpectedShutdowns = @()
            DumpErrors = @(); QueryLimitReached = $false; RecordsRead = 0
        }
        Dumps = @(); DumpAnalysis = @(); Drivers = @(); ProblemDevices = @(); Disks = @()
        DumpConfiguration = $null; Updates = @(); WindowsIntegrity = @(); CollectionErrors = @()
    }
}
function New-TestEvent {
    param([int]$Id, [string]$Provider, [string]$Xml)
    $event = [pscustomobject]@{
        Id = $Id; ProviderName = $Provider; Xml = $Xml; TimeCreated = [datetime]'2026-01-01T12:00:00Z'
        RecordId = 42; Message = 'Localized message'
    }
    $event | Add-Member -MemberType ScriptMethod -Name ToXml -Value { $this.Xml }
    $event
}

Test-Case 'All PowerShell files parse' {
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        Assert-Equal @($parseErrors).Count 0 "Syntax: $($file.Name) $($parseErrors | Out-String)"
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        Assert-True ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) "UTF-8 BOM for Windows PowerShell 5.1: $($file.Name)"
    }
}
Test-Case 'Bugcheck normalization and rejection' {
    Assert-Equal (ConvertTo-BugcheckCode '0xD1') '0x000000D1' 'Hex code'
    Assert-Equal (ConvertTo-BugcheckCode '209' -Decimal) '0x000000D1' 'Event 41 decimal code'
    foreach ($bad in @('', '0', 'invalid', '-1', 'FFFFFFFFF')) {
        Assert-True ($null -eq (ConvertTo-BugcheckCode $bad)) "Invalid or zero code: $bad"
    }
}
Test-Case 'Localized WER XML and parameters' {
    $event = New-TestEvent 1001 'Microsoft-Windows-WER-SystemErrorReporting' `
        '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData><Data Name="param1">0x000000d1 (0x0000000000000001, 0x0000000000000002)</Data><Data Name="param2">C:\Windows\MEMORY.DMP</Data></EventData></Event>'
    $crash = ConvertTo-CrashEvent $event
    Assert-Equal $crash.BugcheckCode '0x000000D1' 'Structured code, not localized message'
    Assert-Equal $crash.Parameters.Count 2 'Bugcheck parameters'
}
Test-Case 'Kernel-Power zero is not a blue screen' {
    $event = New-TestEvent 41 'Microsoft-Windows-Kernel-Power' `
        '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData><Data Name="BugcheckCode">0</Data></EventData></Event>'
    Assert-True ($null -eq (ConvertTo-CrashEvent $event).BugcheckCode) 'Zero bugcheck'
    $event.Xml = '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData><Data Name="BugcheckCode">292</Data></EventData></Event>'
    Assert-Equal (ConvertTo-CrashEvent $event).BugcheckCode '0x00000124' 'Decimal bugcheck 292'
}
Test-Case 'Provider filtering rejects unrelated event IDs' {
    $records = @(
        (New-TestEvent 1001 'OtherApplication' '<Event><EventData><Data Name="param1">0xD1</Data></EventData></Event>'),
        (New-TestEvent 1001 'Microsoft-Windows-WER-SystemErrorReporting' '<Event><EventData><Data Name="param1">0xD1</Data></EventData></Event>'),
        (New-TestEvent 41 'Microsoft-Windows-Kernel-Power' '<Event><EventData><Data Name="BugcheckCode">0</Data></EventData></Event>'),
        (New-TestEvent 129 'storahci' '<Event><EventData /></Event>'),
        (New-TestEvent 129 'OtherApplication' '<Event><EventData /></Event>'),
        (New-TestEvent 18 'Microsoft-Windows-WHEA-Logger' '<Event><EventData /></Event>')
    )
    $module = Get-Module Crashlog.Diagnostics
    $events = & $module {
        param($Records)
        $script:TestRecords = $Records
        function script:Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) $script:TestRecords }
        try { Read-DiagnosticEvents ([datetime]'2025-01-01') 100 }
        finally { Remove-Item Function:\Get-WinEvent; Remove-Variable TestRecords -Scope Script }
    } $records
    Assert-Equal @($events.Crashes).Count 1 'Only WER bugcheck counted'
    Assert-Equal @($events.UnexpectedShutdowns).Count 1 '41 without code separated'
    Assert-Equal @($events.Storage).Count 1 'Storage provider required'
    Assert-Equal @($events.Hardware).Count 1 'WHEA provider required'
}
Test-Case 'Empty logs succeed but access failures propagate' {
    $module = Get-Module Crashlog.Diagnostics
    & $module {
        function script:Get-WinEvent {
            param($FilterHashtable, $MaxEvents, $ErrorAction)
            $record = New-Object Management.Automation.ErrorRecord(
                (New-Object Exception('No matching events')), 'NoMatchingEventsFound',
                [Management.Automation.ErrorCategory]::ObjectNotFound, $null)
            throw $record
        }
        try {
            $result = Read-DiagnosticEvents ([datetime]'2025-01-01') 100
            if (@($result.Crashes).Count -ne 0) { throw 'Expected empty event collection' }
        }
        finally { Remove-Item Function:\Get-WinEvent }
        function script:Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) throw 'Access denied' }
        $threw = $false
        try { Read-DiagnosticEvents ([datetime]'2025-01-01') 100 | Out-Null }
        catch { $threw = $_.Exception.Message -eq 'Access denied' }
        finally { Remove-Item Function:\Get-WinEvent }
        if (-not $threw) { throw 'Access failures must not look like healthy logs' }
    }
}
Test-Case 'Unexpected shutdown never invents a bugcheck finding' {
    $data = New-Data
    $data.Events.UnexpectedShutdowns = @([pscustomobject]@{ EventId = 41 })
    $findings = @(Get-DiagnosticFindings $data)
    Assert-True (@($findings | Where-Object Id -eq 'unexpected-shutdown').Count -eq 1) 'Shutdown guidance'
    Assert-Equal @($findings | Where-Object Id -like 'bugcheck-*').Count 0 'No invented stopcode'
}
Test-Case 'Storage correlation is measured within fifteen minutes' {
    $data = New-Data
    $data.Events.Crashes = @([pscustomobject]@{ BugcheckCode = '0x0000007A'; TimeUtc = '2026-01-01T12:00:00Z' })
    $data.Events.Storage = @(
        [pscustomobject]@{ TimeUtc = '2026-01-01T11:45:00Z' },
        [pscustomobject]@{ TimeUtc = '2026-01-01T11:44:59Z' },
        [pscustomobject]@{ TimeUtc = '2026-01-01T12:15:00Z' }
    )
    $finding = Get-DiagnosticFindings $data | Where-Object Id -eq 'storage-events'
    Assert-True ($finding.Evidence[0] -match '2 inom 15 minuter') 'Boundary included; outside excluded'
}
Test-Case 'Memory stopcode does not assert driver root cause' {
    $data = New-Data
    $data.Events.Crashes = @([pscustomobject]@{ BugcheckCode = '0x000000D1'; TimeUtc = '2026-01-01T12:00:00Z' })
    $findings = @(Get-DiagnosticFindings $data)
    $finding = $findings | Where-Object Id -eq 'bugcheck-0x000000D1'
    Assert-True (($finding.Actions -join ' ') -match 'både drivrutin och RAM') 'Competing hypotheses'
    Assert-True (@($findings | Where-Object Id -eq 'missing-dumps').Count -eq 1) 'Missing dump guidance'
}
Test-Case 'Corrected WHEA is not fatal WHEA' {
    $data = New-Data
    $data.Events.Hardware = @([pscustomobject]@{ EventId = 19 })
    $findings = @(Get-DiagnosticFindings $data)
    Assert-Equal @($findings | Where-Object Id -eq 'whea-fatal').Count 0 'Corrected events'
    Assert-Equal @($findings | Where-Object Id -eq 'whea-corrected').Count 1 'Separate corrected finding'
    $data.Events.Hardware += [pscustomobject]@{ EventId = 18 }
    Assert-Equal @(Get-DiagnosticFindings $data | Where-Object Id -eq 'whea-fatal').Count 1 'Fatal event'
}
Test-Case 'Debugger parser and repeated module evidence' {
    $parsed = ConvertFrom-DebuggerOutput "MODULE_NAME: vendor`nIMAGE_NAME: vendor.sys`nFAILURE_BUCKET_ID: AV_vendor`nBUGCHECK_CODE: d1"
    Assert-Equal $parsed.BugcheckCode '0x000000D1' 'Debugger hex normalization'
    Assert-Equal $parsed.Image 'vendor.sys' 'Image extraction'
    $data = New-Data
    $data.DumpAnalysis = @(
        [pscustomobject]@{ Image = 'vendor.sys'; Module = 'vendor'; Path = 'a.dmp'; Bucket = 'AV_vendor'; BugcheckCode = '0x000000D1'; SymbolWarning = $false },
        [pscustomobject]@{ Image = 'VENDOR.SYS'; Module = 'vendor'; Path = 'b.dmp'; Bucket = 'AV_vendor'; BugcheckCode = '0x000000D1'; SymbolWarning = $false },
        [pscustomobject]@{ Image = 'ntoskrnl.exe'; Module = 'nt'; Path = 'c.dmp'; Bucket = 'AV_nt'; BugcheckCode = '0x000000D1'; SymbolWarning = $false },
        [pscustomobject]@{ Image = 'wdf01000.sys'; Module = 'wdf'; Path = 'd.dmp'; Bucket = 'AV_wdf'; BugcheckCode = '0x000000D1'; SymbolWarning = $false },
        [pscustomobject]@{ Image = 'other.sys'; Module = 'other'; Path = 'e.dmp'; Bucket = 'AV_other'; BugcheckCode = '0x000000D1'; SymbolWarning = $true }
    )
    $findings = @(Get-DiagnosticFindings $data)
    $moduleFindings = @($findings | Where-Object Id -like 'module-*')
    Assert-Equal $moduleFindings.Count 1 'Ignore generic modules and missing symbols'
    Assert-Equal $moduleFindings[0].Confidence 'Medium' 'Repeated evidence remains a hypothesis'
    Assert-Equal $moduleFindings[0].Evidence.Count 2 'Distinct dumps'
    Assert-Equal @($findings | Where-Object Id -eq 'symbols-incomplete').Count 1 'Symbol warning surfaced'
}
Test-Case 'Collector failure is visible and does not claim healthy Windows' {
    $module = Get-Module Crashlog.Diagnostics
    $errors = New-Object 'System.Collections.Generic.List[object]'
    $result = & $module {
        param($Errors)
        Invoke-Collector 'Events' { throw 'Access denied' } $Errors -WarningAction SilentlyContinue
    } $errors
    Assert-True ($null -eq $result) 'No success-shaped fallback'
    Assert-Equal $errors.Count 1 'Error recorded'
    $data = New-Data
    $data.Events = $null
    $data.CollectionErrors = @($errors.ToArray())
    $findings = @(Get-DiagnosticFindings $data)
    Assert-Equal @($findings | Where-Object Id -eq 'collection-Events').Count 1 'Failure finding'
    Assert-Equal @($findings | Where-Object Id -eq 'no-bugchecks').Count 0 'Missing is not empty'
}
Test-Case 'Event truncation and disabled dumps are explicit' {
    $data = New-Data
    $data.Events.QueryLimitReached = $true
    $data.Events.RecordsRead = 100
    $data.DumpConfiguration = [pscustomobject]@{ CrashDumpEnabled = 0 }
    $findings = @(Get-DiagnosticFindings $data)
    Assert-Equal @($findings | Where-Object Id -eq 'event-limit').Count 1 'Truncation'
    Assert-Equal @($findings | Where-Object Id -eq 'dumps-disabled').Count 1 'Disabled dump'
}
Test-Case 'Complete collection fixture exercises the data contract' {
    $module = Get-Module Crashlog.Diagnostics
    $data = & $module {
        $originalDumpInventory = (Get-Item Function:\Get-DumpInventory).ScriptBlock
        function script:Get-DumpInventory { param($Since, $Limit) }
        function script:Get-WinEvent { param($FilterHashtable, $MaxEvents, $ErrorAction) }
        function script:Get-ItemProperty {
            param($Path)
            [pscustomobject]@{ CrashDumpEnabled = 7; AutoReboot = 1 }
        }
        function script:Get-CimInstance {
            param($ClassName, $Filter)
            switch ($ClassName) {
                'Win32_OperatingSystem' {
                    [pscustomobject]@{ Caption = 'Windows'; Version = '10.0'; BuildNumber = '26100'; LastBootUpTime = [datetime]'2026-01-01' }
                }
                'Win32_ComputerSystem' {
                    [pscustomobject]@{ Manufacturer = 'OEM'; Model = 'Model'; TotalPhysicalMemory = 16GB; AutomaticManagedPagefile = $true }
                }
                'Win32_BIOS' { [pscustomobject]@{ SMBIOSBIOSVersion = '1.0'; ReleaseDate = [datetime]'2025-01-01' } }
                'Win32_PnPSignedDriver' {
                    [pscustomobject]@{
                        DeviceName = 'Network'; DeviceID = 'PCI\TEST'; DriverProviderName = 'OEM'
                        DriverVersion = '1.2'; DriverDate = [datetime]'2025-01-01'; InfName = 'oem1.inf'
                        IsSigned = $true; DriverName = 'network.sys'
                    }
                }
                'Win32_QuickFixEngineering' { [pscustomobject]@{ HotFixID = 'KB123'; Description = 'Update'; InstalledOn = [datetime]'2025-01-01' } }
                'Win32_PageFileUsage' { [pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = 4096; CurrentUsage = 128 } }
                'Win32_LogicalDisk' { [pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 50GB } }
                'Win32_PnPEntity' { }
                default { throw "Unexpected CIM class: $ClassName" }
            }
        }
        try { Get-DiagnosticData -SymbolCache 'unused' }
        finally {
            Set-Item Function:\Get-DumpInventory $originalDumpInventory
            Remove-Item Function:\Get-CimInstance, Function:\Get-ItemProperty, Function:\Get-WinEvent
        }
    }
    Assert-Equal $data.CollectionErrors.Count 0 'All collectors compatible with fixture'
    Assert-Equal $data.System.BIOSVersion '1.0' 'BIOS inventory'
    Assert-Equal $data.Drivers.Count 1 'Driver inventory shape'
    Assert-Equal $data.DumpConfiguration.Pagefiles.Count 1 'Pagefile inventory'
    Assert-Equal $data.Events.Crashes.Count 0 'Empty logs'
    Assert-Equal @(Get-DiagnosticFindings $data | Where-Object Id -eq 'no-bugchecks').Count 1 'No false fault'
}
Test-Case 'Free space threshold and unknown disk size' {
    $data = New-Data
    $data.Disks = @(
        [pscustomobject]@{ DeviceID = 'C:'; Size = 100GB; FreeSpace = 9GB },
        [pscustomobject]@{ DeviceID = 'D:'; Size = 100GB; FreeSpace = 10GB },
        [pscustomobject]@{ DeviceID = 'E:'; Size = $null; FreeSpace = $null }
    )
    $findings = @(Get-DiagnosticFindings $data | Where-Object Id -like 'disk-space-*')
    Assert-Equal $findings.Count 1 'Strictly below 10 percent only'
    Assert-Equal $findings[0].Id 'disk-space-C:' 'Correct drive'
}
Test-Case 'Report HTML escapes untrusted event and driver text' {
    $data = New-Data
    $data.System = [pscustomobject]@{ ComputerName = '<script>alert(1)</script>' }
    $report = [pscustomobject]@{
        AgentVersion = '1.0.0'; GeneratedUtc = '2026-01-01T12:00:00Z'; Status = 'Partial'; LookbackDays = 30
        Upload = [pscustomobject]@{ Status = 'Failed'; Error = '<b>error</b>' }
        Findings = @([pscustomobject]@{
                Severity = '"><script>'; Confidence = 'Low'; Title = '<img src=x onerror=alert(1)>'
                Evidence = @('<script>bad</script>'); Actions = @('A&B')
            })
        Data = $data
    }
    $html = ConvertTo-DiagnosticHtml $report
    Assert-True (-not $html.Contains('<script>')) 'No raw script markup'
    Assert-True ($html.Contains('&lt;img')) 'Finding escaped'
    Assert-True ($html.Contains('A&amp;B')) 'Action escaped'
    Assert-True ($html.Contains('&lt;b&gt;error')) 'Upload error escaped'
    Assert-True ($html.Contains('Content-Security-Policy')) 'Offline report CSP'
    $directory = Join-Path ([IO.Path]::GetTempPath()) ("crashlog-tests-" + [guid]::NewGuid())
    try {
        Save-DiagnosticReport $report $directory
        $saved = Get-Content -LiteralPath "$directory/report.json" -Raw | ConvertFrom-Json
        Assert-Equal $saved.Status 'Partial' 'JSON roundtrip'
        Assert-True (Test-Path -LiteralPath "$directory/report.html") 'HTML persisted'
        Assert-Equal @(Get-ChildItem -LiteralPath $directory -Filter '*.tmp').Count 0 'No temporary artifacts'
    }
    finally {
        if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
}
Test-Case 'Upload payload excludes names, paths and raw messages' {
    $data = New-Data
    $data.System = [pscustomobject]@{
        ComputerName = 'PRIVATE-PC'; Manufacturer = 'OEM'; Model = 'Model1'
        Version = '10.0'; Build = '26100'; BIOSVersion = '1.2'
    }
    $data.Events.Crashes = @([pscustomobject]@{
            TimeUtc = '2026-01-01T12:00:00Z'; EventId = 1001; BugcheckCode = '0x000000D1'; Message = 'PRIVATE-MESSAGE'
        })
    $data.DumpAnalysis = @([pscustomobject]@{
            Path = 'PRIVATE-PATH'; ModifiedUtc = '2026-01-01T12:00:00Z'; Module = 'vendor'
            Image = 'vendor.sys'; Bucket = 'AV_vendor'; BugcheckCode = '0x000000D1'; SymbolWarning = $false
        })
    $data.Drivers = @([pscustomobject]@{
            DeviceID = 'PRIVATE-ID'; DeviceName = 'PRIVATE-NAME'; DriverProviderName = 'OEM'
            DriverVersion = '1.2'; DriverDate = '2025-01-01'; InfName = 'oem1.inf'; IsSigned = $true
        })
    $report = [pscustomobject]@{
        SchemaVersion = 1; ReportId = 'test'; AgentVersion = '1.0.0'; GeneratedUtc = '2026-01-01T12:00:00Z'
        LookbackDays = 30; Status = 'Complete'; Data = $data; Findings = @(Get-DiagnosticFindings $data)
    }
    $module = Get-Module Crashlog.Diagnostics
    $payload = & $module {
        param($Report)
        function script:Get-ItemProperty { param($Path) [pscustomobject]@{ MachineGuid = 'test-machine-id' } }
        try { New-UploadPayload $Report 'test-customer-salt-123456' }
        finally { Remove-Item Function:\Get-ItemProperty }
    } $report
    $json = $payload | ConvertTo-Json -Depth 12
    Assert-True (-not $json.Contains('PRIVATE-')) 'Local identifiers excluded'
    Assert-True (-not $json.Contains('test-machine-id')) 'Machine GUID hashed'
    Assert-True ($payload.DeviceId -match '^[a-f0-9]{64}$') 'Pseudonymous stable device ID'
    Assert-Equal $payload.DriverVersions[0].DriverVersion '1.2' 'Fleet version comparison'
}
Test-Case 'Unsafe upload endpoints rejected before network access' {
    foreach ($uri in @('http://example.invalid', 'https://user:pass@example.invalid', 'https://example.invalid/?token=x', 'https://example.invalid/#x')) {
        $rejected = $false
        try { Send-DiagnosticReport -Report $null -Endpoint $uri }
        catch { $rejected = $_.Exception.Message -like 'ReportEndpoint måste*' }
        Assert-True $rejected "Reject unsafe endpoint: $uri"
    }
}
Test-Case 'Process runner captures exit and enforces timeout' {
    $executable = (Get-Process -Id $PID).Path
    $result = Invoke-BoundedProcess -FilePath $executable `
        -Arguments '-NoProfile -NonInteractive -Command "Write-Output bounded-test; exit 7"' -TimeoutSeconds 20
    Assert-Equal $result.ExitCode 7 'Nonzero captured'
    Assert-True ($result.Output -match 'bounded-test') 'Stdout captured'
    $timeout = $false
    try {
        Invoke-BoundedProcess -FilePath $executable -Arguments '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"' `
            -TimeoutSeconds 1 | Out-Null
    }
    catch { $timeout = $_.Exception.Message -like 'Timeout efter*' }
    Assert-True $timeout 'Timeout throws and kills only owned process'
}

Write-Output "$script:passed tests passed."
