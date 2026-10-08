# Changelog

Alle bemerkenswerten Änderungen an **Exchange-MoveRequest-Dashboard**.
Die Versionierung folgt `MAJOR.MINOR` – das Skript führt die Versionsnummer in `.NOTES`.

## [2.4] – 08.10.2026

### Neu
- **Button „Abschließen" pro suspendierter Anforderung** – direkt hinter jeder Tabellenzeile
  mit Status `Suspended` (`-SuspendWhenReadyToComplete`) **oder** `AutoSuspended`
  (automatisches Anhalten). Er startet `Resume-MoveRequest` für genau diese eine Anforderung –
  nicht für den ganzen Batch. Sobald sich der Status ändert, verschwindet der Button automatisch.
- **`/api/move-aktion` akzeptiert `Identity`** einer einzelnen Anforderung – neben `BatchName`
  und `Alle`. Die Identity kommt aus der Detailzeile, dadurch wird genau der angezeigte Job
  fortgesetzt.

### Geändert
- Detailzeilen liefern die `Identity` des MoveRequests mit (Grundzeilen, Fehlerzeilen und
  gecachte Volldaten) – Voraussetzung für das Einzelziel.
- Der Auftrag einer Einzel-Aktion trägt keine Batch-Kennung mehr, damit am Auftrag kein
  Batch-Button erscheint, der fälschlich den ganzen Batch fortsetzen würde.

## [2.3] – 07.10.2026

### Neu
- **Schneller Erstablauf** – der erste Lauf liefert nur die Grunddaten aus `Get-MoveRequest`
  (Sekunden statt Minuten); die Statistikdetails kommen im nächsten Lauf nach. Bis dahin zeigt die
  Fortschrittsspalte `...` statt einer scheinbaren 0 % (`DetailOffen`).
- **Parallele Statistikabrufe** über einen Runspace-Pool (`-Parallelitaet`, Standard 4). Bei 300
  laufenden Jobs war das der Hauptengpass: sequenzielle Abrufe hielten die Request-Queue Minuten
  lang blockiert.
- **`-MaxDetailAbrufe`** begrenzt die Statistikabrufe je Sammlung (`0` = unbegrenzt). Offene
  Details werden zuerst nachgeholt, damit kein Job durch die Grenze dauerhaft übergeht.

### Geändert
- Das Lade-Overlay blendet ab, sobald die Dashboard-Tabelle da ist – Postfächer und Detaildaten
  laufen dann im Hintergrund weiter (v2.2 wartete auf alles).

## [2.2] – 07.10.2026

### Neu
- **WebGUI-Bereich „Neue Verschiebeanforderung"** – Postfächer einer Quelldatenbank auswählen,
  Quell- und Ziel-Datenbank wählen, Start durchgehend oder mit `-SuspendWhenReadyToComplete`.
  Die Erstellung läuft in einem eigenen Hintergrund-Job, das Dashboard bleibt bedienbar.
- **Alle Postfächer ohne Quelldatenbank** – ohne Quell-Datenbank werden alle Postfächer aller
  Datenbanken angezeigt, die Zugehörigkeit steht rechts in der Zeile (auch mitgefiltert).
- **Vorab-Prüfung der Ziel-Datenbank** (existent und gemountet). Die Systemmailbox-Prüfung wurde
  wieder entfernt – sie hat den Start normaler Verschiebungen fälschlich blockiert.
- **Auswahlfeld Priorität** (`-Priority`: Low/Normal/High/Critical/Emergency). Die Quelldatenbank
  darf leer bleiben, dann werden alle ausgewählten Postfächer verschoben.
- **Vorabtest mit `-WhatIf`** (aus / erst prüfen dann verschieben / nur prüfen). Im „nur prüfen"-
  Modus entstehen keine MoveRequests.
- **Auswahlfeld BadItemLimit** (0/1/10/20/50/100) für `-BadItemLimit`.
- **Lade-Overlay** zeigt Text und zählt die geladenen Postfächer hoch; es bleibt stehen, bis
  Dashboard-Daten *und* Postfächer da sind.
- **Suspendierte Anforderungen nachziehen** – Button „Suspendierte abschließen" pro Batch und
  global „Alle suspendierten abschließen" (`Resume-MoveRequest` als Hintergrund-Job, Fortschritt
  über `/api/move-status`).
- **Abgeschlossene Anforderungen löschen** – Buttons pro Auftrag und global „Alle abgeschlossenen
  löschen" (`Remove-MoveRequest` berührt nur die MoveRequest-Einträge). Neue Route
  `/api/move-aktion`.

### Behoben
- Überflüssiges `-Confirm` entfernt (`New-*`-Cmdlets fragen nicht nach). Die Darstellung
  „-SuspendWhenReadyToComplete True" im Cmdlet-Log ist korrekt und war nie die Fehlerursache.

## [2.1] – 07.10.2026

### Behoben
- Statistik-Cache nutzte `ExchangeObjectId` als Schlüssel (leer/nicht eindeutig) – alle
  Completed-Jobs zeigten dieselbe Zeile. Schlüssel ist jetzt `Identity`/`RequestGuid`, Fallback
  `DisplayName`+`BatchName`, mit Selbstheilung bei Kollision.

### Geändert
- Spalten „Übertragen"/„Gesamtgröße" zeigen nur noch ganze MB/GB
  (`2 GB` statt `1.834 GB (1,969,304,264 bytes)`).
- Datei auf UTF-8 mit BOM umgestellt, damit Umlaute unter PowerShell 5.1 korrekt gelesen werden.

## [2.0] – 07.10.2026

Stabilitätskern – Behebung des Totalausfalls nach wenigen Minuten bei vielen Jobs.

### Behoben
- `Response.OutputStream.Close()` stand außerhalb des `finally` – jeder fehlgeschlagene Request
  leckte eine TCP-Verbindung, nach ~10 Minuten war der Port dicht.
- `setInterval(async)` stapelte Requests. Ersetzt durch eine selbstkorrigierende `setTimeout`-Kette
  mit `AbortController` und In-Flight-Sperre.
- `$_` im `catch`-Block ist der `ErrorRecord`, nicht der MoveRequest – Fehlermeldungen waren leer.
- `"$var.Property"` interpoliert in PowerShell nicht die Property, sondern den Wert plus Literaltext.
- Cache-TTL war am Sammlungsanfang statt -ende verankert, der Schnellpfad konnte nie greifen.
- Jobs mit fehlgeschlagener Statistik fielen aus der Tabelle (Gesamt 235, Tabelle 226).
- `Get-StatusFarbe`/`Get-StatusPrioritaet` waren `Mandatory` und warfen bei leerem Status, obwohl
  darunter ein Fallback lag – ein solcher Job hat die komplette Sammlung gekillt (0 Zeilen).

### Neu
- Snapshot-Cache: überlappende Requests werden sofort beantwortet (19 s → 0,03 s).
- `Get-MoveRequestStatistics` nur noch für aktive Jobs, Endzustände gecacht (235 → 188 Abrufe).
- Stale-Snapshot bei Sammlungsfehler statt „Keine MoveRequests vorhanden".
- Dauerhaft offener `StreamWriter` statt `Add-Content` pro Zeile, Rate-Limiting und Log-Rotation.
- Parameter `-CacheIntervall`, `-AbfrageTimeout`, `-LeerlaufIntervall`, `-BatchName`, `-KeinBrowser`.
- Zeilen ohne Statistik werden markiert statt unterschlagen.

## [1.0] – 26.02.2026

### Neu
- Initiale Version: Live-Dashboard mit Mini-Webserver, automatischer Aktualisierung ohne
  Seiten-Reload und priorisierter Darstellung aktiver Jobs.
