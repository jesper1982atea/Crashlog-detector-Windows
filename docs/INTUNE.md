# Distribution med Intune

## Förutsättningar

- Windows 10/11 x64, 64-bitars Windows PowerShell 5.1, lokal administratör/SYSTEM.
- Organisationens policy måste tillåta skripten. Signera `.ps1` **och** `.psm1`
  med ett betrott kodsigneringscertifikat före paketering. `RemoteSigned` i
  tasken åsidosätter inte en tvingande Group Policy/AllSigned-policy.
- Inkludera inte token, salt, rapporter eller dumpar i Win32-paketet.
- `cdb.exe` är valfritt och ingår inte; distribuera Debugging Tools separat.

## Skapa Win32-paket

Använd Microsoft Win32 Content Prep Tool (`IntuneWinAppUtil.exe`) från Microsoft.
Staging-katalogen ska bara innehålla `src/` och `intune/` från detta repo:

```text
CrashlogPackage/
  src/
    Crashlog.Diagnostics.psm1
    Invoke-CrashlogDiagnostics.ps1
  intune/
    Deployment.Common.psm1
    Install-CrashlogDetector.ps1
    Run-InstalledDiagnostics.ps1
    Detect-CrashlogDetector.ps1
    Set-ReportingConfiguration.ps1
    Uninstall-CrashlogDetector.ps1
```

Exempel (output-katalog utanför staging):

```powershell
.\IntuneWinAppUtil.exe -c C:\Packaging\CrashlogPackage `
  -s C:\Packaging\CrashlogPackage\intune\Install-CrashlogDetector.ps1 `
  -o C:\Packaging\Output -q
```

Ladda upp `.intunewin` som **Windows app (Win32)**. Install behavior: **System**.
Krav: Windows 10/11, x64. Intune Management Extension kör normalt en 32-bitars
process, så använd `Sysnative` för att nå native Windows PowerShell:

```text
Install command:
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File .\intune\Install-CrashlogDetector.ps1 -LookbackDays 30 -ScheduleHour 10 -RetainReports 14

Uninstall command:
%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File .\intune\Uninstall-CrashlogDetector.ps1
```

Om installationsvärden redan är 64-bitars, använd `System32` i stället för
`Sysnative`. Installation ger 0 vid framgång och 1 vid fel. Lägg inte till
diagnostikens exitkoder 2/3 som installationsframgångar.

## Detection rule

Använd **custom detection script** `intune/Detect-CrashlogDetector.ps1`.
**Run script as 32-bit process on 64-bit clients: No**.
Ställ signeringskontroll efter organisationens policy.
Skriptet kräver både förväntad version/filer och en aktiverad SYSTEM-task med
förväntad action. Det returnerar text + exit 0 endast om installerat.

Detection verifierar **inte** att datorn är frisk eller att rapportering fungerar.
Agentversion `1.0.0` finns i entrypoint, installer och detection; vid nästa
paketversion måste dessa uppdateras tillsammans.

## Körning och rapporter

Tasken `CrashlogDetector-Daily` kör dagligen vid `ScheduleHour` i klientens lokala
tid. Missat starttillfälle körs när datorn blir tillgänglig. Installation startar
dessutom första körningen direkt. Tasken tillåter batteridrift; välj pilot och
tidpunkt med hänsyn till prestanda, särskilt vid dump-/integritetsanalys.
Taskens maximala körtid är två timmar; överskridande är en misslyckad körning,
inte en friskdiagnos.

```powershell
Start-ScheduledTask -TaskName CrashlogDetector-Daily
Get-ScheduledTaskInfo -TaskName CrashlogDetector-Daily
Get-Content "$env:ProgramData\CrashlogDetector\last-run.json" -Raw
Get-Content "$env:ProgramData\CrashlogDetector\Reports\Latest\report.json" -Raw |
  ConvertFrom-Json | Select-Object GeneratedUtc, Status, Upload
```

`LastTaskResult` följer agentens exitkoder i README. `last-run.json` visar start,
slut, status och exitkod; vid wrapper-/konfigurationsfel även felande steg och
felkategori (utan hemligheter). För exakt fel, kör wrappern manuellt som
administratör/SYSTEM. Om processen avbryts kan status bli kvar som `Running`;
granska då även Task Scheduler-loggen. Kontrollera alltid
rapportens `GeneratedUtc`: en gammal rapport får inte tolkas som ny framgång.
Även rapporter med ofullständig insamling/misslyckad uppladdning arkiveras.
Retentionsgränsen avser **antal körningar**, inte antal dagar.

Filer sparas under `%ProgramData%\CrashlogDetector`:

| Sökväg | Innehåll |
| --- | --- |
| `Agent/` | Installerade skript/moduler |
| `Reports/Latest/report.html` och `report.json` | Senaste rapport |
| `Reports/<UTC-tid>-<rapport-ID>/` | Historik, normalt senaste 14 körningarna |
| `Symbols/` | Lokal symbolcache; växer vid aktiverad symbolhämtning |
| `settings.json` | Insamlingsparametrar |
| `last-run.json` | Senaste körningsstatus, inklusive wrapperfel |
| `reporting.json` | Valfri HTTPS-konfiguration och DPAPI-skyddade uppgifter |

Endast SYSTEM och lokala administratörer har åtkomst. Öppna/kopiera rapporter via
godkänd administrativ åtkomst, inte genom att ge alla användare läsrättigheter.
Installationen avvisar junctions/symlinks i installationskatalogen.

Valfria installationsparametrar: `DebuggerPath`, `AllowSymbolDownload`,
`VerifyWindows`. Exempel på tillägg till install command:

```text
-DebuggerPath "C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe" -AllowSymbolDownload
```

Uppdatering bevarar rapporteringskonfiguration och rapporter men ersätter
insamlingsinställningarna med installationskommandots värden. Kör inte uppdatering
eller avinstallation medan diagnostiken pågår.

## Avinstallation

Avinstallation tar bort task, agent, inställningar, symbolcache och skyddade
rapporteringsuppgifter. Rapporter sparas för fortsatt utredning. Lägg till
`-RemoveReports` för att uttryckligen radera även rapportkatalogen.

## Pilotens acceptanskriterier

Verifiera på en Windows-testdator innan Required-tilldelning:

1. Installera som SYSTEM med samma kommando som Intune och kontrollera detection.
2. Kontrollera att användare inte kan skriva/läsa agent, rapporter eller credentials.
3. Jämför stopkod och tid med en känd befintlig dump/Event Viewer. Utan krascher
   ska rapporten inte påstå att maskinen är felfri.
4. Testa cdb med riktiga dumpar och symboler om dumpanalys aktiveras.
5. Testa HTTPS som SYSTEM, inklusive 401, nätverksavbrott och spärrad redirect.
   Lokal rapport ska kvarstå med `Upload.Status = Failed` och taskresultat 3.
6. Testa historik/retention och avinstallation samt att gammal rapport inte
   arkiveras vid misslyckad körning.
