# Exchange MoveRequest Dashboard

[![GitLab Project](https://img.shields.io/badge/GitLab-Project-FC6D26?logo=gitlab&logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard)
[![License: MIT](https://img.shields.io/badge/License-MIT-4c1?logo=opensourceinitiative&logoColor=white)](LICENSE)
[![Version 2.16](https://img.shields.io/badge/Version-2.16-007ec6)](CHANGELOG.md)
[![Last Commit](https://img.shields.io/gitlab/last-commit/RoccoAmmon/Exchange-MoveRequest-Dashboard)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/commits/main)
[![Status: stable](https://img.shields.io/badge/Status-stable-brightgreen)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Architektur)
[![Language: DE/EN](https://img.shields.io/badge/Language-DE%2FEN-005BBB?logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/home)
<br>
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)
[![Exchange Server 2019 + SE](https://img.shields.io/badge/Exchange%20Server-2019%20%2B%20SE-0078D4)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)
[![Windows Server](https://img.shields.io/badge/Platform-Windows%20Server-0078D6?logo=windows&logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)
[![Admin rights required](https://img.shields.io/badge/Admin%20rights-required-orange)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Fehlerbehebung)
[![Readable in 5 minutes](https://img.shields.io/badge/README-Readable%20in%205%20Minutes-lightgrey)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)

![GUI of Exchange-MoveRequest-Dashboard with status tiles, move request form, and live table of MoveRequests](docs/gui-screenshot.png)

> **DE:** Die Web-Oberfläche des Dashboards – oben die Statuskacheln, mittig das Formular **„Neue Verschiebeanforderung"**, darunter die Live-Tabelle aller MoveRequests (aktive Jobs oben, suspendierte mit **„Abschließen"**-Button und Mehrfachauswahl). Die Aufnahme stammt aus einer Testfassung ohne Exchange-Anbindung und zeigt **Beispieldaten** – Servername, Postfächer und Zeiten sind frei erfunden. Die Testfassung läuft bewusst mit der Vorversion **v2.15** und zeigt deshalb das Update-Badge „Update verfügbar: v2.16" auf die im Badge oben versionierte aktuelle Veröffentlichung. In der Live-Umgebung aktualisiert sich die Seite automatisch (Standard-Intervall 10 s, ohne Seiten-Reload).
>
> **EN:** The dashboard's web UI – status tiles on top, the **"New move request"** form in the middle, and the live table of all move requests below (active jobs first, suspended ones with a **"Complete"** button and multi-selection). The screenshot was taken from a test build without an Exchange connection and shows **sample data** – server name, mailboxes and timestamps are fictional. The test build deliberately runs the previous version **v2.15**, which is why the update badge "Update available: v2.16" points to the current release shown in the badge above. In a live environment the page refreshes automatically (default interval 10 s, no page reload).

---

## 📋 Features / Funktionen

| Bereich / Area | DE – Was es kann | EN – What it does |
|---|---|---|
| **Live-Statistik / Live Statistics** | Tabelle aller MoveRequests, aktualisiert per AJAX alle X Sekunden – **ohne** Seiten-Reload | Table of all MoveRequests, updated via AJAX every X seconds – **no** page reload |
| **Aktive Jobs zuerst / Active Jobs First** | `InProgress`, `CompletionInProgress` und `Queued` stehen immer oben, abgeschlossene/fehlgeschlagene darunter | `InProgress`, `CompletionInProgress`, and `Queued` always on top, completed/failed below |
| **Neue Verschiebung / New Move** | Postfächer einer Quell-Datenbank auswählen, Quelle/Ziel wählen, mit `New-MoveRequest` starten (eigener Hintergrund-Job, GUI bleibt bedienbar) | Select mailboxes from a source DB, pick source/target, start with `New-MoveRequest` (background job, GUI stays responsive) |
| **Sonderpostfächer / Special Mailboxes** | Eigenes Auswahlfeld **Postfachart**: *Benutzerpostfächer* / *Sonderpostfächer* / *Alle*. Zu den Sonderpostfächern zählen **Arbitration, AuditLog, AuxAuditLog, öffentliche Postfächer, Archiv**, SystemMailbox, Migration und Discovery – diese waren vorher komplett ausgefiltert und lassen sich nun getrennt anzeigen, auswählen und verschieben (Health-/Monitoring-Postfächer bleiben verborgen). Jeder Eintrag trägt seine Art als Markierung, Postfächer ohne eigene SMTP-Adresse werden über Alias bzw. DN identifiziert | Dedicated **Mailbox type** selector: *User mailboxes* / *Special mailboxes* / *All*. Special mailboxes include **Arbitration, AuditLog, AuxAuditLog, PublicFolder, Archive**, SystemMailbox, Migration, and Discovery – previously completely filtered out, now separately displayable, selectable, and movable (Health/Monitoring mailboxes stay hidden). Each entry shows its type as a badge; mailboxes without their own SMTP address are identified via Alias or DN |
| **Suspendierte fortsetzen / Resume Suspended** | Button **„Abschließen"** direkt hinter jeder suspendierten Tabellenzeile (einzelne Anforderung), **Mehrfachauswahl** mit Häkchen + „Auswahl abschließen" (ein Auftrag für die ganze Auswahl), zusätzlich pro Batch und global: `Resume-MoveRequest` als Hintergrund-Job, Fortschritt über `/api/move-status` | **„Complete"** button right behind each suspended table row (single request), **multi-select** with checkboxes + „Complete selection" (one job for the whole selection), plus per-batch and global: `Resume-MoveRequest` as background job, progress via `/api/move-status` |
| **Abgeschlossene löschen / Delete Completed** | Pro Auftrag und global: `Remove-MoveRequest` – räumt nur die MoveRequests auf, die Postfächer bleiben unberührt | Per job and globally: `Remove-MoveRequest` – cleans up only the MoveRequests, mailboxes stay untouched |
| **Vorabtest / Pretest** | `New-MoveRequest -WhatIf` vor dem eigentlichen Start (aus / erst prüfen dann verschieben / nur prüfen) | `New-MoveRequest -WhatIf` before actual start (off / check then move / check only) |
| **Priorität & BadItemLimit / Priority & BadItemLimit** | Auswahl in der GUI, werden direkt an `New-MoveRequest` übergeben | Selection in GUI, passed directly to `New-MoveRequest` |
| **Stabil bei Last / Stable under Load** | Snapshot-Cache, Stats-Cache, parallele Statistikabrufe, gedämmptes Log-Rotation – siehe [Stabilitätskern](#stabilitätskern-v20) | Snapshot cache, stats cache, parallel stats fetches, throttled log rotation – see [Stability Core](#stability-core-v20) |
| **Update-Check** | Prüft beim Start asynchron gegen die GitLab-Releases-API und zeigt bei neuerer Version ein klickbares **Update-Badge** im Kopf (plus Log-Hinweis). Abschaltbar mit `-KeinUpdateCheck` | Checks at start asynchronously against GitLab Releases API, shows clickable **Update badge** in header (plus log hint) if newer version. Disable with `-KeinUpdateCheck` |
| **Zweite Instanz / Second Instance** | Läuft auf dem Ziel-Port schon ein Dashboard, wird diese **beim Start automatisch beendet** (sauber über `/api/stop`, sonst `Stop-Process`) – Abschaltbar mit `-KeinAutoStopp`. Geprüft wird **zweimal**: einmal früh beim Start und noch einmal unmittelbar **vor** `$Listener.Start()`; nach Fehler 32 wird einmal nachgelegt | If a dashboard already runs on the target port, it is **automatically stopped at start** (cleanly via `/api/stop`, else `Stop-Process`) – disable with `-KeinAutoStopp`. Checked **twice**: early at start and again **right before** `$Listener.Start()`; after error 32 one retry |
| **Light-Modus / Light Mode** | `-Light` (Alias `-NurStatus`): nur Anzeigename, Status, Quell-/Ziel-DB und Batch – `Get-MoveRequestStatistics` bleibt komplett aus, die technischen Spalten sind ausgeblendet. Deutlich schneller bei vielen hundert Verschiebeanforderungen | `-Light` (alias `-NurStatus`): only display name, status, source/target DB and batch – `Get-MoveRequestStatistics` stays off entirely, technical columns hidden. Much faster with hundreds of move requests |
| **Filter** | Auf einen Move-Batch eingeschränkt starten (`-BatchName`), Quell-/Ziel-Datenbank frei wählbar | Filter to a single move batch (`-BatchName`), source/target DB freely selectable |

---

## ✅ Voraussetzungen / Prerequisites

| DE | EN |
|---|---|
| **Exchange Server 2019 oder Exchange SE (Subscription Edition), On-Premises** (Management-Tools / Exchange Management Shell verfügbar) | **Exchange Server 2019 or Exchange SE (Subscription Edition), On-Premises** (Management Tools / Exchange Management Shell available) |
| **Windows PowerShell 5.1** (skriptiert aus der Exchange Management Shell) | **Windows PowerShell 5.1** (scripted from the Exchange Management Shell) |
| Ausführung **als Administrator** – `System.Net.HttpListener` benötigt HTTP-Reservierungsrechte; startet das Skript ohne Admin-Rechte, hebt es sich selbst per UAC an (seit v2.14) | Run **as Administrator** – `System.Net.HttpListener` needs HTTP reservation rights; if started without admin rights, script self-elevates via UAC (since v2.14) |
| Netzwerkzugriff auf den Exchange-Server (Localhost reicht, wenn das Skript auf dem Exchange läuft) | Network access to the Exchange server (localhost sufficient if script runs on Exchange) |

---

## 🚀 Schnellstart / Quick Start

```powershell
# DE: In einer *administrativen* Exchange Management Shell:
# EN: In an *administrative* Exchange Management Shell:
git clone https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard.git
cd Exchange-MoveRequest-Dashboard

.\Exchange-MoveRequest-Dashboard.ps1
# -> Browser öffnet http://localhost:8585/ / Browser opens http://localhost:8585/
```

Dashboard beenden: Schalter **„Server stoppen"** in der GUI oder `GET http://localhost:8585/api/stop`.  
Stop dashboard: **„Stop server"** button in the GUI or `GET http://localhost:8585/api/stop`.

### Häufige Aufrufe / Common Invocations

```powershell
# Anderer Port, kürzeres Aktualisierungsintervall / Different port, shorter refresh interval
.\Exchange-MoveRequest-Dashboard.ps1 -Port 9090 -AktualisierungsIntervall 15

# Nur einen Move-Batch auswerten / Evaluate only a single move batch
.\Exchange-MoveRequest-Dashboard.ps1 -BatchName "MBX2026Q1"

# Sehr viele laufende Jobs: mehr parallele Detailabfragen, begrenzte Abfragen je Lauf
# Very many running jobs: more parallel detail fetches, limited fetches per run
.\Exchange-MoveRequest-Dashboard.ps1 -Parallelitaet 8 -MaxDetailAbrufe 100

# Ohne Browserstart (z. B. für Remote-Sessions) / No browser launch (e.g. for remote sessions)
.\Exchange-MoveRequest-Dashboard.ps1 -KeinBrowser

# Light-Modus: nur der Status der Verschiebeanforderungen, ohne technische Werte
# Light mode: only move request status, no technical values
.\Exchange-MoveRequest-Dashboard.ps1 -Light

# Sprache explizit setzen (Auto = OS-Sprache) / Explicitly set language (Auto = OS language)
.\Exchange-MoveRequest-Dashboard.ps1 -Sprache de
.\Exchange-MoveRequest-Dashboard.ps1 -Sprache en
```

---

## ⚙️ Parameter

| Parameter | Standard | DE – Beschreibung | EN – Description |
|---|---:|---|---|
| `-Port` | `8585` | Port des lokalen Webservers | Local web server port |
| `-AktualisierungsIntervall` | `10` | Sekunden zwischen zwei Polling-Läufen im Browser | Seconds between browser polling runs |
| `-CacheIntervall` | `5` | Sekunden, für die ein Snapshot ohne neue Exchange-Abfrage ausgeliefert wird | Seconds a snapshot is served without new Exchange query |
| `-AbfrageTimeout` | `300` | Sekunden, nach denen der Browser einen `/api/data`-Request abbricht | Seconds after which browser aborts a `/api/data` request |
| `-LeerlaufIntervall` | `60` | Sekunden zwischen zwei Sammlungen, wenn keine aktiven Jobs mehr laufen | Seconds between collections when no active jobs run |
| `-BatchName` | `""` | Filter auf einen Move-Batch | Filter to a single move batch |
| `-Parallelitaet` | `4` | Anzahl paralleler `Get-MoveRequestStatistics`-Abrufe (`1` = sequenziell) | Number of parallel `Get-MoveRequestStatistics` fetches (`1` = sequential) |
| `-MaxDetailAbrufe` | `0` | Max. Statistikabrufe pro Sammlung, `0` = unbegrenzt | Max stats fetches per collection, `0` = unlimited |
| `-KeinBrowser` | aus | Browser nicht automatisch öffnen | Don't open browser automatically |
| `-KeinAutoStopp` | aus | Andere Instanz auf demselben Port **nicht** automatisch beenden | Don't auto-stop other instance on same port |
| `-Light` | aus | Light-Modus (Alias `-NurStatus`): nur Status, Name, Quell-/Ziel-DB und Batch – keine Statistikabrufe, technische Spalten ausgeblendet | Light mode (alias `-NurStatus`): only status, name, source/target DB and batch – no stats fetches, technical columns hidden |
| `-KeinUpdateCheck` | aus | Update-Check gegen die GitLab-Releases-API unterdrücken (Airgap/Offline); Fehler und Offline-Zustände bleiben folgenlos | Suppress update check against GitLab Releases API (airgap/offline); errors and offline states stay harmless |
| `-Sprache` / `-Language` | `Auto` | Sprache der Oberfläche: `Auto` (OS), `de` oder `en` | UI language: `Auto` (OS), `de` or `en` |

---

## 🌐 API-Routen / API Routes

| Route | Method | DE – Zweck | EN – Purpose |
|---|---|---|---|
| `/` | GET | Liefert die HTML-Dashboard-Seite (einmalig laden) | Returns HTML dashboard page (load once) |
| `/api/data` | GET | Aktuelle MoveRequest-Daten als JSON (gepollt) | Current MoveRequest data as JSON (polled) |
| `/api/databases` | GET | Alle Postfachdatenbanken (Quell-/Ziel-Auswahl) | All mailbox databases (source/target selection) |
| `/api/benutzer` | GET | Postfächer (`?quelle=NAME`, `?typ=` mit `benutzer` / `sonder` / `alle` / `archiv` für Postfachart; ohne Parameter alle Benutzerpostfächer aller Datenbanken) | Mailboxes (`?quelle=NAME`, `?typ=` with `benutzer` / `sonder` / `alle` / `archiv` for mailbox type; without params all user mailboxes of all DBs) |
| `/api/move` | POST | Erstellt Verschiebeanforderungen (JSON: Quelle, Ziel, Benutzer, Suspend, Prioritaet, Vorabtest, BadItemLimit) | Creates move requests (JSON: Quelle, Ziel, Benutzer, Suspend, Prioritaet, Vorabtest, BadItemLimit) |
| `/api/move-status` | GET | Status und Ergebnisse gestarteter Verschiebeaufträge | Status and results of started move jobs |
| `/api/move-aktion` | POST | Suspendierte fortsetzen oder abgeschlossene löschen (JSON: Aktion, BatchName, Alle, Identity bzw. Identities) | Resume suspended or delete completed (JSON: Aktion, BatchName, Alle, Identity or Identities) |
| `/api/stop` | GET | Stoppt den Webserver sauber | Stops the web server cleanly |

---

## 🛡️ Stabilitätskern (v2.0) / Stability Core (v2.0)

Die folgenden Punkte verhindern den Totalausfall nach wenigen Minuten, der bei vielen Jobs zuvor auftrat:  
The following points prevent the total crash after a few minutes that previously occurred with many jobs:

1. **Sammlungs-Cache / Collection Cache** – überlappende Requests bekommen sofort den letzten Snapshot statt die Exchange-Sammlung erneut anzufragen (19 s → 0,03 s).  
   Overlapping requests get the last snapshot immediately instead of re-querying Exchange collection (19 s → 0.03 s).

2. **Stats-Cache** – `Get-MoveRequestStatistics` wird nur noch für *aktive* Jobs aufgerufen, abgeschlossene/fehlgeschlagene kommen aus dem Cache (235 → 188 Abrufe pro Sammlung).  
   `Get-MoveRequestStatistics` called only for *active* jobs; completed/failed come from cache (235 → 188 fetches per collection).

3. **Kein Connection-Leak / No Connection Leak** – `Response.OutputStream.Close()` läuft in einem `finally`; ohne das leckte jeder fehlgeschlagene Request eine TCP-Verbindung (Port dicht nach ~10 min).  
   `Response.OutputStream.Close()` runs in a `finally`; without it each failed request leaked a TCP connection (port stuck after ~10 min).

4. **Selbstkorrigierendes Polling / Self-correcting Polling** – `setTimeout`-Kette mit `AbortController` statt `setInterval`; der Browser stapelt keine Requests, wenn der Server langsam ist.  
   `setTimeout` chain with `AbortController` instead of `setInterval`; browser doesn't stack requests when server is slow.

5. **Gedämmptes Logging / Throttled Logging** – dauerhaft offener `StreamWriter`, Rate-Limiting, Rotation ab 10 MB (5 Generationen).  
   Permanently open `StreamWriter`, rate limiting, rotation at 10 MB (5 generations).

6. **Stale-Snapshot** – schlägt eine Sammlung fehl, wird der letzte bekannte Stand mit Fehlerbanner ausgeliefert statt „Keine MoveRequests vorhanden".  
   If a collection fails, last known state is delivered with error banner instead of "No MoveRequests found".

---

## 📝 Logging

| | DE | EN |
|---|---|---|
| **Verzeichnis / Directory** | `C:\ExchangeMigrationLog` | `C:\ExchangeMigrationLog` |
| **Datei / File** | `LiveDashboard_<Zeitstempel>.log` | `LiveDashboard_<timestamp>.log` |
| **Rotation** | ab 10 MB, 5 Generationen werden behalten | from 10 MB, 5 generations kept |
| **Rate-Limit** | identische Meldungen werden innerhalb von 5 Minuten nur gezählt | identical messages counted only within 5 minutes |

---

## ❓ Häufige Probleme / Common Issues

### `maxenvelopesizekb`-Fehler bei `Get-MoveRequestStatistics`
**DE:** In der Exchange Management Shell ausführen und das Skript neu starten:  
**EN:** Run in Exchange Management Shell and restart script:

```powershell
Set-PowerShellConfig -Identity WSMan:localhost -MaxEnvelopeSizeKb 16384
```

Das Skript ist auch ohne diesen Wert lauffähig, da abgeschlossene Jobs nicht mehr abgefragt werden.  
The script works without this value too, since completed jobs are no longer queried.

---

### **„Zugriff verweigert" / `HttpListenerException` beim Start / at Start**
**DE:** Skript muss in einer *administrativen* Shell laufen (HTTP-Reservierung).  
**EN:** Script must run in an *administrative* shell (HTTP reservation).

---

### **Fehler 32 beim Start – „… da sie von einem anderen Prozess verwendet wird" / Error 32 at Start**
**DE:** Nicht der TCP-Port ist belegt, sondern die **URL-Präfix-Registrierung** `http://localhost:8585/` von `http.sys`. Verursacht durch ein zweites Dashboard – auch die alte Version `live_moverequest_statistik.ps1` reserviert denselben Port. Wichtig: **danach** ist der Port sofort wieder frei, ein `netstat`-Check nach dem Fehler findet deshalb nichts mehr.

**EN:** It's not the TCP port that's occupied, but the **URL prefix registration** `http://localhost:8585/` in `http.sys`. Caused by a second dashboard – even the old version `live_moverequest_statistik.ps1` reserves the same port. Important: **afterwards** the port is immediately free again, so a `netstat` check after the error finds nothing.

```powershell
# DE: laufende Instanzen suchen (nur zum Fehlerzeitpunkt aussagekräftig)
# EN: find running instances (only meaningful at error time)
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -match 'Moverequest-Dashboard|live_moverequest_statistik' } |
    Select-Object ProcessId, CommandLine

# DE: oder einfach mit abweichendem Port starten
# EN: or just start with a different port
.\Exchange-MoveRequest-Dashboard.ps1 -Port 9090
```

Seit **v2.5** schreibt das Skript genau diese Daten (laufende Instanzen, Port-Listener, `netsh`-Reservierungen) automatisch ins Log, sobald der Start scheitert.  
Since **v2.5** the script automatically writes exactly this data (running instances, port listeners, `netsh` reservations) to the log when start fails.

Seit **v2.6** wird eine auf dem Ziel-Port laufende Instanz **vor** dem Start automatisch beendet – zuerst per HTTP geprüft (das findet auch eine in einer offenen Konsole gestartete Instanz, deren Prozess die Skriptdatei nicht in der Kommandozeile trägt), dann sauber über deren `/api/stop`, im Notfall per `Stop-Process`. Mit `-KeinAutoStopp` ist das deaktiviert.  
Since **v2.6** a running instance on the target port is **automatically stopped before start** – first HTTP-checked (finds even an instance started in an open console whose process doesn't carry the script file in its command line), then cleanly via its `/api/stop`, in emergency via `Stop-Process`. Disabled with `-KeinAutoStopp`.

**Seit v2.8 / Since v2.8** wird die Prüfung **zweimal** ausgeführt: beim Start und noch einmal unmittelbar **vor** `$Listener.Start()`. Dazwischen liegen Snap-In und erste Sammlung (rund 11 Sekunden) – genau in diesem Fenster konnte sich eine zweite Instanz das URL-Praefix schnappen, worauf der Start mit Fehler 32 scheiterte. Schlägt der Start trotzdem mit einem Präfix-Konflikt fehl, wird **einmal nachgelegt** (höchstens 3 Versuche, ohne `Ping-Pong` zwischen zwei Instanzen).  
The check runs **twice**: at start and again **right before** `$Listener.Start()`. Between them lie snap-in and first collection (~11 seconds) – exactly this window let a second instance grab the URL prefix, causing error 32. If start still fails with prefix conflict, **one retry** is made (max 3 attempts, no `ping-pong` between two instances).

---

### **Warnung „HTTP-Listener Fehler … Netzwerkname ist nicht mehr verfügbar" beim Stoppen / Warning when stopping**
**DE:** Kein Fehler: Der Klick auf **„Server stoppen"** bricht die gerade laufende Browser-Anfrage ab, während das Skript in deren Response-Stream schreibt – der Server fährt trotzdem sauber herunter (`Server-Stop angefordert` → `HTTP-Server sauber heruntergefahren`). Seit **v2.9** erkennt das Skript solche Client-Abbrüche und schreibt stattdessen eine harmlose `[STILL]`-Zeile mit verständlichem Text – nur in die Datei, nicht auf die Konsole. Echte Listener-Fehler (etwa „Zugriff verweigert") bleiben eine WARNUNG.

**EN:** Not an error: Clicking **„Stop server"** aborts the currently running browser request while the script writes to its response stream – the server still shuts down cleanly (`Server-Stop requested` → `HTTP-Server shut down cleanly`). Since **v2.9** the script detects such client aborts and writes a harmless `[STILL]` line with understandable text – file only, not console. Real listener errors (e.g. "Access denied") remain a WARNING.

---

### **Dashboard lädt, aber die Tabelle bleibt leer / Dashboard loads but table stays empty**
**DE:** Prüfen, ob überhaupt MoveRequests existieren (`Get-MoveRequest`) und ob der Exchange-Management-Zugriff aus der Shell funktioniert. Fehlermeldungen stehen im Log unter `C:\ExchangeMigrationLog`.

**EN:** Check if any MoveRequests exist (`Get-MoveRequest`) and if Exchange management access works from the shell. Error messages are in the log under `C:\ExchangeMigrationLog`.

---

Weitere Details im [Wiki](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/home) / More details in the [Wiki](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/home).

---

## 📦 Versionen / Versions

Alle Änderungen siehe [CHANGELOG.md](CHANGELOG.md). / All changes see [CHANGELOG.md](CHANGELOG.md).

| Version | DE – Schwerpunkt | EN – Focus |
|---|---|---|
| 2.16 | **Zweisprachig (DE/EN)**: OS-Erkennung, Umschalter in GUI, Cookie, alle Meldungen lokalisiert | **Bilingual (DE/EN)**: OS detection, GUI switcher, cookie, all messages localized |
| 2.15 | **Update-Check** gegen die GitLab-Releases-API: asynchron per Runspace, klickbares Update-Badge in der Web-Oberfläche, Log-Hinweis, Schalter `-KeinUpdateCheck` | **Update Check** against GitLab Releases API: async via Runspace, clickable update badge in web UI, log hint, switch `-KeinUpdateCheck` |
| 2.14 | **Selbst-Elevation**: ohne Admin-Rechte startet das Skript sich automatisch mit UAC elevated neu (alle Parameter bleiben erhalten); bei Ablehnung Log-Warnung und Hinweisdialog | **Self-Elevation**: without admin rights script auto-restarts elevated via UAC (all params preserved); on decline log warning and info dialog |
| 2.13 | Fehlgeschlagene Verschiebungen nennen Ausführungskontext (Konto, Administrator-Status, PowerShell), Exception-Details und einen Handlungshinweis („Zugriff wurde verweigert") | Failed moves report execution context (account, admin status, PowerShell), exception details, and action hint ("Access denied") |
| 2.12 | System-/Arbitration-Postfächer über eigene `Get-Mailbox`-Schalter abrufen (vorher in der Sonderliste ausgeblendet) – dazu die Ansicht „Postfächer mit Archiv" | System/Arbitration mailboxes via dedicated `Get-Mailbox` switches (previously hidden in special list) – plus "Mailboxes with Archive" view |
| 2.11 | Versionsnummer in der Web-Oberfläche (Marke im Kopf, Seitentitel, Fußzeile) – aus dem `.NOTES`-Block gelesen | Version number in web UI (badge in header, page title, footer) – read from `.NOTES` block |
| 2.10 | Sonderpostfächer (Arbitration, AuditLog, AuxAuditLog, öffentliche Postfächer, Archiv) separat anzeigen, auswählen und verschieben | Special mailboxes (Arbitration, AuditLog, AuxAuditLog, PublicFolder, Archive) separately displayable, selectable, movable |
| 2.9 | Beim Stoppen über die Seite keine Fehlwarnung mehr – Browser-Abbruch gilt nicht als Listener-Fehler | No more false warning when stopping via page – browser abort not treated as listener error |
| 2.8 | Fehler 32 behoben (Prüfung direkt vor `$Listener.Start()` + ein Nachlegen), Light-Modus `-Light` | Error 32 fixed (check right before `$Listener.Start()` + one retry), Light mode `-Light` |
| 2.7 | Mehrfachauswahl suspendierter Anforderungen – auswählen und mit einem Klick abschließen (`Identities`) | Multi-select suspended requests – select and complete with one click (`Identities`) |
| 2.6 | Zweite Instanz auf demselben Port wird beim Start automatisch beendet (Fehler 32 vorab), `-KeinAutoStopp` | Second instance on same port auto-stopped at start (error 32 pre-empted), `-KeinAutoStopp` |
| 2.5 | Diagnose beim Startfehler: zweite Instanz, Port-Listener und URL-Reservierungen im Fehlerfall | Diagnostics on start failure: second instance, port listeners, URL reservations at error time |
| 2.4 | Button „Abschließen" pro suspendierter Anforderung, Einzelziel über `Identity` | "Complete" button per suspended request, single target via `Identity` |
| 2.3 | Schneller Erstablauf, parallele Statistikabrufe (Runspace-Pool), `-MaxDetailAbrufe` | Faster initial run, parallel stats fetches (Runspace pool), `-MaxDetailAbrufe` |
| 2.2 | WebGUI „Neue Verschiebeanforderung", Suspendierte fortsetzen, Abgeschlossene löschen, Vorabtest | WebGUI "New Move Request", resume suspended, delete completed, pretest |
| 2.1 | Cache-Schlüssel korrigiert, Größenangaben in MB/GB, UTF-8 mit BOM | Cache key fixed, sizes in MB/GB, UTF-8 with BOM |
| 2.0 | Stabilitätskern: Caches, Leck-Fix, selbstkorrigierendes Polling, Log-Rotation | Stability core: caches, leak fix, self-correcting polling, log rotation |
| 1.0 | Initiale Version | Initial version |

---

## 🤝 Mitwirken / Contributing

**DE:** Issues und Merge Requests sind willkommen – am besten mit  
**EN:** Issues and Merge Requests welcome – preferably with

- Exchange-Version und PowerShell-Version / Exchange version and PowerShell version
- Anzahl der gleichzeitigen MoveRequests / Number of concurrent MoveRequests
- Auszug aus dem Log unter `C:\ExchangeMigrationLog` / Excerpt from log at `C:\ExchangeMigrationLog`

---

## 📄 Lizenz / License

[MIT](LICENSE) – © 2026 Rocco Ammon