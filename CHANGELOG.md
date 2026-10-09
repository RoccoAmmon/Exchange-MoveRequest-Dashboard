# Changelog

Alle bemerkenswerten Änderungen an **Exchange-MoveRequest-Dashboard**.
Die Versionierung folgt `MAJOR.MINOR` – das Skript führt die Versionsnummer in `.NOTES`.

## [2.9] – 09.10.2026

### Behoben
- **Fehlwarnung beim Stoppen über die Seite.** Der Klick auf „Server stoppen" bricht die gerade
  laufende Browser-Anfrage ab, während das Skript in deren Response-Stream schreibt. Das ergab:

  ```text
  [WARNUNG] HTTP-Listener Fehler: Ausnahme beim Aufrufen von "Write" mit 3 Argument(en): "Der angegebene Netzwerkname ist nicht mehr verfügbar"
  [WARNUNG] Server-Stop angefordert.
  [INFO] HTTP-Server sauber heruntergefahren.
  ```

  Der Stopp selbst funktioniert einwandfrei – die Warnung war also rein kosmetisch, wirkte aber
  wie ein Fehler.
- Neue Funktion **`Test-BrowserVerbindungsabbruch`** erkennt Client-Abbrüche an der
  Exception-Kette (PowerShell liefert die `HttpListenerException` als Wrapper mit
  `InnerException`) an den Win32-Codes 64, 995, 1225, 1236, 10053, 10054 und 10058 bzw. am
  Meldungstext. Solche Fälle werden als `STILL` protokolliert – nur in die Datei, nicht auf die
  Konsole:

  ```text
  [STILL] Verbindung vom Browser geschlossen - Anfrage abgebrochen (beim Stoppen oder Schliessen des Tabs ganz normal).
  ```

  Echte Listener-Fehler bleiben eine WARNUNG, etwa „Zugriff verweigert" (5) oder 10061.

### Getestet
- 17 neue Prüfungen (`test_stop_log.ps1`): der konkrete Praxisfall (Win32 64, auch als Wrapper
  mit `InnerException` und als `MethodInvocationException`), weitere Abbruchcodes, nur der
  Meldungstext – sowie die Gegenprobe, dass „Zugriff verweigert", 10061 und sonstige
  Exceptionen weiterhin als Fehler erkannt werden.

## [2.8] – 08.10.2026

### Behoben
- **Fehler 32 beim Start (`Die angegebene Adresse ist bereits in Verwendung`).** Die Port-Prüfung
  lief nur *einmal*, und zwar **vor** Snap-In und erster Sammlung. In diesem rund 11‑sekündigen
  Fenster (Praxistest: Port um 12:00:22 noch frei, um 12:00:33 von einer zweiten Instanz belegt)
  konnte das URL-Praefix gewechseln, sodass `$Listener.Start()` mit Fehler 32 scheiterte.
  Jetzt wird die Prüfung mit der neuen Funktion `Resolve-DashboardPortKonflikt` erneut **unmittelbar
  vor jedem Startversuch** ausgeführt – und nach einem Fehler 32 wird **einmal nachgelegt**
  (höchstens 3 Versuche, mit frischem `HttpListener` pro Versuch). Ohne `-KeinAutoStopp` wird nicht
  nachgelegt, damit sich zwei Instanzen nicht gegenseitig beenden (`Ping-Pong`).
- **Fehlwarnung „Es läuft bereits eine weitere Dashboard-Instanz".** `return , $Treffer` lieferte dem
  Aufrufer ein Array mit *einem* leeren Element; mit der `@()`-Umbruchung entstand daraus eine Instanz
  ohne Felder – sichtbar als die leere Logzeile `PID  (), Port :`. Die Komma-Wraps in
  `Get-DashboardProzess`, `Get-LaufendeDashboardInstanzen` und `Get-PortDiagnose` sind entfernt.
- **Light-Zeilen zählten als „offen".** Im Light-Modus wurde `DetailOffen` trotz endgültiger Zeile
  erhöht, wodurch das Dashboard dauerhaft im Nachhol-Modus geblieben wäre.

### Neu
- **Parameter `-Light` (Alias `-NurStatus`).** Liefert nur den Status der Verschiebeanforderungen –
  Anzeigename, Status, Quell-/Ziel-Datenbank und Batch. `Get-MoveRequestStatistics` wird
  **vollständig ausgelassen**, das ist der eigentliche Geschwindigkeitsgewinn; die Sammlung bleibt
  bei den Grunddaten aus `Get-MoveRequest`. Die technischen Spalten (Statusdetail, Fortschritt,
  Übertragen, Gesamtgröße, Items, Bad Items, Start, Abschluss) werden per CSS
  (`.spalte-technisch`) ausgeblendet, die Fußzeile zeigt `Light-Modus`. Resume-/Löschen-Buttons
  und die Mehrfachauswahl bleiben voll funktionsfähig.
- Die Start-Protokollzeile nennt den Light-Modus, die `.NOTES` dokumentieren den Ablauf.

### Getestet
- 54 Prüfungen neu (`test_light_start.ps1`): Phantom-Zählung, `Resolve-DashboardPortKonflikt`
  (freier Port, fremder Dienst, `-KeinAutoStopp`, Auto-Stopp mit freiem Präfix), `New-Grundzeile`
  mit/ohne `-Light`, Sammlung mit und ohne Statistikabrufe sowie das generierte HTML
  (CSS-Regel, Spaltenklassen, Fußzeile).
- Wiederholt: Auto-Stopp 11/11, Move-Aktion 18/18, Frontend-Auswahl 38/38, PS-Syntax, UTF‑8-BOM,
  `node --check`.

## [2.7] – 08.10.2026

### Neu
- **Mehrfachauswahl suspendierter Anforderungen.** Jede Tabellenzeile mit Status `Suspended`
  (`-SuspendWhenReadyToComplete`) oder `AutoSuspended` hat neben dem Einzel-Button von v2.4
  jetzt ein **Auswahlfeld**. Darüber erscheint eine Leiste mit:
  - **„Alle sichtbaren auswählen"** – nur die Zeilen, die der Suchfilter gerade zeigt,
    **„Auswahl abschließen"** – mit Zähler, führt die Auswahl mit *einem* Klick aus,
  - **„Auswahl aufheben"**.

  Die Auswahl überlebt den Tabelle-Render (der bei jedem Poll komplett neu gebaut wird) und
  wird aufgeräumt, sobald eine Anforderung nicht mehr suspendiert ist – es bleibt kein
  Geisterhaken stehen. Während ein Auftrag läuft, sind die Schalter gesperrt.
- **`/api/move-aktion` akzeptiert `Identities` als Array.** Daraus entsteht **ein**
  Hintergrund-Auftrag, der die Auswahl der Reihe nach fortsetzt – ein Fortschrittsbalken
  statt eines Requests pro Zeile. Auswahlregel: `Identities` → `Identity` → `Alle` → `BatchName`.
- Identities, die sich nicht auflösen lassen (z. B. zwischenzeitlich abgeschlossene
  Anforderungen), werden protokolliert und übersprungen; der Rest der Auswahl läuft trotzdem.
- `Start-MoveAktion` arbeitet intern mit `$ZielIds` (dedupliziert, Leer-Einträge entfernt).
  Der Einzelweg über `Identity` bleibt unverändert erhalten.
- Das Wiki wurde korrigiert: die Werte von `Aktion` heißen `Resume`/`Entfernen`
  (das Beispiel mit `remove` funktionierte nicht).

### Getestet
- 18 Prüfungen gegen `Start-MoveAktion` mit Stubs statt Exchange (Einzel-/Mehrfachziel,
  fehlende Identities, Dubletten, Fehlermeldungen).
- 38 Prüfungen der Frontend-Auswahl-Logik gegen einen DOM-Stub (Render-Überleben, Filter,
  Prune bei Statuswechsel, Sperren während laufender Aktion).

## [2.6] – 08.10.2026

### Neu
- **Andere Instanz wird beim Start automatisch beendet.** Startet das Skript, während auf
  demselben Port bereits ein Dashboard läuft, wird diese Instanz jetzt *bevor* Zeit in
  Snap-In und erste Sammlung fließt beendet – der klassische Fehler 32 tritt gar nicht mehr auf.
  Ablauf in dieser Reihenfolge:
  1. **HTTP-Prüfung** (`Test-DashboardAntwort`) – sieht auch eine in einer *offenen Konsole*
     gestartete Instanz. Deren `powershell.exe` trägt den Skriptnamen nicht in der Kommandozeile,
     eine reine Prozesssuche findet sie also nicht – und genau dieser Listener hält das
     URL-Präfix, das dem eigenen Start fehlt.
  2. **Sauberer Stopp** über die fremde `/api/stop`-Route (`Stop-AnderesDashboard`): die alte
     Instanz schließt ihren HttpListener und gibt das Präfix frei. Der Prozess selbst darf
     weiterleben (offener Konsolen-Prompt) – gehalten wurde nur das Präfix.
  3. **Harter Stopp** per `Stop-Process` – ausschließlich bei Prozessen mit Skriptnamen *und*
     genau diesem Port, und nur wenn Schritt 2 nicht reichte.
  4. **Abbruch mit Hinweisen**, wenn das Präfix blockiert bleibt (manuelle Suche, anderer Port).
- Neuer Parameter **`-KeinAutoStopp`** – deaktiviert das automatische Beenden, das Skript
  begnügt sich dann mit einer Warnung im Log.
- Instanzen auf *anderen* Ports bleiben unberührt, fremde Dienste auf dem Start-Port werden
  als solche erkannt und protokolliert.
- Neue Hilfsfunktionen `Get-DashboardProzess`, `Test-DashboardAntwort` und
  `Stop-AnderesDashboard`. Die bisherige `Get-LaufendeDashboardInstanzen` liefert weiterhin
  dieselben Textzeilen fürs Log – sie baut jetzt auf `Get-DashboardProzess` auf.

## [2.5] – 08.10.2026

### Geändert
- **Diagnose beim Startfehler des Webservers.** Bisher endete ein scheiternder
  `$Listener.Start()` nur mit dem Win32-Text *„Der Prozess kann nicht auf die Datei zugreifen,
  da sie von einem anderen Prozess verwendet wird"* (Fehler 32). Das Log nennt jetzt:
  - die Ursache (URL-Präfix `http://localhost:<Port>/` war schon vergeben – fast immer ein
    zweites Dashboard, auch die alte Skript-Version),
  - **alle zum Fehlerzeitpunkt laufenden Dashboard-Prozesse** (PID, Name, Kommandozeile),
  - die Port-Listener (PID/Prozess) und die URL-Reservierungen aus `netsh`,
  - drei Abhilfen (andere Instanz beenden, anderer Port, Nachweis-Befehle).

  Entscheidend ist der **Zeitpunkt**: Ein Port-Check *nach* dem Fehler findet nichts mehr,
  weil die gescheiterte Registrierung sofort wieder freigegeben wird – die Spur ist dann kalt.

### Neu
- Beim Start werden weitere laufende Dashboard-Prozesse gesucht und bei Treffern protokolliert
  (Warnung vor dem bekannten Fehler-32-Fall).
- Neue Hilfsfunktionen `Get-LaufendeDashboardInstanzen` und `Get-PortDiagnose`.

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
