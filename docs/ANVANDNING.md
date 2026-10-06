# Användarguide: hitta orsaken till återkommande blåskärmar

Den här guiden är för IT-tekniker. Agenten samlar underlag och föreslår nästa
steg; den reparerar inte datorn och kan inte ensam fastställa en rotorsak.
Börja med en drabbad dator innan du distribuerar till fler.

## 1. Förbered datorn

Du behöver Windows 10/11 **x64**, **64-bitars Windows PowerShell 5.1** och
administratörsrättigheter. Behåll hela katalogstrukturen när du hämtar projektet.
Internet krävs inte för grundinsamlingen.

Notera användarens ungefärliga kraschtider, vad datorn gjorde vid kraschen och
om den var ansluten till docka. Notera även vilka komponenter, BIOS-versioner
och drivrutiner ni redan har provat att byta.

Skript måste vara tillåtna enligt organisationens policy. För produktion:
signera skripten och modulerna med organisationens betrodda certifikat.
Använd inte `ExecutionPolicy Bypass` för att kringgå kundens policy.

## 2. Hämta projektet från GitHub

Öppna [projektet på GitHub](https://github.com/jesper1982atea/Crashlog-detector-Windows).
Välj den branch som innehåller agenten, eller `main` efter att pull requesten
har slagits ihop. Välj **Code → Download ZIP**, packa upp och placera hela
projektet i exempelvis `C:\Tools\CrashlogDetector`.

Alternativt, om Git är installerat:

```powershell
git clone --branch jesper1982atea-windows-bsod-diagnostics `
  https://github.com/jesper1982atea/Crashlog-detector-Windows.git `
  C:\Tools\CrashlogDetector
```

Branchkommandot hämtar den första publicerade versionen även innan den finns
på `main`. Efter merge kan `--branch jesper1982atea-windows-bsod-diagnostics`
utelämnas för att hämta `main`.

Om Windows blockerar nedladdade filer: granska ursprung och innehåll först och
följ kundens rutin för godkännande/kodsignering. Avblockera bara granskade
filer om policyn tillåter det; ändra inte maskinens policy generellt.

## 3. Starta en grundinsamling

Öppna Start, sök efter **Windows PowerShell** och välj **Kör som administratör**.
Välj inte varianten märkt **(x86)**.

Kör följande kommandon från projektets rotkatalog:

```powershell
Set-Location 'C:\Tools\CrashlogDetector'
[Environment]::Is64BitProcess
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
  -File .\src\Invoke-CrashlogDiagnostics.ps1 -LookbackDays 30
$diagnosticExitCode = $LASTEXITCODE
"Diagnostikens exitkod: $diagnosticExitCode"
```

`Is64BitProcess` ska visa `True`. En separat PowerShell-process används här
eftersom agenten avslutas med en exitkod; ditt öppna terminalfönster blir kvar.
Vänta tills kommandot är klart.

Grundinsamlingen läser Windows-loggar, drivrutinsinventering och systemdata.
Den inventerar dumpar men analyserar inte deras innehåll utan separat debugger.
Den laddar inte upp rapporter och gör inga automatiska reparationer.

## 4. Öppna rapporten

```powershell
$reportDirectory = "$env:ProgramData\CrashlogDetector\Reports\Latest"
Start-Process "$reportDirectory\report.html"
Get-Content "$reportDirectory\report.json" -Raw |
  ConvertFrom-Json | Select-Object GeneratedUtc, Status, LookbackDays, Upload
```

Rapporten finns normalt här:

```text
C:\ProgramData\CrashlogDetector\Reports\Latest\report.html
C:\ProgramData\CrashlogDetector\Reports\Latest\report.json
```

HTML är för läsning; JSON är för vidare bearbetning. Rapportkatalogen är skyddad
för SYSTEM och administratörer. Om webbläsaren inte kan läsa filen från ditt
vanliga användarkonto, använd administrativ åtkomst för att kopiera den till
en **godkänd skyddad arbetskatalog**. Gör inte originalkatalogen läsbar för alla.

Kontrollera alltid `GeneratedUtc` först: är detta den nya körningens rapport?
`Complete` betyder att insamlingen slutfördes, **inte** att datorn är frisk.
`Partial` betyder att data saknas eller att händelsegränsen nåddes.
Expandera rapportens rådatasektioner vid behov.

| Det du ser | Vad du ska göra |
| --- | --- |
| Stopkod, exempelvis `0x000000D1` | Läs åtgärdsförslaget och analysera dumpar; både drivrutin och RAM kan vara orsaken |
| Samma tredjepartsmodul i flera dumpar | Kontrollera stack, symboler och leverantör; jämför version mot friska datorer |
| WHEA 18/46 | Granska felposten och kör OEM:s utökade hårdvarudiagnostik; välj inte komponent enbart utifrån event-ID |
| Korrigerade WHEA 17/19 | Undersök samband med kraschtider; dessa är inte ensamma bevis för BSOD-orsak |
| Lagringsfel nära en bugcheck | Säkerhetskopiera och kontrollera rätt SSD/enhet, firmware och lagringsdrivrutin |
| Kernel-Power utan bugcheck-kod | Utred ström/hård omstart och dumpinställningar; detta bevisar inte blåskärm |
| Bugcheck men ingen dump | Kontrollera Windows-inställningar, växlingsfil, ledigt utrymme och volmgr-fel |
| Insamlingsfel | Åtgärda felet och kör igen; saknad data är inte en friskdiagnos |
| Ingen bugcheck hittad | Kontrollera tidsfönster, rensade loggar, befintliga dumpar och användarens tider |

Antal händelser är inte antal krascher: 41 och 1001 kan beskriva samma incident.

## 5. Analysera dumpar för bättre drivrutinsunderlag

Installera **Debugging Tools for Windows** från Microsofts Windows SDK på
testdatorn enligt kundens policy. Det ska finnas en x64-version av `cdb.exe`;
enbart installation av WinDbg-appen garanterar inte denna sökväg.

Kontrollera och kör:

```powershell
$debugger = 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe'
Test-Path -LiteralPath $debugger
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
  -File .\src\Invoke-CrashlogDiagnostics.ps1 -LookbackDays 30 `
  -DebuggerPath $debugger -AllowSymbolDownload -MaxDumps 5
"Diagnostikens exitkod: $LASTEXITCODE"
```

`Test-Path` ska visa `True`; ändra sökvägen om verktyget installerats på annan
plats. `AllowSymbolDownload` tillåter hämtning från Microsofts symbolserver.
Inga dumpfiler laddas upp av agenten. Utan flaggan används bara lokal symbolcache.

Varje dump har tre minuters timeout; flera dumpar kan ta tid.
Vid symbolvarningar eller ofullständig analys: öppna dumpen i WinDbg, använd
matchande symboler och granska `!analyze -v` samt stacken manuellt.
En nämnd modul kan vara ett offer för minneskorruption, inte orsaken.

## 6. Kontrollera Windows-filer vid behov

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned `
  -File .\src\Invoke-CrashlogDiagnostics.ps1 -LookbackDays 30 -VerifyWindows
"Diagnostikens exitkod: $LASTEXITCODE"
```

Detta kör `DISM /Online /Cleanup-Image /CheckHealth /English` och
`sfc /verifyonly`. Ingen reparation görs. Kontrollerna kan sammanlagt ta upp
till 30 minuter. Läs resultaten under `WindowsIntegrity`.
CheckHealth är inte en fullständig korruptionsskanning.

Om korruption bekräftas, planera godkänd reparation och underhållsfönster
separat. Agenten kör inte `RestoreHealth`, `sfc /scannow` eller omstart.

Varje direktkörning ersätter föregående rapport i `Latest`. Om du vill behålla
grundrapporten före en ny körning, kopiera HTML och JSON till en godkänd skyddad
ärendekatalog först. Skicka aldrig kundrapporter/dumpar till publika GitHub-issues.

## 7. Jämför flera datorer och välj åtgärd

Samla rapporter med samma parametrar från några drabbade och några friska
datorer av samma modell. Jämför BIOS, Windows-build, drivrutinsversioner och
dumpens stopkod/modul/bucket. Jämför även VPN-/EDR-versioner från kundens
inventariesystem; agenten gör ingen fullständig programinventering.

Testa **en förändring åt gången** på en liten pilot: exempelvis OEM-godkänd
drivrutinsrollback eller firmwareuppdatering. Dokumentera vad som ändrades och
följ nya krascher jämfört med kontrollgruppen innan bred utrullning.
Moderkortsbyte utesluter inte RAM, SSD, ström, docka eller mjukvarufel.

## 8. Automatisera med Intune

Följ [Intune-guiden](INTUNE.md) för paketering som Win32-app, SYSTEM-installation,
64-bitars detection och daglig schemaläggning. Börja med en testgrupp.
Installationen startar första insamlingen och sparar normalt 14 historiska
körningar plus `Latest`.

**Intunes installationsstatus innehåller inte diagnostikrapporten.**
Hämta lokala rapporter genom godkänd administrativ åtkomst eller konfigurera
valfri central rapportering enligt [rapporteringsguiden](REPORTING.md).
En central mottagare/dashboard måste tillhandahållas separat.

## Vanliga problem

| Problem | Åtgärd |
| --- | --- |
| Skript blockeras | Kontrollera kodsignering, nedladdningsblockering och kundens policy; kringgå inte policyn |
| Åtkomst nekas | Kör som administratör/SYSTEM och använd 64-bitars PowerShell |
| Händelsegräns nådd | Kör om med exempelvis `-MaxEvents 10000`, eller minska tidsfönstret |
| Ingen aktuell dump | Kontrollera dumpkonfiguration och växlingsfil; agenten ändrar inte dessa |
| cdb-timeout/symbolfel | Kontrollera debugger/symboler/nätverk och analysera berörd dump manuellt |
| Exitkod 1 | Körfel; kontrollera terminalens feltext och om en annan körning redan pågår |
| Exitkod 2 | Ofullständig insamling; läs `CollectionErrors` och rapportens varningar |
| Exitkod 3 | Uppladdningsfel; lokal rapport finns kvar, kontrollera mottagare/credentials/nätverk |
| Gammal rapport efter schemalagd körning | Läs `last-run.json` och Task Scheduler-resultat; gammal rapport är inte en ny framgång |

Verklig Windows-/dumpanalys och Intune-distribution ska verifieras i pilot.
Detta är beslutsstöd för felsökning, inte ett automatiskt godkännande av
datorns hälsa eller en garanti att en identifierad drivrutin är felaktig.
