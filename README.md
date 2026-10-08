# Exchange MoveRequest Dashboard

[![GitLab-Projekt](https://img.shields.io/badge/GitLab-Projekt-FC6D26?logo=gitlab&logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard)
[![Lizenz: MIT](https://img.shields.io/badge/Lizenz-MIT-4c1?logo=opensourceinitiative&logoColor=white)](LICENSE)
[![Version 2.5](https://img.shields.io/badge/Version-2.5-007ec6)](CHANGELOG.md)
[![Letzter Commit](https://img.shields.io/gitlab/last-commit/RoccoAmmon/Exchange-MoveRequest-Dashboard)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/commits/main)
[![Status: stabil](https://img.shields.io/badge/Status-stabil-brightgreen)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Architektur)
[![Sprache: Deutsch](https://img.shields.io/badge/Sprache-Deutsch-005BBB?logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/home)
<br>
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE?logo=powershell&logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)
[![Exchange Server 2019](https://img.shields.io/badge/Exchange%20Server-2019-0078D4)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)
[![Windows Server](https://img.shields.io/badge/Platform-Windows%20Server-0078D6?logo=windows&logoColor=white)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)
[![Adminrechte erforderlich](https://img.shields.io/badge/Adminrechte-erforderlich-orange)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Fehlerbehebung)
[![Lesbar in 5 Minuten](https://img.shields.io/badge/README-Lesbar%20in%205%20Minuten-lightgrey)](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/Installation)

**Live-Dashboard für Exchange Server MoveRequests** – ein einzelnes PowerShell-Skript startet einen lokalen
Mini-Webserver und zeigt in Echtzeit den Status aller Postfachverschiebungen an. Neu und abgeschlossene
Verschiebeanforderungen lassen sich direkt aus der Web-GUI starten, fortsetzen und aufräumen.

> 🖥️ Öffnet sich automatisch im Browser auf `http://localhost:8585/` · Autor: **Rocco Ammon**

---

## Features

| Bereich | Was es kann |
|---|---|
| **Live-Statistik** | Tabelle aller MoveRequests, aktualisiert per AJAX alle X Sekunden – **ohne** Seiten-Reload |
| **Aktive Jobs zuerst** | `InProgress`, `CompletionInProgress` und `Queued` stehen immer oben, abgeschlossene/fehlgeschlagene darunter |
| **Neue Verschiebung** | Postfächer einer Quell-Datenbank auswählen, Quelle/Ziel wählen, mit `New-MoveRequest` starten (eigener Hintergrund-Job, GUI bleibt bedienbar) |
| **Suspendierte fortsetzen** | Button **„Abschließen"** direkt hinter jeder suspendierten Tabellenzeile (einzelne Anforderung), zusätzlich pro Batch und global: `Resume-MoveRequest` als Hintergrund-Job, Fortschritt über `/api/move-status` |
| **Abgeschlossene löschen** | Pro Auftrag und global: `Remove-MoveRequest` – räumt nur die MoveRequests auf, die Postfächer bleiben unberührt |
| **Vorabtest** | `New-MoveRequest -WhatIf` vor dem eigentlichen Start (aus / erst prüfen dann verschieben / nur prüfen) |
| **Priorität & BadItemLimit** | Auswahl in der GUI, werden direkt an `New-MoveRequest` übergeben |
| **Stabil bei Last** | Snapshot-Cache, Stats-Cache, parallele Statistikabrufe, gedämmptes Log-Rotation – siehe [Stabilitätskern](#stabilitätskern-v20) |
| **Filter** | Auf einen Move-Batch eingeschränkt starten (`-BatchName`), Quell-/Ziel-Datenbank frei wählbar |

## Voraussetzungen

- **Exchange Server 2019 On-Premises** (Management-Tools / Exchange Management Shell verfügbar)
- **Windows PowerShell 5.1** (skriptiert aus der Exchange Management Shell)
- Ausführung **als Administrator** – `System.Net.HttpListener` benötigt HTTP-Reservierungsrechte
- Netzwerkzugriff auf den Exchange-Server (Localhost reicht, wenn das Skript auf dem Exchange läuft)

## Schnellstart

```powershell
# In einer *administrativen* Exchange Management Shell:
git clone https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard.git
cd Exchange-MoveRequest-Dashboard

.\Exchange-MoveRequest-Dashboard.ps1
# -> Browser öffnet http://localhost:8585/
```

Dashboard beenden: Schalter **„Server stoppen"** in der GUI oder `GET http://localhost:8585/api/stop`.

### Häufige Aufrufe

```powershell
# Anderer Port, kürzeres Aktualisierungsintervall
.\Exchange-MoveRequest-Dashboard.ps1 -Port 9090 -AktualisierungsIntervall 15

# Nur einen Move-Batch auswerten
.\Exchange-MoveRequest-Dashboard.ps1 -BatchName "MBX2026Q1"

# Sehr viele laufende Jobs: mehr parallele Detailabfragen, begrenzte Abfragen je Lauf
.\Exchange-MoveRequest-Dashboard.ps1 -Parallelitaet 8 -MaxDetailAbrufe 100

# Ohne Browserstart (z. B. für Remote-Sessions)
.\Exchange-MoveRequest-Dashboard.ps1 -KeinBrowser
```

## Parameter

| Parameter | Standard | Beschreibung |
|---|---:|---|
| `-Port` | `8585` | Port des lokalen Webservers |
| `-AktualisierungsIntervall` | `10` | Sekunden zwischen zwei Polling-Läufen im Browser |
| `-CacheIntervall` | `5` | Sekunden, für die ein Snapshot ohne neue Exchange-Abfrage ausgeliefert wird |
| `-AbfrageTimeout` | `300` | Sekunden, nach denen der Browser einen `/api/data`-Request abbricht |
| `-LeerlaufIntervall` | `60` | Sekunden zwischen zwei Sammlungen, wenn keine aktiven Jobs mehr laufen |
| `-BatchName` | `""` | Filter auf einen Move-Batch |
| `-Parallelitaet` | `4` | Anzahl paralleler `Get-MoveRequestStatistics`-Abrufe (`1` = sequenziell) |
| `-MaxDetailAbrufe` | `0` | Max. Statistikabrufe pro Sammlung, `0` = unbegrenzt |
| `-KeinBrowser` | aus | Browser nicht automatisch öffnen |

## API-Routen

| Route | Methode | Zweck |
|---|---|---|
| `/` | GET | Liefert die HTML-Dashboard-Seite (einmalig laden) |
| `/api/data` | GET | Aktuelle MoveRequest-Daten als JSON (gepollt) |
| `/api/databases` | GET | Alle Postfachdatenbanken (Quell-/Ziel-Auswahl) |
| `/api/benutzer` | GET | Postfächer (`?quelle=NAME`; ohne Parameter alle Postfächer aller Datenbanken) |
| `/api/move` | POST | Erstellt Verschiebeanforderungen (JSON: Quelle, Ziel, Benutzer, Suspend, Prioritaet, Vorabtest, BadItemLimit) |
| `/api/move-status` | GET | Status und Ergebnisse gestarteter Verschiebeaufträge |
| `/api/move-aktion` | POST | Suspendierte fortsetzen oder abgeschlossene löschen (JSON: Aktion, BatchName, Alle) |
| `/api/stop` | GET | Stoppt den Webserver sauber |

## Stabilitätskern (v2.0)

Die folgenden Punkte verhindern den Totalausfall nach wenigen Minuten, der bei vielen Jobs zuvor auftrat:

1. **Sammlungs-Cache** – überlappende Requests bekommen sofort den letzten Snapshot statt die
   Exchange-Sammlung erneut anzufragen (19 s → 0,03 s).
2. **Stats-Cache** – `Get-MoveRequestStatistics` wird nur noch für *aktive* Jobs aufgerufen,
   abgeschlossene/fehlgeschlagene kommen aus dem Cache (235 → 188 Abrufe pro Sammlung).
3. **Kein Connection-Leak** – `Response.OutputStream.Close()` läuft in einem `finally`;
   ohne das leckte jeder fehlgeschlagene Request eine TCP-Verbindung (Port dicht nach ~10 min).
4. **Selbstkorrigierendes Polling** – `setTimeout`-Kette mit `AbortController` statt `setInterval`;
   der Browser stapelt keine Requests, wenn der Server langsam ist.
5. **Gedämmptes Logging** – dauerhaft offener `StreamWriter`, Rate-Limiting, Rotation ab 10 MB
   (5 Generationen).
6. **Stale-Snapshot** – schlägt eine Sammlung fehl, wird der letzte bekannte Stand mit
   Fehlerbanner ausgeliefert statt „Keine MoveRequests vorhanden".

## Logging

| | |
|---|---|
| Verzeichnis | `C:\ExchangeMigrationLog` |
| Datei | `LiveDashboard_<Zeitstempel>.log` |
| Rotation | ab 10 MB, 5 Generationen werden behalten |
| Rate-Limit | identische Meldungen werden innerhalb von 5 Minuten nur gezählt |

## Häufige Probleme

**`maxenvelopesizekb`-Fehler bei `Get-MoveRequestStatistics`**
In der Exchange Management Shell ausführen und das Skript neu starten:

```powershell
Set-PowerShellConfig -Identity WSMan:localhost -MaxEnvelopeSizeKb 16384
```

Das Skript ist auch ohne diesen Wert lauffähig, da abgeschlossene Jobs nicht mehr abgefragt werden.

**„Zugriff verweigert" / `HttpListenerException` beim Start**
Skript muss in einer *administrativen* Shell laufen (HTTP-Reservierung).

**Fehler 32 beim Start – „… da sie von einem anderen Prozess verwendet wird"**
Nicht der TCP-Port ist belegt, sondern die **URL-Präfix-Registrierung** `http://localhost:8585/`
von `http.sys`. Verursacht durch ein zweites Dashboard – auch die alte Version
`live_moverequest_statistik.ps1` reserviert denselben Port. Wichtig: **danach** ist der Port
sofort wieder frei, ein `netstat`-Check nach dem Fehler findet deshalb nichts mehr.

```powershell
# laufende Instanzen suchen (nur zum Fehlerzeitpunkt aussagekräftig)
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -match 'Moverequest-Dashboard|live_moverequest_statistik' } |
    Select-Object ProcessId, CommandLine

# oder einfach mit abweichendem Port starten
.\Exchange-MoveRequest-Dashboard.ps1 -Port 9090
```

Seit **v2.5** schreibt das Skript genau diese Daten (laufende Instanzen, Port-Listener, `netsh`-Reservierungen)
automatisch ins Log, sobald der Start scheitert.

**Dashboard lädt, aber die Tabelle bleibt leer**
Prüfen, ob überhaupt MoveRequests existieren (`Get-MoveRequest`) und ob der Exchange-Management-Zugriff
aus der Shell funktioniert. Fehlermeldungen stehen im Log unter `C:\ExchangeMigrationLog`.

Weitere Details im [Wiki](https://gitlab.com/RoccoAmmon/Exchange-MoveRequest-Dashboard/-/wikis/home).

## Versionen

Alle Änderungen siehe [CHANGELOG.md](CHANGELOG.md).

| Version | Schwerpunkt |
|---|---|
| 2.5 | Diagnose beim Startfehler: zweite Instanz, Port-Listener und URL-Reservierungen im Fehlerfall |
| 2.4 | Button „Abschließen" pro suspendierter Anforderung, Einzelziel über `Identity` |
| 2.3 | Schneller Erstablauf, parallele Statistikabrufe (Runspace-Pool), `-MaxDetailAbrufe` |
| 2.2 | WebGUI „Neue Verschiebeanforderung", Suspendierte fortsetzen, Abgeschlossene löschen, Vorabtest |
| 2.1 | Cache-Schlüssel korrigiert, Größenangaben in MB/GB, UTF-8 mit BOM |
| 2.0 | Stabilitätskern: Caches, Leck-Fix, selbstkorrigierendes Polling, Log-Rotation |
| 1.0 | Initiale Version |

## Mitwirken

Issues und Merge Requests sind willkommen – am besten mit

- Exchange-Version und PowerShell-Version
- Anzahl der gleichzeitigen MoveRequests
- Auszug aus dem Log unter `C:\ExchangeMigrationLog`

## Lizenz

[MIT](LICENSE) – © 2026 Rocco Ammon
