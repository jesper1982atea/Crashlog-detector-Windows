# Crashlog Detector för Windows

Skrivskyddad PowerShell-agent för återkommande blåskärmar på Windows 10/11 x64.
Kör på en enskild dator eller distribuera som en Win32-app via Intune.
Resultatet är en lokal HTML-rapport med **evidens, osäkerhet och konkreta
åtgärdsförslag**, samt JSON för vidare analys. Gränssnittet och råden är på svenska.

## Börja här

Läs [användarguiden steg för steg](docs/ANVANDNING.md) för att hämta agenten,
köra den på en drabbad dator och tolka resultatet. För flera datorer finns
[Intune-instruktionen](docs/INTUNE.md). [Central rapportering](docs/REPORTING.md)
är valfri och kräver en separat mottagare.

**Första versionen är avsedd för pilot.** Verifiera på riktiga Windows-datorer
innan bred distribution; automatiserade mocktester ersätter inte en sådan pilot.

## Vad agenten undersöker

| Område | Insamling och användning |
| --- | --- |
| Blåskärmar | Systemloggens WER/BugCheck 1001 och Kernel-Power 41 med faktisk bugcheck-kod; stöd för lokaliserad XML |
| Andra avstängningar | Event 41 utan kod och 6008 hålls isär från verifierade bugcheck-händelser |
| Drivrutiner | PnP-drivrutinernas leverantör, version, datum, INF och signeringsstatus; enheter med konfigurationsfel |
| Hårdvara | Modell, BIOS, Windows-version, RAM, korrigerade och allvarliga WHEA-händelser |
| Lagring | Disk-/NTFS-/lagringstimeouter, korrelation inom 15 minuter från bugcheck, ledigt utrymme |
| Kraschdumpar | Inventering av standard- och CrashControl-sökvägar, dump-/växlingsfilsinställningar och volmgr 161 |
| Windows | Installerade QFE-hotfixar; valfri DISM CheckHealth och SFC VerifyOnly utan reparation |
| Dumpanalys | Valfri `cdb.exe !analyze -v`: stopkod, modul, image och failure bucket; symbolvarningar synliggörs |

En händelse är **inte** samma sak som en krasch: 41 och 1001 kan beskriva samma
incident. Agenten rapporterar händelser, inte ett deduplicerat antal blåskärmar.
Återkommande modulnamn i flera dumpar prioriteras som hypotes, aldrig som bevis.
Generiska kernel-moduler och dumpar med upptäckta symbolvarningar används inte
för automatisk drivrutinsprioritering. Signering och drivrutinsålder avgör inte
om en drivrutin är felaktig.

## Kör lokalt

Öppna **64-bitars Windows PowerShell 5.1 som administratör**:

```powershell
.\src\Invoke-CrashlogDiagnostics.ps1 -LookbackDays 30
Start-Process "$env:ProgramData\CrashlogDetector\Reports\Latest\report.html"
```

Ingen extra runtime eller PowerShell-modul krävs. Standardkörningen hämtar inga
verktyg, laddar inte upp data och gör inga reparationer. Den skriver rapportfiler;
valfria Windows-kontroller/debugger kan också skriva Windows-loggar/symbolcache.
Även direktkörning till standardkatalogen låser agentkatalogens behörigheter
till SYSTEM/administratörer. Behåll repots `intune/Deployment.Common.psm1`
vid direktkörning. Om du väljer en egen `OutputDirectory` utanför standardens
rapportkatalog ansvarar du själv för dess ACL och för att undvika delade mappar.
Skript måste vara tillåtna enligt kundens exekveringspolicy. Använd
organisationens kodsignering i produktion, inte `ExecutionPolicy Bypass`.
PowerShell-filerna har UTF-8 BOM för svenska tecken i Windows PowerShell 5.1.

Valfria Windows-kontroller kan ta upp till 30 minuter tillsammans:

```powershell
.\src\Invoke-CrashlogDiagnostics.ps1 -VerifyWindows
```

`DISM /CheckHealth` läser redan registrerad korruption, **inte** en fullständig
komponentlagerskanning. `sfc /verifyonly` verifierar utan att reparera. Resultaten
visas som rådata att granska; agenten tolkar inte lokaliserad SFC-text som ett
entydigt frisk-/felbesked. QFE-listan omfattar inte alla Windows-/drivrutinsuppdateringar.

För bättre drivrutinsindikationer, installera Microsofts **Debugging Tools for
Windows** separat och ange den lokala sökvägen till `cdb.exe`:

```powershell
.\src\Invoke-CrashlogDiagnostics.ps1 `
  -DebuggerPath 'C:\Program Files (x86)\Windows Kits\10\Debuggers\x64\cdb.exe' `
  -AllowSymbolDownload -MaxDumps 5
```

Utan `AllowSymbolDownload` används endast lokal symbolcache. Med flaggan får
debuggern kontakta Microsofts symbolserver; inga dumpfiler laddas upp av agenten.
Varje dumpanalys har 180 sekunders timeout. Saknade/felaktiga symboler, otillräcklig
dump eller misslyckad insamling kan ge en ofullständig rapport. Granska alltid
stack och matchande symboler i WinDbg innan en drivrutin utpekas.
Agenten inkluderar inte full debuggertext i rapporten.

Parametrar: `LookbackDays` 1–365 (30), `MaxEvents` 100–100000 (2000),
`MaxDumps` 1–50 (10), `OutputDirectory`, `DebuggerPath`, `SymbolCache`,
`AllowSymbolDownload`, `VerifyWindows` och `ReportEndpoint`.
Rapporter över samma `OutputDirectory` ersätts vid nästa körning.

| Exitkod | Betydelse |
| --- | --- |
| 0 | Insamlingen slutfördes; **betyder inte att datorn är felfri** |
| 1 | Körningen misslyckades, t.ex. fel behörighet eller samtidig körning |
| 2 | Ofullständig insamling, se `CollectionErrors` och åtgärdsförslag |
| 3 | Valfri uppladdning misslyckades; lokal rapport finns kvar |

## Intune

Se [paketering, detection, schemaläggning och avinstallation](docs/INTUNE.md).
Installationen låser `%ProgramData%\CrashlogDetector` till SYSTEM och
administratörer och skapar en daglig SYSTEM-task. Den sparar senaste rapporten
plus normalt 14 historiska rapporter. Slutanvändare har inte åtkomst till dessa
rapporter; de är avsedda för IT.

## Central rapportering

**En central server/dashboard ingår inte i den här versionen.** Agenten kan skicka
en pseudonymiserad sammanfattning till en av er godkänd HTTPS-mottagare.
Denna måste implementeras/anslutas separat och validera bearer-token,
lagra rapporter och erbjuda sammanställning. Agenten rapporterar aldrig via
Intunes vanliga installationsstatus; Intune-status visar endast installation.
Se [rapportformat, autentisering och dataskydd](docs/REPORTING.md).

## Rekommenderat upplägg för kunden

1. Samla rapporter från en pilot med drabbade datorer och friska datorer av samma modell.
2. Säkerställ att dump faktiskt skapas och analysera flera dumpar. Gruppera modell,
   BIOS, stopkoder, modul/bucket, drivrutiner samt VPN/EDR-versioner från ert inventariesystem.
3. Prioritera en återkommande tredjepartsmodul, WHEA-felpost eller lagringsfel som
   hypotes. Att moderkort bytts utesluter inte RAM, SSD, ström, docka, BIOS eller drivrutin.
4. Testa en OEM-godkänd drivrutinsuppdatering/rollback eller firmwareförändring åt
   gången i en liten pilot. Följ nya krascher mot kontrollgruppen innan bred utrullning.

Agenten ändrar inte BIOS, drivrutiner, dumpinställningar eller växlingsfil och kör
inte Driver Verifier eller reparationer automatiskt. Driver Verifier kan orsaka
bootloop och ska bara användas med återställningsplan.

## Utveckling och verifiering

```powershell
.\tests\Run-Tests.ps1
```

Testerna kräver inga externa paket och täcker parsning, krasch-/strömavbrottsskillnad,
leverantörsfilter, prioriteringsregler, gränsvärden, rapportkodning, timeout och
dataminimering. GitHub Actions kör dem med Windows PowerShell 5.1 och PowerShell 7.
Mocktester ersätter inte en Windows-pilot: CIM/EventLog, verkliga dumpar,
SYSTEM/ACL/DPAPI och Intune-installation måste verifieras på kundens testdatorer.
