Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EventFields {
    param([Parameter(Mandatory)]$Event)
    [xml]$xml = $Event.ToXml()
    $fields = @{}
    foreach ($node in $xml.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")) {
        $name = $node.GetAttribute('Name')
        if (-not $name) { $name = "param$($fields.Count + 1)" }
        $fields[$name] = $node.InnerText
    }
    return $fields
}

function ConvertTo-BugcheckCode {
    param([AllowNull()][string]$Value, [switch]$Decimal)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $text = $Value.Trim()
    try {
        if ($Decimal) { $number = [Convert]::ToUInt32($text, 10) }
        else { $number = [Convert]::ToUInt32(($text -replace '^0x', ''), 16) }
        if ($number -eq 0) { return $null }
        return ('0x{0:X8}' -f $number)
    }
    catch { return $null }
}

function ConvertTo-CrashEvent {
    param([Parameter(Mandatory)]$Event)
    $fields = Get-EventFields $Event
    $code = $null
    $parameters = @()
    if ($Event.Id -eq 41) {
        $code = ConvertTo-BugcheckCode -Value $fields['BugcheckCode'] -Decimal
    }
    elseif ($Event.Id -eq 1001) {
        # WER event parameters are stable across localized Windows messages.
        if ([string]$fields['param1'] -match '(?i)\b(0x[0-9a-f]+)\b') {
            $code = ConvertTo-BugcheckCode $Matches[1]
            $parameters = @([regex]::Matches([string]$fields['param1'], '(?i)0x[0-9a-f]+') |
                ForEach-Object { $_.Value } | Select-Object -Skip 1)
        }
    }
    [pscustomobject]@{
        TimeUtc = $Event.TimeCreated.ToUniversalTime().ToString('o')
        EventId = $Event.Id
        RecordId = $Event.RecordId
        Provider = $Event.ProviderName
        BugcheckCode = $code
        Parameters = $parameters
        Fields = $fields
        Message = $Event.Message
    }
}

function Read-DiagnosticEvents {
    param([datetime]$Since, [int]$Limit)
    # Read one bounded query; do not mistake unrelated event 1001 records for BSODs.
    $filter = @{
        LogName = 'System'
        StartTime = $Since
        Id = @(41, 1001, 18, 19, 17, 46, 7, 51, 55, 129, 153, 6008, 161)
    }
    $records = @()
    try { $records = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Limit -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw }
    }
    $crashes = @()
    $hardware = @()
    $storage = @()
    $unexpected = @()
    $dumpErrors = @()
    foreach ($event in $records) {
        if (($event.Id -eq 1001 -and $event.ProviderName -in @(
                    'Microsoft-Windows-WER-SystemErrorReporting', 'BugCheck')) -or
            ($event.Id -eq 41 -and $event.ProviderName -eq 'Microsoft-Windows-Kernel-Power')) {
            $record = ConvertTo-CrashEvent $event
            if ($record.BugcheckCode) { $crashes += $record }
            else { $unexpected += $record }
        }
        elseif ($event.ProviderName -eq 'Microsoft-Windows-WHEA-Logger') {
            $hardware += ConvertTo-CrashEvent $event
        }
        elseif ($event.Id -in @(7, 51, 55, 129, 153) -and
            $event.ProviderName -match '(?i)^(disk|ntfs|Microsoft-Windows-Ntfs|storahci|stornvme|storport|Microsoft-Windows-StorPort|iaStor.*)$') {
            $storage += ConvertTo-CrashEvent $event
        }
        elseif ($event.Id -eq 6008 -and $event.ProviderName -eq 'EventLog') {
            $unexpected += ConvertTo-CrashEvent $event
        }
        elseif ($event.Id -eq 161 -and $event.ProviderName -eq 'volmgr') {
            $dumpErrors += ConvertTo-CrashEvent $event
        }
    }
    [pscustomobject]@{
        Crashes = $crashes
        Hardware = $hardware
        Storage = $storage
        UnexpectedShutdowns = $unexpected
        DumpErrors = $dumpErrors
        QueryLimitReached = ($records.Count -ge $Limit)
        RecordsRead = $records.Count
    }
}

function Get-DumpInventory {
    param([datetime]$Since, [int]$Limit)
    $files = @()
    $miniPath = Join-Path $env:SystemRoot 'Minidump'
    if (Test-Path -LiteralPath $miniPath) {
        $files += @(Get-ChildItem -LiteralPath $miniPath -Filter '*.dmp' -File -ErrorAction Stop)
    }
    $memoryPath = Join-Path $env:SystemRoot 'MEMORY.DMP'
    if (Test-Path -LiteralPath $memoryPath) { $files += Get-Item -LiteralPath $memoryPath }
    $crashControl = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
    foreach ($property in @('DumpFile', 'MinidumpDir')) {
        if ($crashControl.PSObject.Properties.Name -contains $property) {
            $path = [Environment]::ExpandEnvironmentVariables([string]$crashControl.$property)
            if ($path -and (Test-Path -LiteralPath $path)) {
                $item = Get-Item -LiteralPath $path
                if ($item.PSIsContainer) {
                    $files += @(Get-ChildItem -LiteralPath $path -Filter '*.dmp' -File)
                }
                else { $files += $item }
            }
        }
    }
    @($files | Sort-Object FullName -Unique | Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending | Select-Object -First $Limit |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName
                SizeBytes = $_.Length
                ModifiedUtc = $_.LastWriteTimeUtc.ToString('o')
            }
        })
}

function Invoke-BoundedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Arguments,
        [int]$TimeoutSeconds = 120
    )
    $process = New-Object Diagnostics.Process
    try {
        $process.StartInfo.FileName = $FilePath
        $process.StartInfo.Arguments = $Arguments
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.CreateNoWindow = $true
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Timeout efter $TimeoutSeconds sekunder: $FilePath"
        }
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdout.GetAwaiter().GetResult()
            ErrorOutput = $stderr.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function ConvertFrom-DebuggerOutput {
    param([string]$Text)
    $result = [ordered]@{ Module = $null; Image = $null; Bucket = $null; BugcheckCode = $null }
    foreach ($field in @(
            @('Module', 'MODULE_NAME'), @('Image', 'IMAGE_NAME'),
            @('Bucket', 'FAILURE_BUCKET_ID'), @('BugcheckCode', 'BUGCHECK_CODE'))) {
        $match = [regex]::Match($Text, "(?im)^\s*$($field[1]):\s*(\S+)")
        if ($match.Success) { $result[$field[0]] = $match.Groups[1].Value }
    }
    if ($result.BugcheckCode) { $result.BugcheckCode = ConvertTo-BugcheckCode $result.BugcheckCode }
    [pscustomobject]$result
}

function Get-DumpAnalysis {
    param($Dumps, [string]$DebuggerPath, [string]$SymbolCache, [switch]$AllowSymbolDownload)
    if (-not $DebuggerPath) { return @() }
    if (-not (Test-Path -LiteralPath $DebuggerPath -PathType Leaf) -or
        [IO.Path]::GetFileName($DebuggerPath) -ine 'cdb.exe') {
        throw 'DebuggerPath måste peka på en befintlig cdb.exe från Windows Debugging Tools.'
    }
    if ($DebuggerPath.Contains('"') -or $SymbolCache.Contains('"')) { throw 'Ogiltigt citattecken i debugger-/symbol-sökväg.' }
    $symbols = $SymbolCache
    if ($AllowSymbolDownload) { $symbols = "srv*$SymbolCache*https://msdl.microsoft.com/download/symbols" }
    foreach ($dump in $Dumps) {
        if ($dump.Path.Contains('"')) { throw 'Ogiltigt citattecken i dump-sökväg.' }
        $result = Invoke-BoundedProcess -FilePath $DebuggerPath `
            -Arguments "-z `"$($dump.Path)`" -y `"$symbols`" -c `".reload; !analyze -v; q`"" -TimeoutSeconds 180
        if ($result.ExitCode -ne 0) {
            throw "cdb misslyckades för $($dump.Path), exitkod $($result.ExitCode): $($result.ErrorOutput)"
        }
        $parsed = ConvertFrom-DebuggerOutput $result.Output
        if (-not $parsed.BugcheckCode) {
            throw "cdb gav ingen läsbar bugcheck för $($dump.Path). Kontrollera dumpformat och symboler."
        }
        [pscustomobject]@{
            Path = $dump.Path
            ModifiedUtc = $dump.ModifiedUtc
            Module = $parsed.Module
            Image = $parsed.Image
            Bucket = $parsed.Bucket
            BugcheckCode = $parsed.BugcheckCode
            SymbolDownloadAllowed = [bool]$AllowSymbolDownload
            SymbolWarning = ($result.Output -match '(?i)symbols could not be loaded|wrong symbols|symbol.*error|unable to verify')
        }
    }
}

function Invoke-Collector {
    param([string]$Name, [scriptblock]$Action, [System.Collections.Generic.List[object]]$Errors)
    try { & $Action }
    catch {
        $Errors.Add([pscustomobject]@{ Collector = $Name; Message = $_.Exception.Message })
        Write-Warning "$Name : $($_.Exception.Message)"
    }
}

function Get-DiagnosticData {
    param(
        [int]$LookbackDays = 30, [int]$MaxEvents = 2000, [int]$MaxDumps = 10,
        [string]$DebuggerPath, [string]$SymbolCache, [switch]$AllowSymbolDownload,
        [switch]$VerifyWindows
    )
    $errors = New-Object 'System.Collections.Generic.List[object]'
    $since = (Get-Date).AddDays(-$LookbackDays)
    $system = Invoke-Collector 'System' {
        $os = Get-CimInstance Win32_OperatingSystem
        $computer = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            Manufacturer = $computer.Manufacturer
            Model = $computer.Model
            OS = $os.Caption
            Version = $os.Version
            Build = $os.BuildNumber
            LastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
            BIOSVersion = $bios.SMBIOSBIOSVersion
            BIOSDate = if ($bios.ReleaseDate) { $bios.ReleaseDate.ToUniversalTime().ToString('o') } else { $null }
            RAMBytes = $computer.TotalPhysicalMemory
        }
    } $errors
    $events = Invoke-Collector 'Events' { Read-DiagnosticEvents $since $MaxEvents } $errors
    $drivers = @(Invoke-Collector 'Drivers' {
            Get-CimInstance Win32_PnPSignedDriver | Select-Object DeviceName, DeviceID, DriverProviderName,
                DriverVersion, @{n = 'DriverDate'; e = {
                        if ($_.DriverDate) { $_.DriverDate.ToUniversalTime().ToString('o') } else { $null }
                    }}, InfName, IsSigned, DriverName
        } $errors)
    $devices = @(Invoke-Collector 'Devices' {
            Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' |
                Select-Object Name, DeviceID, ConfigManagerErrorCode
        } $errors)
    $updates = @(Invoke-Collector 'Updates' {
            Get-CimInstance Win32_QuickFixEngineering | Select-Object HotFixID, Description,
                @{n = 'InstalledOn'; e = { [string]$_.InstalledOn }}
        } $errors)
    $dumpConfig = Invoke-Collector 'DumpConfiguration' {
        $config = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
        $paging = Get-CimInstance Win32_ComputerSystem | Select-Object -ExpandProperty AutomaticManagedPagefile
        [pscustomobject]@{
            CrashDumpEnabled = if ($config.PSObject.Properties.Name -contains 'CrashDumpEnabled') { $config.CrashDumpEnabled } else { $null }
            AutoReboot = if ($config.PSObject.Properties.Name -contains 'AutoReboot') { $config.AutoReboot } else { $null }
            AutomaticManagedPagefile = $paging
            Pagefiles = @(Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, CurrentUsage)
        }
    } $errors
    $disks = @(Invoke-Collector 'Disks' {
            Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' |
                Select-Object DeviceID, Size, FreeSpace
        } $errors)
    $dumps = @(Invoke-Collector 'Dumps' { Get-DumpInventory $since $MaxDumps } $errors)
    $analysis = @(Invoke-Collector 'DumpAnalysis' {
            Get-DumpAnalysis $dumps $DebuggerPath $SymbolCache -AllowSymbolDownload:$AllowSymbolDownload
        } $errors)
    $integrity = @()
    if ($VerifyWindows) {
        $integrity = @(Invoke-Collector 'WindowsIntegrity' {
                foreach ($check in @(
                        @{ Name = 'DISM CheckHealth'; File = 'dism.exe'; Args = '/Online /Cleanup-Image /CheckHealth /English' },
                        @{ Name = 'SFC VerifyOnly'; File = 'sfc.exe'; Args = '/verifyonly' })) {
                    $result = Invoke-BoundedProcess -FilePath (Join-Path "$env:SystemRoot\System32" $check.File) `
                        -Arguments $check.Args -TimeoutSeconds 900
                    [pscustomobject]@{
                        Name = $check.Name
                        ExitCode = $result.ExitCode
                        Output = $result.Output
                        ErrorOutput = $result.ErrorOutput
                    }
                }
            } $errors)
    }
    [pscustomobject]@{
        System = $system; Events = $events; Drivers = $drivers; ProblemDevices = $devices
        Updates = $updates; DumpConfiguration = $dumpConfig; Disks = $disks
        Dumps = $dumps; DumpAnalysis = $analysis; WindowsIntegrity = $integrity
        CollectionErrors = @($errors.ToArray())
    }
}

function New-Finding {
    param([string]$Id, [string]$Severity, [string]$Confidence, [string]$Title,
        [string[]]$Evidence, [string[]]$Actions)
    [pscustomobject]@{
        Id = $Id; Severity = $Severity; Confidence = $Confidence
        Title = $Title; Evidence = @($Evidence); Actions = @($Actions)
    }
}

function Get-DiagnosticFindings {
    param([Parameter(Mandatory)]$Data)
    $findings = New-Object 'System.Collections.Generic.List[object]'
    $crashes = @()
    if ($null -ne $Data.Events) {
        $crashes = @($Data.Events.Crashes)
        if ($Data.Events.QueryLimitReached) {
            $findings.Add((New-Finding 'event-limit' 'Warning' 'High' 'Händelsegränsen nåddes; historiken är ofullständig' `
                @("$($Data.Events.RecordsRead) händelser lästes.") `
                @('Öka MaxEvents eller begränsa LookbackDays innan frekvenser jämförs mellan datorer.')))
        }
        if (@($Data.Events.UnexpectedShutdowns).Count -gt 0) {
            $findings.Add((New-Finding 'unexpected-shutdown' 'Info' 'High' 'Oväntade avstängningar utan bugcheck-kod' `
                @("$(@($Data.Events.UnexpectedShutdowns).Count) händelser; flera kan avse samma avstängning.") `
                @('Kernel-Power 41 och EventLog 6008 bevisar inte blåskärm. Kontrollera ström, hård omstart och om dump kunde skrivas.')))
        }
        $fatalHardware = @($Data.Events.Hardware | Where-Object { $_.EventId -in @(18, 46) })
        $correctedHardware = @($Data.Events.Hardware | Where-Object { $_.EventId -in @(17, 19) })
        if ($fatalHardware.Count -gt 0) {
            $findings.Add((New-Finding 'whea-fatal' 'Critical' 'Medium' 'WHEA rapporterar allvarliga hårdvarufel' `
                @("$($fatalHardware.Count) WHEA-händelser (18/46). Läs felposterna; detta identifierar inte ensamt en trasig komponent.") `
                @('Kör OEM:s utökade RAM-, CPU- och lagringstest. Återställ överklockning/XMP till OEM-standard efter godkännande.',
                    'Jämför BIOS, firmware, RAM, SSD, nätadapter och docka mellan drabbade och friska datorer. Moderkortsbyte utesluter inte dessa orsaker.')))
        }
        if ($correctedHardware.Count -gt 0) {
            $findings.Add((New-Finding 'whea-corrected' 'Warning' 'Low' 'Korrigerade WHEA-fel finns i historiken' `
                @("$($correctedHardware.Count) WHEA-händelser (17/19); korrigerade fel är inte i sig bevis för BSOD-orsak.") `
                @('Kontrollera om tidsstämplarna sammanfaller med krascher. Jämför OEM BIOS/PCIe/SSD-firmware och kör hårdvarudiagnostik.')))
        }
        if (@($Data.Events.Storage).Count -gt 0) {
            $crashTimes = @($crashes | ForEach-Object {
                    [datetimeoffset]::Parse($_.TimeUtc).UtcDateTime.Ticks
                } | Sort-Object)
            $nearCrash = @($Data.Events.Storage | Where-Object {
                    $storageTicks = [datetimeoffset]::Parse($_.TimeUtc).UtcDateTime.Ticks
                    $lower = $storageTicks - [TimeSpan]::FromMinutes(15).Ticks
                    $upper = $storageTicks + [TimeSpan]::FromMinutes(15).Ticks
                    $left = 0
                    $right = $crashTimes.Count - 1
                    $found = $false
                    # A bounded binary search avoids quadratic work on busy event logs.
                    while ($left -le $right) {
                        $middle = [int][Math]::Floor(($left + $right) / 2)
                        if ($crashTimes[$middle] -lt $lower) { $left = $middle + 1 }
                        elseif ($crashTimes[$middle] -gt $upper) { $right = $middle - 1 }
                        else { $found = $true; break }
                    }
                    $found
                })
            $findings.Add((New-Finding 'storage-events' 'Warning' 'Medium' 'Lagrings- eller filsystemfel behöver undersökas' `
                @("$(@($Data.Events.Storage).Count) relevanta händelser; $($nearCrash.Count) inom 15 minuter från en bugcheck-händelse (korrelation, inte bevis).") `
                @('Säkerhetskopiera före ingrepp. Kontrollera OEM SSD-diagnostik, firmware och lagringsdrivrutin.',
                    'Granska händelsernas disk-/enhets-ID. Kör vid behov chkdsk /scan; schemalägg inte /f eller /r utan underhållsfönster.')))
        }
        if (@($Data.Events.DumpErrors).Count -gt 0) {
            $findings.Add((New-Finding 'dump-write-error' 'Warning' 'High' 'Windows kunde inte skapa kraschdump' `
                @("$(@($Data.Events.DumpErrors).Count) volmgr 161-händelser.") `
                @('Kontrollera CrashControl, växlingsfil på systemdisken, ledigt utrymme och eventuella lagringsfel.')))
        }
    }
    foreach ($group in @($crashes | Group-Object BugcheckCode)) {
        $actions = switch ($group.Name) {
            '0x0000009F' { @('Kontrollera OEM chipset-, nätverks-, GPU- och dockdrivrutiner samt BIOS. Reproducera vila/återupptagning och analysera väntande IRP i WinDbg.') }
            '0x00000124' { @('Analysera WHEA-felposten i WinDbg (!errrec). Kör OEM-hårdvarutest och kontrollera BIOS/firmware, temperatur och ström; byt inte komponent enbart på stopkoden.') }
            '0x00000116' { @('Kontrollera OEM GPU-drivrutin och GPU/temperatur. Jämför drivrutinsversion mot friska datorer och testa godkänd uppdatering eller rollback på pilotgrupp.') }
            '0x0000007A' { @('Kontrollera dumpens I/O-statuskod, SSD-hälsa, lagringsdrivrutin och växlingsfil. Säkerhetskopiera innan lagringsingrepp.') }
            { $_ -in @('0x0000000A', '0x000000D1', '0x00000050', '0x0000001A', '0x0000003B', '0x0000007E', '0x00000139') } {
                @('Analysera flera dumpar och jämför tredjepartsmoduler. Minneskorruption kan orsakas av både drivrutin och RAM; kör utökat RAM-test.',
                    'Jämför OEM drivrutiner, EDR/antivirus och VPN-versioner med friska datorer. Ändra en sak i taget på en pilotgrupp.')
            }
            default { @('Öppna kraschdumpen i WinDbg och kör !analyze -v. Jämför flera dumpar innan en drivrutin eller hårdvara pekas ut.') }
        }
        $findings.Add((New-Finding "bugcheck-$($group.Name)" 'Warning' 'Medium' "Registrerad stopkod $($group.Name)" `
            @("$($group.Count) händelser. Event 41 och 1001 kan beskriva samma krasch; antal händelser är inte antal krascher.") $actions))
    }
    $usableAnalysis = @($Data.DumpAnalysis | Where-Object { -not $_.SymbolWarning -and $_.Image })
    foreach ($group in @($usableAnalysis | Group-Object { $_.Image.ToLowerInvariant() })) {
        if ($group.Name -notmatch '\.sys$' -or
            $group.Name -match '^(ntoskrnl|ntkrnlmp|ntkrnlpa|ntkrpamp|hal|wdf01000|dxgkrnl|dxgmms2|memory_corruption)\.') { continue }
        $confidence = if ($group.Count -ge 2) { 'Medium' } else { 'Low' }
        $findings.Add((New-Finding "module-$($group.Name)" 'Warning' $confidence "Debuggern nämner $($group.Name) i $($group.Count) dump(ar)" `
            @($group.Group | ForEach-Object { "$([IO.Path]::GetFileName($_.Path)): $($_.BugcheckCode), bucket $($_.Bucket)" }) `
            @("Verifiera att $($group.Name) är felande part, inte bara offret för minneskorruption. Granska stack, symboler och flera dumpar i WinDbg.",
                'Identifiera leverantör och installerad version; jämför med friska datorer. Testa endast OEM-godkänd uppdatering/rollback på pilotgrupp.')))
    }
    if (@($Data.DumpAnalysis | Where-Object SymbolWarning).Count -gt 0) {
        $findings.Add((New-Finding 'symbols-incomplete' 'Warning' 'High' 'Dumpanalys har symbolvarningar' `
            @('Automatisk modulprioritering utesluter dessa dumpar.') `
            @('Använd matchande Microsoft- och leverantörssymboler och kör analysen igen.')))
    }
    if (@($Data.Dumps).Count -gt 0 -and @($Data.DumpAnalysis).Count -eq 0) {
        $findings.Add((New-Finding 'dump-analysis-needed' 'Info' 'High' 'Kraschdumpar finns men är inte analyserade' `
            @("$(@($Data.Dumps).Count) dump(ar) hittades.") `
            @('Installera Windows Debugging Tools och ange DebuggerPath till cdb.exe, eller analysera lokalt med WinDbg. Händelselogg ensam kan inte identifiera felande drivrutin.')))
    }
    if ($crashes.Count -gt 0 -and @($Data.Dumps).Count -eq 0) {
        $findings.Add((New-Finding 'missing-dumps' 'Warning' 'Medium' 'Bugcheck registrerades men ingen aktuell dump hittades' `
            @('Dump kan ha raderats, flyttats eller misslyckats att skrivas.') `
            @('Kontrollera inställningen Automatisk minnesdump eller Liten minnesdump, systemhanterad växlingsfil och ledigt diskutrymme. Agenten ändrar inte inställningarna.')))
    }
    if ($null -ne $Data.DumpConfiguration -and $Data.DumpConfiguration.CrashDumpEnabled -eq 0) {
        $findings.Add((New-Finding 'dumps-disabled' 'Warning' 'High' 'Kraschdump är avstängd' `
            @('CrashDumpEnabled = 0.') `
            @('Aktivera automatisk eller liten minnesdump via godkänd konfiguration så att nästa krasch kan analyseras.')))
    }
    if (@($Data.ProblemDevices).Count -gt 0) {
        $findings.Add((New-Finding 'problem-devices' 'Warning' 'Low' 'Enheter rapporterar konfigurationsfel' `
            @($Data.ProblemDevices | ForEach-Object { "$($_.Name): kod $($_.ConfigManagerErrorCode)" }) `
            @('Granska Enhetshanteraren och OEM-drivrutin för varje enhet. En avsiktligt inaktiverad enhet kan också ha felkod och är inte automatiskt BSOD-orsak.')))
    }
    foreach ($disk in $Data.Disks) {
        if ($null -ne $disk.Size -and $disk.Size -gt 0 -and $null -ne $disk.FreeSpace -and
            $disk.FreeSpace / $disk.Size -lt 0.1) {
            $findings.Add((New-Finding "disk-space-$($disk.DeviceID)" 'Warning' 'High' "Lite ledigt utrymme på $($disk.DeviceID)" `
                @("$([Math]::Round($disk.FreeSpace / 1GB, 1)) GiB ledigt; under 10 procent.") `
                @('Frigör utrymme enligt kundens policy. Full minnesdump kan kräva utrymme motsvarande RAM plus marginal.')))
        }
    }
    foreach ($check in $Data.WindowsIntegrity) {
        $findings.Add((New-Finding "integrity-$($check.Name)" 'Info' 'High' "Windows-kontroll: $($check.Name)" `
            @("Exitkod: $($check.ExitCode). Läs fullständigt kommandoresultat i rapporten; exitkod ensam bevisar inte friskt Windows.") `
            @('Granska DISM/SFC-resultat samt CBS.log/DISM.log. CheckHealth läser endast redan registrerad komponentlagerstatus; det är ingen fullständig skanning.',
                'Vid bekräftad korruption: planera DISM /RestoreHealth följt av sfc /scannow med godkänt underhållsfönster.')))
    }
    foreach ($errorRecord in $Data.CollectionErrors) {
        $findings.Add((New-Finding "collection-$($errorRecord.Collector)" 'Warning' 'High' "Ofullständig insamling: $($errorRecord.Collector)" `
            @($errorRecord.Message) @('Åtgärda insamlingsfelet och kör igen. Saknad data ska inte tolkas som att datorn är felfri.')))
    }
    if ($null -ne $Data.Events -and $crashes.Count -eq 0) {
        $findings.Add((New-Finding 'no-bugchecks' 'Info' 'Medium' 'Ingen läsbar bugcheck hittades i det valda intervallet' `
            @('Detta utesluter inte blåskärm, rensad logg eller problem utanför intervallet.') `
            @('Kontrollera tidsperiod, dumpfiler och hur kraschen yttrar sig. Jämför rapporten med användarens kraschtider.')))
    }
    $findings.Add((New-Finding 'fleet-comparison' 'Info' 'Low' 'Jämför drabbade och friska datorer innan bred utrullning' `
        @('Ålder på en drivrutin och Microsofts generiska kernel-modul är inte i sig bevis för fel.') `
        @('Gruppera på modell, BIOS, stopkod, dumpens modul/bucket och drivrutinsversion. Ta kontrollrapporter från friska datorer av samma modell.',
            'Testa en förändring åt gången på liten pilotgrupp och följ nya krascher. Undvik Driver Verifier i produktion utan återställningsplan; det kan orsaka bootloop.')))
    @($findings.ToArray())
}

function ConvertTo-HtmlText {
    param([AllowNull()]$Value)
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-DiagnosticHtml {
    param([Parameter(Mandatory)]$Report)
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append(@'
<!doctype html><html lang="sv"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
<title>Windows BSOD-diagnostik</title><style>
body{font:16px system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;background:#f5f7fa;color:#182230}
article,details{background:white;border:1px solid #ccd5df;border-radius:8px;padding:1rem;margin:1rem 0}
h1,h2{line-height:1.2}.Critical{border-left:6px solid #b91c1c}.Warning{border-left:6px solid #b45309}
.Info{border-left:6px solid #2563eb}pre{white-space:pre-wrap;overflow-wrap:anywhere}li{margin:.5rem 0}
</style></head><body><h1>Windows BSOD-diagnostik</h1>
<p>Beslutsstöd, inte en fastställd rotorsak. Inga automatiska reparationer utförs.</p>
'@)
    [void]$builder.Append("<p>Skapad: $(ConvertTo-HtmlText $Report.GeneratedUtc) | Version: $(ConvertTo-HtmlText $Report.AgentVersion) | Status: $(ConvertTo-HtmlText $Report.Status)</p>")
    [void]$builder.Append("<p>Period: $(ConvertTo-HtmlText $Report.LookbackDays) dagar. Uppladdning: $(ConvertTo-HtmlText $Report.Upload.Status)</p>")
    if ($Report.Upload.Error) { [void]$builder.Append("<p>Rapporteringsfel: $(ConvertTo-HtmlText $Report.Upload.Error)</p>") }
    foreach ($finding in $Report.Findings) {
        $css = if ($finding.Severity -in @('Critical', 'Warning', 'Info')) { $finding.Severity } else { 'Info' }
        [void]$builder.Append("<article class=`"$css`"><h2>$(ConvertTo-HtmlText $finding.Title)</h2><p>Prioritet: $(ConvertTo-HtmlText $finding.Severity) | Evidensstyrka: $(ConvertTo-HtmlText $finding.Confidence)</p><h3>Evidens</h3><ul>")
        foreach ($evidence in $finding.Evidence) { [void]$builder.Append("<li>$(ConvertTo-HtmlText $evidence)</li>") }
        [void]$builder.Append('</ul><h3>Konkreta nästa steg</h3><ul>')
        foreach ($action in $finding.Actions) { [void]$builder.Append("<li>$(ConvertTo-HtmlText $action)</li>") }
        [void]$builder.Append('</ul></article>')
    }
    foreach ($property in $Report.Data.PSObject.Properties) {
        $json = ConvertTo-Json -InputObject $property.Value -Depth 12
        [void]$builder.Append("<details><summary>$(ConvertTo-HtmlText $property.Name)</summary><pre>$(ConvertTo-HtmlText $json)</pre></details>")
    }
    [void]$builder.Append('</body></html>')
    $builder.ToString()
}

function Save-DiagnosticReport {
    param($Report, [string]$OutputDirectory)
    [void][IO.Directory]::CreateDirectory($OutputDirectory)
    $encoding = New-Object Text.UTF8Encoding($false)
    foreach ($file in @(
            @{ Name = 'report.json'; Content = (ConvertTo-Json -InputObject $Report -Depth 16) },
            @{ Name = 'report.html'; Content = (ConvertTo-DiagnosticHtml $Report) })) {
        $path = Join-Path $OutputDirectory $file.Name
        $temporary = "$path.tmp"
        try {
            [IO.File]::WriteAllText($temporary, $file.Content, $encoding)
            Move-Item -LiteralPath $temporary -Destination $path -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
}

function New-UploadPayload {
    param($Report, [string]$IdentitySalt)
    if ([string]::IsNullOrWhiteSpace($IdentitySalt) -or $IdentitySalt.Length -lt 16) {
        throw 'CRASHLOG_IDENTITY_SALT måste ha minst 16 tecken för pseudonymiserad central rapportering.'
    }
    $machineGuid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("$IdentitySalt|$machineGuid"))
        $deviceId = ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    # Exclude names, full inventories, messages, file paths and raw dump contents.
    [pscustomobject]@{
        SchemaVersion = $Report.SchemaVersion
        ReportId = $Report.ReportId
        DeviceId = $deviceId
        AgentVersion = $Report.AgentVersion
        GeneratedUtc = $Report.GeneratedUtc
        LookbackDays = $Report.LookbackDays
        Status = $Report.Status
        System = if ($null -ne $Report.Data.System) {
            $Report.Data.System | Select-Object Manufacturer, Model, Version, Build, BIOSVersion
        } else { $null }
        Bugchecks = if ($null -ne $Report.Data.Events) {
            @($Report.Data.Events.Crashes | Select-Object TimeUtc, EventId, BugcheckCode)
        } else { @() }
        DumpAnalysis = @($Report.Data.DumpAnalysis | Select-Object ModifiedUtc, Module, Image, Bucket, BugcheckCode, SymbolWarning)
        DriverVersions = @($Report.Data.Drivers | Select-Object DriverProviderName, DriverVersion, DriverDate, InfName, IsSigned |
            Sort-Object DriverProviderName, DriverVersion, InfName -Unique)
        FindingIds = @($Report.Findings | Select-Object Id, Severity, Confidence)
        FailedCollectors = @($Report.Data.CollectionErrors | Select-Object -ExpandProperty Collector)
    }
}

function Send-DiagnosticReport {
    param($Report, [uri]$Endpoint)
    if ($Endpoint.Scheme -ne 'https' -or $Endpoint.UserInfo -or $Endpoint.Fragment -or $Endpoint.Query) {
        throw 'ReportEndpoint måste vara HTTPS utan användaruppgifter, query-parametrar eller fragment.'
    }
    $token = [Environment]::GetEnvironmentVariable('CRASHLOG_REPORT_TOKEN', 'Process')
    if ([string]::IsNullOrWhiteSpace($token)) { throw 'CRASHLOG_REPORT_TOKEN saknas. Ingen rapport skickades.' }
    $salt = [Environment]::GetEnvironmentVariable('CRASHLOG_IDENTITY_SALT', 'Process')
    $payload = New-UploadPayload $Report $salt
    $json = ConvertTo-Json -InputObject $payload -Depth 12 -Compress
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    # No redirects: bearer credentials must not be forwarded to a different host.
    $response = Invoke-WebRequest -Uri $Endpoint -Method Post -ContentType 'application/json; charset=utf-8' `
        -Body ([Text.Encoding]::UTF8.GetBytes($json)) -Headers @{
            Authorization = "Bearer $token"; 'Idempotency-Key' = $Report.ReportId
        } -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 60 -ErrorAction Stop
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Rapportmottagaren svarade med HTTP $($response.StatusCode)."
    }
}

Export-ModuleMember -Function Get-DiagnosticData, Get-DiagnosticFindings, ConvertTo-DiagnosticHtml,
    Save-DiagnosticReport, Send-DiagnosticReport, ConvertTo-BugcheckCode, ConvertTo-CrashEvent,
    ConvertFrom-DebuggerOutput, Invoke-BoundedProcess
