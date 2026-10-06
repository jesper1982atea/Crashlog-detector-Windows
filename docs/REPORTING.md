# Central rapportering och dataskydd

## Arkitektur och gräns

Agenten är en klient, inte en central tjänst. Ni behöver en godkänd
HTTPS-mottagare med autentisering, åtkomstkontroll, lagring, retention och
dashboard/export. Intune distribuerar och schemalägger klienten, men tar inte
emot HTML/JSON-rapporter automatiskt.

```text
Windows-klient (SYSTEM)
  -> lokal skyddad HTML/JSON
  -> valfri POST HTTPS med bearer-token
  -> er mottagare/databas/dashboard
```

Ingen publik tjänst anropas av standardkörningen. Microsofts symbolserver
kontaktas endast om `AllowSymbolDownload` uttryckligen aktiveras för cdb.

## Konfigurera installerad agent

Konfiguration är separat från Intune-paketet. Leverera en **skrivbegränsad,
roterbar klienttoken** och ett kundspecifikt slumpmässigt identity salt via er
godkända hemlighetshantering till konfigurationsprocessens miljövariabler:

- `CRASHLOG_REPORT_TOKEN`
- `CRASHLOG_IDENTITY_SALT` (minst 16 tecken, rekommenderat minst 32 slumpmässiga byte)

Skriv aldrig värdena i repo, installationskommando, Intune-skript med klartext,
logg eller incheckad konfigurationsfil. Mekanismen som levererar hemligheterna
ingår inte; välj den enligt kundens policy. Miljövariabler används bara för
överlämningen, inte som permanent maskinlagring.

Kör som administratör/SYSTEM efter installation:

```powershell
# Miljövariablerna har satts i denna process av er hemlighetshantering.
& "$env:ProgramData\CrashlogDetector\Agent\Set-ReportingConfiguration.ps1" `
  -ReportEndpoint 'https://diagnostics.example.org/api/reports'
Start-ScheduledTask -TaskName CrashlogDetector-Daily
```

Adress ovan är en **platshållare**, inte en fungerande mottagare.
Inställningen krypteras med Windows DPAPI LocalMachine och skyddas av katalogens
ACL (endast SYSTEM/administratörer). Lokala administratörer kan fortfarande
dekryptera; detta är ingen isolering mot en komprometterad klient. Undvik en token
som ger läs-/administrationsåtkomst eller åtkomst till andra kunders data.

```powershell
& "$env:ProgramData\CrashlogDetector\Agent\Set-ReportingConfiguration.ps1" -Disable
```

Ändringar gäller nästa körning. Konfigurera helst när tasken inte körs.
Vid direkt körning av `src/Invoke-CrashlogDiagnostics.ps1` kan samma
processmiljövariabler användas med `-ReportEndpoint`.

## Mottagarens kontrakt

`POST <ReportEndpoint>` med UTF-8 JSON, `Authorization: Bearer <token>` och
`Idempotency-Key: <ReportId>`. Bara HTTPS utan URL-credentials, query eller
fragment accepteras. Redirects följs inte, TLS-certifikat måste vara giltigt och
TLS 1.2 är tillåtet. Timeout är 60 sekunder.

Mottagaren ska validera schema och token samt returnera **2xx först efter
varaktig lagring**. Deduplicera på `ReportId`. Begränsa payloadstorlek och
förfrågningsfrekvens; anta inte att klientens diagnostikfält är betrodda.
Dashboard måste också HTML-escapa all data.

| Fält | Innehåll |
| --- | --- |
| `SchemaVersion` | `1` |
| `ReportId` | Unikt UUID för körningen |
| `DeviceId` | SHA-256 av kundsalt + maskinens MachineGuid; varken datornamn eller rå GUID skickas |
| `AgentVersion`, `GeneratedUtc`, `LookbackDays`, `Status` | Version, UTC-tid, tidsfönster, `Complete`/`Partial` |
| `System` | Tillverkare, modell, Windows-version/build och BIOS-version; null vid insamlingsfel |
| `Bugchecks` | Array med UTC-tid, händelse-ID och stopkod; händelser är inte deduplicerade krascher |
| `DumpAnalysis` | Array med UTC-filändringstid, modul, image, bucket, stopkod och symbolvarningsflagga |
| `DriverVersions` | Unika leverantör/version/datum/INF/signering från PnP-inventering |
| `FindingIds` | Regel-ID, prioritet och evidensstyrka; inga råa evidenstexter |
| `FailedCollectors` | Namnen på insamlingar som misslyckades |

`DriverVersions` saknar enhets-ID/namn och är inte en garanterad direktmappning
från dumpmodul till drivrutinspaket. Vid misstänkt modul verifieras leverantör,
filversion, stack och INF lokalt eller i ert godkända inventariesystem.
Modell/BIOS + jämförbar drivrutinsinventering ger stöd för jämförelse mellan
drabbade och friska klienter. Hårdvaruhändelsernas råtext skickas inte; använd
lokala rapporter för WHEA-/diskdetaljer.

Ingen dumpfil, datornamn, serienummer, full dump-sökväg, rå händelsetext,
enhetsinstans-ID eller DISM/SFC-output skickas. Pseudonymisering är **inte**
anonymisering: tekniska metadata kan fortfarande identifiera en dator i en
liten grupp. Saltbyte/ominstallation av Windows kan ändra `DeviceId`.

Uppladdning görs **en gång per körning**, utan offlinekö eller automatisk retry.
En misslyckad uppladdning sparas lokalt och ger exitkod 3. Nästa schemalagda
körning skapar en ny rapport med ett nytt ID och samma tillbakablicksfönster;
den skickar inte automatiskt gammal historik. Schemaläggaren visar last result,
men agenten notifierar inte IT separat. Bevaka uteblivna/för gamla rapporter
och `Partial`/`FailedCollectors` i mottagaren.

## Hantera kunddata

Lokala rapporter innehåller datornamn, hårdvaru-/drivrutinsinventering,
händelsetexter och sökvägar. Dumpar kan innehålla mycket känsligare minnesdata,
inklusive personuppgifter och hemligheter. Agenten inventerar/läser dumpar vid
lokal cdb-analys men kopierar eller laddar inte upp dem.

Använd kundens godkända hantering för supportöverföring, minimera åtkomst och
bestäm retention innan pilot. Kryptera enheterna och serverlagringen enligt
policy. Intune-installationens standardretention är 14 historiska körningar
plus Latest; direktkörning sparar bara Latest. Symbolcache har ingen automatisk
storleksgräns. Avinstallation bevarar rapporter om inte `RemoveReports` anges.
