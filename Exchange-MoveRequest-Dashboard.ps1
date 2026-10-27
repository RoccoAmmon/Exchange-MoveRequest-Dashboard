<#
.SYNOPSIS
    Startet ein Live-Dashboard (Mini-Webserver) für Exchange MoveRequests.
    Aktive Jobs werden immer oben in der Tabelle angezeigt.

.DESCRIPTION
    Dieses Skript startet einen lokalen HTTP-Server auf einem konfigurierbaren Port.
    Im Browser wird ein Dashboard angezeigt, das sich automatisch alle X Sekunden
    aktualisiert – OHNE Seiten-Reload. Die Daten werden per AJAX (Fetch-API)
    vom PowerShell-Backend abgerufen und dynamisch in die HTML-Seite injiziert.

    Die Sortierung priorisiert aktive Jobs (InProgress, CompletionInProgress,
    Queued) vor abgeschlossenen oder fehlgeschlagenen Jobs.

    STABILITÄTSKERN (v2.0) – die Punkte, die bei vielen Jobs zuvor
    zum Totalausfall nach wenigen Minuten führten:

    1. SAMMLUNGS-CACHE   Überlappende Requests bekommen sofort den letzten
                         Snapshot. Vorher wartete jeder Request die volle
                         Exchange-Sammlung ab -> Request-Queue wuchs endlos.
    2. STATS-CACHE       Get-MoveRequestStatistics wird nur noch für AKTIVE
                         Jobs aufgerufen. Fertige/fehlgeschlagene Jobs kommen
                         aus dem Cache. Das war die Ursache für
                         "maxenvelopesizekb"-Fehler und für den Großteil
                         der Laufzeit.
    3. KEIN CONNECTION-LEAK  Response.OutputStream.Close() steht in einem
                         finally. Ohne das leckte jeder fehlgeschlagene
                         Request eine TCP-Verbindung; nach ~10 Minuten war
                         der Port dicht.
    4. SELBSTKORRIGIERENDES POLLING  setTimeout-Kette statt setInterval +
                         AbortController. Der Browser stapelt keine Requests
                         mehr, wenn der Server langsam ist.
    5. GEDAEMPELTES LOGGING  Ein dauerhaft offener StreamWriter statt
                         Add-Content pro Zeile (das waren über 200 synchrone
                         Dateioperationen pro Poll). Gleiche Meldungen werden
                         innerhalb von 5 Minuten nur gezählt, nicht erneut
                         geschrieben. Ab 10 MB wird rotiert, es werden 5
                         Generationen aufbewahrt.
    6. STALE-SNAPSHOT    Schlägt eine Sammlung fehl, wird der letzte
                         bekannte Stand weiter ausgeliefert (mit Fehlerbanner)
                         statt "Keine MoveRequests vorhanden."

    Routen:
      /                -> Liefert die HTML-Dashboard-Seite (einmalig laden)
      /api/data        -> Liefert aktuelle MoveRequest-Daten als JSON (wird gepollt)
      /api/databases   -> Liefert alle Postfachdatenbanken (Quell-/Ziel-Auswahl)
      /api/benutzer    -> Liefert die Postfaecher (?quelle=NAME, ohne
                          quelle = alle Postfaecher aller Datenbanken;
                          ?typ=benutzer|sonder|alle|archiv waehlt die
                          Postfachart: Sonderpostfaecher = Arbitration,
                          AuditLog, AuxAuditLog, PublicFolder, Archiv,
                          SystemMailbox, Migration, Discovery; archiv =
                          alle Postfaecher mit aktiviertem Archiv)
      /api/move        -> Erstellt Verschiebeanforderungen (POST, JSON-Body
                          mit Quelle, Ziel, Benutzer, Suspend, Prioritaet,
                          Vorabtest und BadItemLimit)
      /api/move-status -> Status und Ergebnis der gestarteten Verschiebeauftraege
      /api/move-aktion -> Fortsetzen suspendierter oder Loeschen
                 abgeschlossener MoveRequests (POST, JSON-Body mit Aktion,
                 BatchName, Alle und optional Identity bzw. Identities
                 einer oder mehrerer Anforderungen)
      /api/stop        -> Stoppt den Webserver sauber

.NOTES
    Autor:          Rocco Ammon
    Erstelldatum:   26.02.2026
    Stand:          16.10.2026
    Version:        2.16 (Update-Check gegen die GitLab-Releases-API:
                            GUI-Badge und Log-Hinweis, abschaltbar mit
                            -KeinUpdateCheck)
    Voraussetzung:  Exchange Server 2019 oder SE (Subscription Edition),
                    On-Premises
    Log-Pfad:       C:\ExchangeMigrationLog
    HINWEIS:        Startet ohne Admin-Rechte automatisch mit UAC elevated neu (Selbst-Elevation, v2.14); Absage = Warnung und Weiterlauf ohne Erhoehung

    Aenderungen:    v1.0 - Initiale Version
                    v2.0 - Fix: OutputStream.Close() stand außerhalb des finally.
                                 Jeder fehlgeschlagene Request leckte eine
                                 TCP-Verbindung, nach ~10 min war der Port dicht
                           - Fix: setInterval(async) stapelte Requests. Ersetzt
                                 durch eine selbstkorrigierende setTimeout-Kette
                                 mit AbortController und In-Flight-Sperre
                           - Fix: $_ im catch-Block ist der ErrorRecord, nicht der
                                 MoveRequest. Fehlermeldungen waren dadurch leer
                           - Fix: "$var.Property" interpoliert in PowerShell nicht
                                 die Property, sondern den Wert plus Literaltext
                           - Fix: Cache-TTL war am Sammlungsanfang statt -ende
                                 verankert, der Schnellpfad konnte nie greifen
                           - Fix: Jobs mit fehlgeschlagener Statistik fielen aus
                                 der Tabelle (Gesamt 235, Tabelle 226)
                           - Fix: Get-StatusFarbe/Get-StatusPrioritaet waren
                                 Mandatory und warfen bei leerem Status, obwohl
                                 darunter ein Fallback lag. Ein solcher Job hat
                                 die komplette Sammlung gekillt (0 Zeilen)
                           - Neu: Snapshot-Cache, überlappende Requests werden
                                 sofort beantwortet (19 s -> 0,03 s)
                           - Neu: Get-MoveRequestStatistics nur noch für aktive
                                 Jobs, Endzustände werden gecacht (235 -> 188
                                 Abrufe pro Sammlung)
                           - Neu: Stale-Snapshot bei Sammlungsfehler statt
                                 "Keine MoveRequests vorhanden."
                           - Neu: Dauerhaft offener StreamWriter statt Add-Content
                                 pro Zeile, Rate-Limiting und Log-Rotation
                           - Neu: Parameter -CacheIntervall, -AbfrageTimeout,
                                 -LeerlaufIntervall, -BatchName, -KeinBrowser
                           - Neu: Zeilen ohne Statistik werden markiert statt
                                 unterschlagen
                           - v2.1 Fix: Statistik-Cache nutzte ExchangeObjectId
                                 als Schluessel (leer/nicht eindeutig). Alle
                                 Completed-Jobs zeigten dieselbe Zeile.
                                 Schluessel ist jetzt Identity/RequestGuid,
                                 Fallback DisplayName+BatchName, mit
                                 Selbstheilung bei Kollision
                           - v2.1 Neu: Spalten Uebertragen/Gesamtgroesse zeigen
                                 nur noch ganze MB/GB ("2 GB" statt
                                 "1.834 GB (1,969,304,264 bytes)")
                           - v2.1 Fix: Datei auf UTF-8 mit BOM umgestellt,
                                 damit Umlaute unter PowerShell 5.1 korrekt
                                 gelesen werden
                           - v2.2 Neu: WebGUI-Bereich "Neue Verschiebe-
                                 anforderung": Postfaecher einer Quell-
                                 datenbank auswaehlen, Quell- und Ziel-
                                 datenbank waehlen, Start entweder
                                 durchgaengig oder mit -SuspendWhenReady-
                                 ToComplete (haelt vor dem Abschluss an).
                                 Die Erstellung laeuft in einem eigenen
                                 Hintergrund-Job, das Dashboard bleibt
                                 waehrenddessen bedienbar.
                           - v2.2 Neu: Ohne Quelldatenbank werden ALLE
                                 Postfaecher aller Datenbanken angezeigt,
                                 die Zugehoerigkeit steht rechts in der
                                 Zeile (auch mitgefiltert).
                           - v2.2 Neu: Vorab-Pruefung der Ziel-Datenbank
                                 (existent und gemountet). Die System-
                                 mailbox-Pruefung wurde wieder entfernt -
                                 sie hat den Start normaler Verschiebungen
                                 faelschlich blockiert.
                           - v2.2 Neu: Auswahlfeld Prioritaet, wird als
                                 -Priority an New-MoveRequest uebergeben
                                 (Low/Normal/High/Critical/Emergency).
                                 Quell-Datenbank darf leer bleiben (dann
                                 werden alle ausgewaehlten Postfaecher
                                 verschoben).
                           - v2.2 Neu: Vorabtest mit -WhatIf (aus / erst
                                 pruefen dann verschieben / nur pruefen). Im
                                 "nur pruefen"-Modus entstehen keine
                                 MoveRequests, es wird nur getestet, ob das
                                 Postfach verschiebbar ist.
                           - v2.2 Neu: Auswahlfeld BadItemLimit fuer
                                 -BadItemLimit (0/1/10/20/50/100) - so viele
                                 kaputte Objekte duerfen beim Verschieben
                                 uebersprungen werden.
                           - v2.2 Neu: Lade-Overlay zeigt jetzt Text und zaehlt die
                                 geladenen Postfaecher hoch. Das Overlay bleibt stehen, bis
                                 Dashboard-Daten UND Postfaecher da sind (vorher verschwand
                                 der Spinner, waehrend noch geladen wurde).
                           - v2.2 Neu: Suspendierte Anforderungen nachziehen: Button
                                 "Suspendierte abschliessen" an jedem Verschiebeauftrag
                                 (Batch) und global "Alle suspendierten abschliessen" -
                                 Resume-MoveRequest laeuft als Hintergrund-Job, der
                                 Fortschritt kommt ueber /api/move-status.
                           - v2.2 Neu: Abgeschlossene Anforderungen loeschen: Buttons
                                 pro Auftrag und global "Alle abgeschlossenen loeschen" -
                                 Remove-MoveRequest entfernt nur die MoveRequest-Eintraege,
                                 die Postfaecher bleiben unberuehrt. Neue Route
                                 /api/move-aktion, Ablauf wie bei Verschiebungen.
                           - v2.2 Fix: ueberfluessiges -Confirm entfernt
                                 (New-*Cmdlets fragen nicht nach). Die
                                 Darstellung "-SuspendWhenReadyToComplete
                                 True" im Cmdlet-Log ist korrekt und war nie
                                 die Fehlerursache.
                           - v2.3 Neu: Erste Datensammlung beschleunigt: der erste
                                 Lauf liefert nur die Grunddaten aus Get-MoveRequest
                                 (Sekunden statt Minuten), die Statistikdetails kommen im
                                 naechsten Lauf nach. Die Tabelle zeigt bis dahin "..." in
                                 der Fortschrittsspalte statt einer scheinbaren 0 % (Feld
                                 DetailOffen).
                           - v2.3 Neu: Statistikabrufe laufen parallel ueber einen
                                 Runspace-Pool (Parameter -Parallelitaet, Standard 4). Bei
                                 300 laufenden Jobs war das der Hauptengpass: sequenzielle
                                 Abrufe hielten die Request-Queue Minuten lang blockiert -
                                 jede andere Anfrage (Postfaecher, Datenbanken, Statusabfrage)
                                 musste warten.
                           - v2.3 Neu: Parameter -MaxDetailAbrufe begrenzt die
                                 Statistikabrufe je Sammlung (0 = unbegrenzt). Offene Details
                                 werden zuerst nachgeholt, damit kein Job durch die Grenze
                                 dauerhaft uebergeht.
                           - v2.3 Geaendert: Das Lade-Overlay blendet ab, sobald die
                                 Dashboard-Tabelle da ist - Postfaecher und Detaildaten
                                 laufen dann im Hintergrund weiter (v2.2 musste auf ALLES
                                 gewartet werden).
                           - v2.4 Neu: Button "Abschließen" hinter jeder suspendierten
                                 Zeile der Tabelle - Status 'Suspended'
                                 (-SuspendWhenReadyToComplete) UND 'AutoSuspended'
                                 (automatisches Anhalten). Er fortsetzt genau DIESE
                                 Anforderung per Resume-MoveRequest, nicht den ganzen
                                 Batch. Der Button verschwindet automatisch, sobald der
                                 Status sich geaendert hat.
                           - v2.4 Neu: /api/move-aktion akzeptiert Identity einer
                                 einzelnen Anforderung (neben BatchName und Alle).
                                 Die Identity kommt aus der Detailzeile - dadurch ist
                                 sichergestellt, dass genau der angezeigte Job
                                 fortgesetzt wird.
                           - v2.4 Neu: Der Auftrag einer Einzel-Aktion traegt keine
                                 Batch-Kennung mehr - ein Batch-Button am Auftrag
                                 wuerde sonst faelschlich den ganzen Batch fortsetzen.
                           - v2.5 Neu: Beim Start wird nach weiteren laufenden
                                 Dashboard-Prozessen gesucht und im Log genannt.
                                 Ein zweites Dashboard waere der haeufigste Grund
                                 fuer Fehler 32 beim HttpListener.Start().
                           - v2.5 Geaendert: Schlaegt HttpListener.Start() fehl, wird
                                 nicht nur die Win32-Meldung geschrieben. Das Log
                                 nennt jetzt die Ursache (URL-Praefix schon
                                 vergeben), die zum FEHLERZEITPUNKT laufenden
                                 Instanzen, Port-Listener (PID/Prozess) und
                                 URL-Reservierungen sowie drei Abhilfen.
                                 Entscheidend: der Zustand muss im Fehlerfall
                                 festgehalten werden - ein Port-Check DANACH findet
                                 nichts mehr, die Registrierung war sofort frei.
                            - v2.6 Neu: Andere Instanz auf demselben Port wird beim
                                  Start automatisch beendet, bevor Zeit in Snap-In
                                  und erste Sammlung fliessen. Ablauf:
                                  HTTP-Pruefung (sieht auch eine in offenen
                                  Konsole gestartete Instanz), dann sauberer Stopp
                                  ueber /api/stop, dann erst hart ueber
                                  Stop-Process. Schlaegt das fehl, bricht der Start
                                  mit Hinweisen ab. Abschalten mit -KeinAutoStopp.
                            - v2.6 Neu: Hilfsfunktionen Get-DashboardProzess,
                                  Test-DashboardAntwort und Stop-AnderesDashboard.
                                  Die Prozesssuche allein reicht nicht: eine in
                                  offener Konsole gestartete Instanz traegt den
                                  Skriptnamen nicht in der Kommandozeile.
                            - v2.7 Neu: Mehrfachauswahl suspendierter Anforderungen.
                                  Jede Zeile mit Suspend-Status hat jetzt ein
                                  Auswahlfeld neben dem Einzel-Button. Darueber
                                  erscheint eine Leiste mit "Alle sichtbaren
                                  auswaehlen", "Auswahl abschliessen" (mit Zaehler)
                                  und "Auswahl aufheben". Die Auswahl ueberlebt den
                                  Tabelle-Render (der bei jedem Poll komplett neu
                                  gebaut wird) und wird aufgeraeumt, sobald eine
                                  Anforderung nicht mehr suspendiert ist.
                            - v2.7 Neu: /api/move-aktion akzeptiert Identities als
                                  Array. Daraus entsteht EIN Hintergrund-Auftrag,
                                  der die Auswahl der Reihe nach fortsetzt - ein
                                  Fortschrittsbalken statt eines Requests pro Zeile.
                                  Nicht auffindbare Identities werden protokolliert
                                  und uebersprungen, der Rest laeuft trotzdem.
                            - v2.8 Fix: "return , $Array" lieferte dem Aufrufer ein
                                  Array mit EINEM leeren Element. Zusammen mit @()
                                  entstand daraus die Fehlwarnung "Es laeuft bereits
                                  eine weitere Dashboard-Instanz" samt der leeren
                                  Logzeile "PID  (), Port :". Jetzt ohne Komma.
                            - v2.8 Fix: Die Port-Pruefung lief nur EINMAL, und zwar
                                  vor Snap-In und erster Sammlung. Liegt eine zweite
                                  Instanz in diesem rund 11-Sekunden-Fenster, war
                                  das URL-Praefix beim $Listener.Start() bereits
                                  vergeben - Fehler 32. Jetzt wird direkt VOR jedem
                                  Startversuch erneut geprueft und ggf. beendet,
                                  nach Fehler 32 wird einmal nachgelegt
                                  (hoechstens 3 Versuche, kein Ping-Pong).
                                  Neue Funktion: Resolve-DashboardPortKonflikt.
                            - v2.8 Neu: Parameter -Light (Alias -NurStatus) - nur
                                  der Status der Verschiebeanforderungen, ohne
                                  technische Werte. Get-MoveRequestStatistics
                                  entfaellt vollstaendig, die Sammlung bleibt bei
                                  den Grunddaten und ist dadurch deutlich schneller;
                                  die technischen Spalten werden im Dashboard per
                                  CSS ausgeblendet.
                            - v2.9 Fix: Beim Stoppen ueber die Seite kam die
                                  WARNUNG "HTTP-Listener Fehler: ... Der angegebene
                                  Netzwerkname ist nicht mehr verfuegbar" - der
                                  Browser hatte die Verbindung zuerst zugeklemmt,
                                  der Server fuhr im selben Atemzug sauber
                                  herunter. Neue Funktion
                                  Test-BrowserVerbindungsabbruch erkennt solche
                                  Client-Abbrueche (Win32 64, 995, 1225, 1236,
                                  10053, 10054, 10058) ueber die Exception-Kette
                                  und protokolliert sie als STILL statt als
                                  WARNUNG - echte Listener-Fehler bleiben WARNUNG.
                            - v2.10 Neu: Postfachart-Auswahl in der GUI
                                  ("Benutzerpostfaecher" / "Sonderpostfaecher" /
                                  "Alle") samt ?typ= in /api/benutzer. Die
                                  Sonderpostfaecher (Arbitration, AuditLog,
                                  AuxAuditLog, PublicFolder, Archiv, SystemMailbox,
                                  Migration, Discovery) lassen sich dadurch
                                  getrennt anzeigen, auswaehlen und verschieben -
                                  vorher wurden sie vollstaendig ausgefiltert.
                                  Health-Postfaecher bleiben verborgen. Neu dazu:
                                  Funktion Get-PostfachTyp (Kategorie aus
                                  RecipientTypeDetails) und je Postfach die
                                  Felder "Typ" sowie "Schluessel" (SMTP, sonst
                                  Alias, Anzeigename, DN) - Sonderpostfaecher
                                  haben oft keine eigene Adresse.
                            - v2.11 Neu: Die Versionsnummer steht jetzt in der
                                  Web-Oberflaeche - als Marke neben der
                                  Ueberschrift, im Seitentitel und in der
                                  Fusszeile. Neue Funktion Get-SkriptVersion
                                  liest die Nummer aus dem .NOTES-Block dieses
                                  Skripts, es gibt also nur EINE Quelle und
                                  Oberflaeche und Skript koennen nicht
                                  auseinanderlaufen.
                            - v2.12 Fix: Get-Mailbox OHNE Schalter liefert die
                                  System- und Arbitration-Postfaecher nicht -
                                  in der Sonderpostfaecher-Liste erschien daher
                                  nur das Discoverysuchpostfaech, waehrend
                                  SystemMailbox{...}, FederatedEmail und
                                  Migration.fehlten. Get-BenutzerListe fragt
                                  deshalb zusaetzlich mit -Arbitration,
                                  -AuditLog, -AuxAuditLog, -Migration,
                                  -PublicFolder und -Archive ab (jede Quelle
                                  einzeln abgefangen, Verfuegbarkeit ueber
                                  Get-Command geprueft, Ergebnisse nach
                                  Identitaet zusammengefuehrt). Neu dazu:
                                  Ansicht "Postfaecher mit Archiv" (?typ=archiv)
                                  und das Feld "Archiv". Get-PostfachTyp
                                  prueft zusaetzlich Namensmuster
                                  (SystemMailbox{...}, FederatedEmail.,
                                  Migration., HealthMailbox) fuer Postfaecher
                                  ohne brauchbaren RecipientTypeDetails-Wert.
                            - v2.13 Neu: Jede fehlgeschlagene Verschiebung
                                  erklaert sich jetzt selbst: die Meldung
                                  enthaelt den Ausfuehrungskontext des
                                  Hintergrund-Jobs (Benutzer, Administrator
                                  ja/nein, PowerShell-Version und -Bitness),
                                  Exception-Typ, InnerException und
                                  FullyQualifiedErrorId. Bei "Der Zugriff
                                  wurde verweigert" (der Mailbox Replication
                                  Service lehnt den Aufruf ab) kommt ein
                                  Handlungshinweis mit dem manuellen
                                  EMS-Vergleichstest. Beim Skriptstart wird
                                  der eigene Ausfuehrungskontext ins Log
                                  geschrieben - so ist nachvollziehbar, in
                                  welchem Konto Dashboard und Verschiebe-Job
                                  laufen.
                            - v2.14 Neu: Selbst-Elevation - startet das
                                  Skript ohne Admin-Rechte, wird es mit
                                  UAC elevated neu gestartet; alle
                                  uebergebenen Parameter gehen mit
                                  (New-ElevationsArgumente), das
                                  Ausgangsfenster schliesst. Lehnt der
                                  Nutzer die UAC-Frage ab, laeuft das
                                  Skript ohne Erhoehung weiter - mit
                                  Warnung im Log und einem Hinweisdialog,
                                  denn System- und Arbitration-Postfaecher
                                  brauchen das erhoehte Token (sonst
                                  meldet der MRS "Der Zugriff wurde
                                  verweigert").
                            - v2.15 Neu: Update-Check gegen die
                                  GitLab-Releases-API (asynchron per
                                  Runspace, 3 Versuche, Timeout 3 s):
                                  erscheint eine neuere Version, zeigt
                                  die Web-Oberflaeche ein klickbares
                                  Update-Badge neben der Versionsmarke
                                  und das Log einen Hinweis mit der
                                  Release-URL. Ohne Admin-Rechte bleibt
                                  der Check unveraendert ausserhalb des
                                  Elevation-Neustarts. Abschaltbar mit
                                  -KeinUpdateCheck (Airgap/Offline);
                                  Fehler, Offline und Proxy-Sperren
                                  bleiben folgenlos.

    BEI ENVELOPE-FEHLERN (Get-MoveRequestStatistics):
        In einer Exchange Management Shell ausführen und Skript neu starten:
        Set-PowerShellConfig -Identity WSMan:localhost -MaxEnvelopeSizeKb 16384
    Das Skript ist mit 235 Jobs auch ohne diesen Wert lauffähig, weil es
    abgeschlossene Jobs nicht mehr abfragt.

.EXAMPLE
    .\Exchange-MoveRequest-Dashboard.ps1
    Startet das Dashboard auf http://localhost:8585/

.EXAMPLE
    .\Exchange-MoveRequest-Dashboard.ps1 -Port 9090 -AktualisierungsIntervall 15
    Startet das Dashboard auf Port 9090 mit 15 Sekunden Aktualisierungsintervall.

.EXAMPLE
    .\Exchange-MoveRequest-Dashboard.ps1 -BatchName "MBX2026Q1"
    Beschränkt die Auswertung auf einen Move-Batch.

.EXAMPLE
    .\Exchange-MoveRequest-Dashboard.ps1 -Parallelitaet 8 -MaxDetailAbrufe 100
    Holt die Statistikdetails mit bis zu 8 parallelen Abrufen und hoechstens
    100 Abfragen pro Sammlung. Der Rest wird in den folgenden Läufen
    nachgeholt - ideal bei mehreren hundert laufenden Verschiebungen.

.EXAMPLE
    .\Exchange-MoveRequest-Dashboard.ps1 -Light
    Light-Modus (Alias -NurStatus): nur der Status der Verschiebeanforderungen
    mit Name, Quell-/Ziel-Datenbank und Batch. Get-MoveRequestStatistics wird
    gar nicht erst abgerufen - die Sammlung bleibt bei den Grunddaten aus
    Get-MoveRequest und ist dadurch deutlich schneller. Prozent, Groessen,
    Items und Zeiten fehlen und sind im Dashboard ausgeblendet.
#>

# ============================================================================
# Region: Parameter
# ============================================================================
param(
    [Parameter(Mandatory = $false, HelpMessage = "Port für den Webserver (Standard: 8585)")]
    [int]$Port = 8585,

    [Parameter(Mandatory = $false, HelpMessage = "AktualisierungsIntervall in Sekunden (Standard: 10)")]
    [int]$AktualisierungsIntervall = 10,

    [Parameter(Mandatory = $false, HelpMessage = "Sekunden, für die ein bereits gesammelter Snapshot ohne neue Exchange-Abfrage ausgeliefert wird (Standard: 5)")]
    [int]$CacheIntervall = 5,

    [Parameter(Mandatory = $false, HelpMessage = "Sekunden, nach denen der Browser einen laufenden /api/data-Request abbricht (Standard: 300)")]
    [int]$AbfrageTimeout = 300,

    [Parameter(Mandatory = $false, HelpMessage = "Sekunden zwischen zwei Sammlungen, wenn keine aktiven Jobs mehr laufen (Standard: 60)")]
    [int]$LeerlaufIntervall = 60,

    [Parameter(Mandatory = $false, HelpMessage = "Optionaler Filter auf einen Move-Batch")]
    [string]$BatchName = "",

    [Parameter(Mandatory = $false, HelpMessage = "Anzahl paralleler Get-MoveRequestStatistics-Abrufe (1 = sequenziell, Standard: 4)")]
    [ValidateRange(1, 32)]
    [int]$Parallelitaet = 4,

    [Parameter(Mandatory = $false, HelpMessage = "Maximale Statistikabrufe pro Sammlung, 0 = unbegrenzt (Standard: 0)")]
    [ValidateRange(0, 100000)]
    [int]$MaxDetailAbrufe = 0,

    [Parameter(Mandatory = $false, HelpMessage = "Browser nicht automatisch öffnen")]
    [switch]$KeinBrowser,

    [Parameter(Mandatory = $false, HelpMessage = "Andere Instanz auf demselben Port nicht automatisch beenden")]
    [switch]$KeinAutoStopp,

    [Parameter(Mandatory = $false, HelpMessage = "Light-Modus: nur den Status der Verschiebeanforderungen, ohne technische Werte")]
    [Alias("NurStatus")]
    [switch]$Light,

    [Parameter(Mandatory = $false, HelpMessage = "Update-Check gegen die GitLab-Releases-API unterdruecken (Airgap/Offline) / suppress update check")]
    [switch]$KeinUpdateCheck,

    [Parameter(Mandatory = $false, HelpMessage = "Sprache der Oberflaeche: Auto (Betriebssystem), de oder en (Standard: Auto) / UI language: Auto (OS), de or en")]
    [ValidateSet("Auto", "de", "en")]
    [Alias("Language")]
    [string]$Sprache = "Auto"
)

# ============================================================================
# Region: Sprache / Localization (v2.16)
# ============================================================================
# Die Oberflaeche ist zweisprachig. Ohne -Sprache wird die Sprache des
# Betriebssystems verwendet (deutsches Windows -> Deutsch, sonst Englisch).
# Der Umschalter in der Web-Oberflaeche setzt ein Cookie und laedt die Seite
# mit ?lang=de bzw. ?lang=en neu. Damit folgen auch alle vom Server erzeugten
# Meldungen (Validierung, Auftragsstatus, Log) der gewaehlten Sprache.

function Get-StandardSprache {
    if ($env:EXCHANGE_DASHBOARD_LANG -in @('de', 'en')) {
        return [string]$env:EXCHANGE_DASHBOARD_LANG
    }

    try {
        $Kultur = [System.Globalization.CultureInfo]::CurrentUICulture
        if ($Kultur -and $Kultur.TwoLetterISOLanguageName -eq 'de') { return 'de' }
    }
    catch { }

    return 'en'
}

function ConvertTo-SprachTabelle {
    param([AllowEmptyString()][string]$RohText)

    $Tabelle = @{}
    foreach ($Zeile in ($RohText -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($Zeile)) { continue }
        if ($Zeile.TrimStart().StartsWith('#')) { continue }

        $Trenner = $Zeile.IndexOf('=')
        if ($Trenner -lt 1) { continue }

        $Schluessel = $Zeile.Substring(0, $Trenner).Trim()
        $Wert       = $Zeile.Substring($Trenner + 1)
        if ($Wert.StartsWith(' ')) { $Wert = $Wert.Substring(1) }
        $Wert = $Wert -replace '\\n', "`n"

        $Tabelle[$Schluessel] = $Wert
    }

    return $Tabelle
}

$script:SprachRoh = @{
    de = @'
ui.title=Exchange MoveRequest Live-Dashboard
ui.subtitle=Server: %Server% | Aktualisierung alle %Seconds% Sekunden
ui.versionTitle=Version des Skripts (aus dem .NOTES-Block)
ui.updateBadgeTitle=Oeffnet die Release-Seite dieses Projekts im Browser.
ui.updateBadge=Update verfuegbar
ui.lastUpdateLoading=Letzte Aktualisierung: wird geladen...
ui.live=LIVE
ui.loadingStart=Dashboard wird gestartet ...
ui.totalMoveRequests=Gesamtanzahl MoveRequests:
ui.updates=Updates:
ui.newMoveRequest=Neue Verschiebeanforderung
ui.sourceDb=Quell-Datenbank (leer = alle Postfaecher)
ui.allDatabases=-- alle Datenbanken --
ui.targetDb=Ziel-Datenbank
ui.pleaseChoose=-- bitte waehlen --
ui.priority=Prioritaet (-Priority)
ui.priorityLow=Low (niedrig)
ui.priorityNormal=Normal (Standard)
ui.priorityHigh=High (hoch)
ui.priorityCritical=Critical (kritisch)
ui.priorityEmergency=Emergency (Notfall)
ui.badItems=BadItems ueberspringen (-BadItemLimit)
ui.badItemsNone=0 - keine (Standard)
ui.mode=Vorgangsweise
ui.modeDirect=Direkt durchmigrieren (bis Completed)
ui.modeSuspend=Erst bis 95 % laufen lassen und suspendieren
ui.pretest=Vorabtest mit -WhatIf
ui.pretestOff=aus (sofort verschieben)
ui.pretestCheckThenMove=erst pruefen, dann verschieben
ui.pretestOnly=nur pruefen (nichts verschieben)
ui.mailboxType=Postfachart
ui.mailboxTypeTitle=Sonderpostfaecher werden in der Normalansicht bewusst nicht angezeigt
ui.mailboxTypeUser=Benutzerpostfaecher
ui.mailboxTypeSpecial=Sonderpostfaecher (Arbitration, AuditLog, AuxAuditLog, PublicFolder, Archiv)
ui.mailboxTypeArchive=Postfaecher mit Archiv
ui.mailboxTypeAll=Alle (Benutzer- und Sonderpostfaecher)
ui.filterMailboxes=Postfaecher filtern
ui.filterMailboxesPlaceholder=Filter nach Name, Adresse, Alias, Typ oder Datenbank
ui.selectAllVisible=Alle sichtbaren auswaehlen
ui.clearSelection=Auswahl aufheben
ui.mailboxesLoading=Postfaecher werden geladen ...
ui.startMoveRequest=Verschiebeanforderung starten
ui.selectedCount=0 Postfach/Postfaecher ausgewaehlt
ui.resumeAllSuspended=Alle suspendierten abschliessen
ui.deleteAllCompleted=Alle abgeschlossenen loeschen
ui.backgroundJobNote=Resume-MoveRequest bzw. Remove-MoveRequest - laeuft als Hintergrund-Auftrag
ui.detailsHeading=Detaillierte MoveRequest-Uebersicht
ui.sortHint=Sortierung: Aktive Jobs (InProgress, Queued) werden immer oben angezeigt
ui.searchPlaceholder=Suche nach Name, Status, Datenbank, Batch...
ui.selectAllVisibleSuspendedTitle=Alle sichtbaren suspendierten Anforderungen auswaehlen (respektiert die Suche)
ui.completeSelection=Auswahl abschliessen
ui.completeSelectionTitle=Die ausgewaehlten Verschiebeanforderungen mit Resume-MoveRequest abschliessen
ui.selectedCountShort=0 ausgewaehlt
ui.colDisplayName=Anzeigename
ui.colStatus=Status
ui.colStatusDetail=Statusdetail
ui.colProgress=Fortschritt
ui.colTransferred=Uebertragen
ui.colTotalSize=Gesamtgroesse
ui.colItems=Items
ui.colBadItems=Bad Items
ui.colSourceDb=Quell-DB
ui.colTargetDb=Ziel-DB
ui.colBatch=Batch
ui.colStart=Start
ui.colCompletion=Abschluss
ui.footer=Exchange MoveRequest Live-Dashboard | Version %Version% | PowerShell HttpListener | Intervall: %Seconds% s |
ui.lightMode=Light-Modus |
ui.jsonApi=JSON-API
ui.stopServer=Server stoppen
ui.language=Sprache
ui.languageDe=Deutsch
ui.languageEn=English

js.noMailboxes=keine Postfaecher gefunden
js.loadedOf=%Done% von %Total% Postfaechern geladen
js.mailboxesLoadedOne=%Count% Postfach geladen
js.mailboxesLoadedMany=%Count% Postfaecher geladen
js.dashboardDataPending=Postfaecher geladen - Dashboard-Daten werden noch abgefragt ...
js.dashboardDataReady=Dashboard-Daten da - Postfaecher werden im Hintergrund geladen ...
js.lastUpdate=Letzte Aktualisierung: %Zeit%
js.dataAge=Datenalter: %Alter% s | Letzte Sammlung dauerte: %Dauer% s
js.detailPending= | Detaildaten offen: %Count%
js.failedCount= | Fehlgeschlagen: %Count%
js.updateAvailable=Update verfuegbar: %Tag%
js.timeout=Zeitueberschreitung nach %Seconds% s. Der Server sammelt noch oder ist blockiert. Letzte bekannte Daten bleiben stehen.
js.connectionLost=Verbindung zum Server verloren: %Message%
js.noData=Keine Daten vorhanden.
js.noMoveRequests=Keine MoveRequests vorhanden.
js.completedInactiveJobs=Abgeschlossene / Inaktive Jobs
js.statsUnavailable=Statistik nicht abrufbar: %Cause%
js.unknownCause=unbekannte Ursache
js.detailsLoading=Detaildaten werden nachgeladen.
js.detailsLoadingTitle=Detaildaten werden nachgeladen
js.selectToComplete=Auswaehlen, um mehrere Verschiebeanforderungen gemeinsam abzuschliessen
js.completeTitle=Diese Verschiebeanforderung abschliessen (Resume-MoveRequest)
js.complete=Abschliessen
js.databasesLoadError=Datenbanken konnten nicht geladen werden: %Message%
js.mailboxesLoadError=Fehler beim Laden der Postfaecher: %Message%
js.mailboxesQueried=Postfaecher abgefragt - Liste wird aufgebaut ...
js.noMatchingMailboxes=Keine passenden Postfaecher gefunden.
js.alreadyMoving=(bereits in Bewegung: %Status%)
js.unknown=unbekannt
js.archive=Archiv
js.mailboxTypeUser=Benutzerpostfaecher
js.mailboxTypeSpecial=Sonderpostfaecher
js.mailboxTypeArchive=Postfaecher mit Archiv
js.mailboxTypeAll=Benutzer- und Sonderpostfaecher
js.mailboxes=Postfaecher
js.visibleOf=%Visible% von %Total% %Type% sichtbar
js.source=(Quelle: %Source%)
js.allDatabases=(alle Datenbanken)
js.selected=%Count% Postfach/Postfaecher ausgewaehlt
js.modeSuspendHint=Der MoveRequest wird vor dem Abschluss angehalten (ReadyToComplete, klassische 95-%-Stufe). Die Finalisierung erfolgt spaeter, z. B. per Resume-MoveRequest - das Postfach wird vorher nicht gesperrt.
js.modeDirectHint=Die Postfaecher werden vollstaendig in die Ziel-Datenbank migriert und danach abgeschlossen.
js.checkOnly=Nur pruefen (WhatIf)
js.checkAndMove=Pruefen und verschieben
js.startMove=Verschiebeanforderung starten
js.pretestOnly=nur pruefen (nichts verschieben)
js.pretestCheckThenMove=erst pruefen, dann verschieben
js.pretestOff=aus (sofort verschieben)
js.selectTarget=Bitte eine Ziel-Datenbank auswaehlen.
js.sameDb=Quell- und Ziel-Datenbank sind identisch.
js.selectMailbox=Bitte mindestens ein Postfach auswaehlen.
js.confirmMove=%Count% Postfach/Postfaecher in die Datenbank "%Target%" verschieben?
js.confirmCheckOnly=%Count% Postfach/Postfaecher in der Datenbank "%Target%" nur pruefen (WhatIf)?
js.confirmMoveDetails=\n\nQuelle: %Source%\nPrioritaet: %Priority%\nBadItems ueberspringen: %BadItems%\nVorabtest: %Pretest%
js.confirmMode=\nModus: %Mode%
js.modeSuspendShort=bis 95 % laufen lassen und suspendieren
js.modeDirectShort=direkt durchmigrieren
js.whatIfStarted=WhatIf-Pruefung wird gestartet ...
js.jobStarted=Auftrag wird gestartet ...
js.jobStartedStrong=Auftrag #%Id% gestartet.
js.errorPrefix=Fehler: %Message%
js.actionRunning=Es laeuft bereits ein Vorgang - bitte kurz warten.
js.actionStarted=Aktion wird gestartet ...
js.confirmResumeBatch=Suspendierte Anforderungen im Batch "%Batch%" fortsetzen?\n\nResume-MoveRequest: die Verschiebung laeuft danach bis zum Abschluss weiter.
js.confirmResumeOne=Verschiebeanforderung von "%Name%" abschliessen?\n\nResume-MoveRequest fuer genau diese Anforderung:\ndie Verschiebung laeuft danach bis zum Abschluss weiter.
js.confirmResumeAll=Alle suspendierten MoveRequests fortsetzen?\n\nResume-MoveRequest fuer jede suspendierte Anforderung (alle Batches).
js.confirmDeleteBatch=Abgeschlossene Anforderungen im Batch "%Batch%" loeschen?\n\nRemove-MoveRequest - nur die MoveRequest-Eintraege werden entfernt, die Postfaecher bleiben unberuehrt.
js.confirmDeleteAll=Alle abgeschlossenen MoveRequests loeschen?\n\nRemove-MoveRequest - nur die MoveRequest-Eintraege werden entfernt, die Postfaecher bleiben unberuehrt.
js.confirmCompleteSelectedOne=1 ausgewaehlte Verschiebeanforderung abschliessen?
js.confirmCompleteSelectedMany=%Count% ausgewaehlte Verschiebeanforderungen abschliessen?
js.confirmCompleteSelectedDetails=\n\nResume-MoveRequest fuer:\n%List%%Rest%\n\nDie Verschiebungen laufen danach bis zum Abschluss weiter.
js.andMore=\n  ... und %Count% weitere
js.selectedInTable=%Count% ausgewaehlt
js.resumeSuspended=Suspendierte abschliessen
js.deleteCompleted=Abgeschlossene loeschen
js.statusRunning=Laufend
js.statusCompleted=Abgeschlossen
js.statusFailed=Fehlgeschlagen
js.resumeDone=suspendierte Anforderungen fortgesetzt
js.removeDone=abgeschlossene Anforderungen entfernt
js.moveRequestsCreated=MoveRequests erstellt
js.errors=Fehler
js.suspendBeforeComplete=suspendieren vor Abschluss
js.migrateThrough=durchmigrieren
js.priorityLabel=Prioritaet: %Value%
js.badItemsLabel=BadItems: %Value%
js.whatIfOnly=nur pruefen
js.whatIfCheckMove=pruefen + verschieben
js.batchLabel=Batch: %Value%
js.startLabel=Start: %Value%
js.statusQueryFailed=Statusabfrage fehlgeschlagen: %Message%
js.confirmStop=Moechten Sie den Dashboard-Server wirklich stoppen?
js.serverStopped=Server wurde gestoppt.
js.serverStoppedDisconnected=Server gestoppt (Verbindung getrennt).
js.start=START
js.stopped=GESTOPPT
js.timeoutStatus=TIMEOUT
js.offline=OFFLINE
js.filterArchive=archiv

msg.noMailboxesSelected=Keine Postfaecher ausgewaehlt.
msg.noTargetDb=Keine Ziel-Datenbank angegeben.
msg.sourceTargetSame=Quell- und Ziel-Datenbank sind identisch.
msg.targetNotFound=Ziel-Datenbank '%Target%' wurde nicht gefunden: %Error%
msg.targetNotMounted=Die Ziel-Datenbank '%Target%' ist nicht bereitgestellt (nicht gemountet). Dorthin koennen keine MoveRequests erstellt werden.
msg.invalidPriority=Unzulaessige Prioritaet '%Priority%'. Erlaubt: %Allowed%.
msg.invalidPretest=Unzulaessiger Vorabtest '%Pretest%'. Erlaubt: aus, pruefen, nur.
msg.invalidBadItems=Unzulaessiger BadItemLimit '%Value%'. Erlaubt: %Allowed%.
msg.sourceNotFound=Quell-Datenbank '%Source%' wurde nicht gefunden: %Error%
msg.suspendUnavailable=Der Parameter -SuspendWhenReadyToComplete steht auf diesem Server nicht zur Verfuegung. Es kann nicht suspendiert werden.
msg.jobStartFailed=Der Hintergrund-Job konnte nicht gestartet werden: %Error%
msg.jobGone=Der Hintergrund-Job ist nicht mehr vorhanden (Skript evtl. neu gestartet).
msg.resumeCount=%Done% von %Total% suspendierten Anforderungen fortgesetzt, %Errors% Fehler.
msg.removeCount=%Done% von %Total% abgeschlossenen Anforderungen entfernt, %Errors% Fehler.
msg.whatIfPassedCount=%Done% von %Total% Postfaechern bestanden die WhatIf-Pruefung, %Errors% Fehler. Es wurden keine MoveRequests erstellt.
msg.createdAfterWhatIf=%Done% von %Total% MoveRequests erstellt (alle bestanden zuerst die WhatIf-Pruefung), %Errors% Fehler.
msg.createdCount=%Done% von %Total% MoveRequests erstellt, %Errors% Fehler.
msg.actionNoTarget=Es wurde weder eine Anforderung noch ein Batch noch 'alle' angegeben.
msg.commandUnavailable=%Command% ist auf diesem Server nicht verfuegbar: %Error%
msg.requestNotFoundSingle=Die Anforderung '%Identity%' ist keine %Word% Anforderung (mehr).
msg.noneOfSelected=Keine der %Count% ausgewaehlten Anforderungen ist (mehr) eine %Word% Anforderung.
msg.noMatchingMoveRequests=Keine %Word% MoveRequests gefunden.
msg.noneInBatch=Im Batch '%Batch%' ist keine %Word% Anforderung vorhanden.
msg.moveQueryFailed=Die MoveRequests konnten nicht abgefragt werden: %Error%
msg.resumeDone=Anforderung fortgesetzt - die Verschiebung laeuft jetzt bis zum Abschluss weiter.
msg.removeDone=Abgeschlossene Anforderung entfernt - das Postfach bleibt unberuehrt.
msg.actionStartedResume=Fortsetzung: %Count% (%Selection%) - Resume-MoveRequest laeuft im Hintergrund, die Postfaecher ziehen bis zum Abschluss durch.
msg.actionStartedRemove=Entfernen: %Count% (%Selection%) - Remove-MoveRequest laeuft im Hintergrund, nur die Anforderungs-Eintraege, die Postfaecher bleiben unberuehrt.
msg.batchLabel=Batch '%Batch%'
msg.allRequests=alle Anforderungen
msg.multipleSelection=Mehrfachauswahl
msg.requestSingular=%Count% Anforderung
msg.requestPlural=%Count% Anforderungen
msg.databasesLoadFailed=Datenbanken konnten nicht ermittelt werden: %Error%
msg.mailboxesLoadFailed=Postfaecher konnten nicht geladen werden: %Error%
msg.incompleteRequest=Unvollstaendige Anfrage.
msg.unexpectedShippingResponse=Unerwartete Rueckmeldung vom Versand-Modul.
msg.unexpectedActionResponse=Unerwartete Rueckmeldung vom Aktion-Modul.
msg.statusLoadFailed=Status konnte nicht ermittelt werden: %Error%
msg.noActionSpecified=Keine Aktion angegeben (Resume oder Entfernen).
msg.noRequestBody=Kein Request-Body uebermittelt.
msg.whatIfPassed=WhatIf-Pruefung bestanden - das Postfaecher ist verschiebbar, es wurde nichts erstellt.
msg.whatIfFailed=WhatIf-Pruefung fehlgeschlagen: %Error%
msg.moveCreatedSuspend=MoveRequest erstellt - haelt vor dem Abschluss an (95 %), Prioritaet: %Priority%.
msg.moveCreatedDirect=MoveRequest erstellt - wird durchgehend migriert, Prioritaet: %Priority%.
msg.snapinLoadFailed=Exchange Snap-In konnte nicht geladen werden: %Error%
msg.statsUnavailable=Statistik nicht abrufbar
msg.mailboxQueryFailed=Postfachabfrage '%Source%' schlug fehl: %Error%
msg.elevationDeniedText=Das Skript wurde NICHT als Administrator gestartet (UAC abgelehnt).\n\nSystem- und Arbitration-Postfaecher lassen sich dann nicht verschieben - Exchange meldet 'Der Zugriff wurde verweigert'.\n\nBitte erneut starten und der UAC-Frage zustimmen.
msg.elevationDeniedTitle=Exchange-MoveRequest-Dashboard - ohne Admin-Rechte

# --- Konsole und Logdatei (v2.16) ----------------------------------------
log.level.info=INFO
log.level.warn=WARNUNG
log.level.error=FEHLER
log.level.silent=STILL
log.stopSent=/api/stop an die andere Instanz gesendet.
log.stopFailed=/api/stop nicht moeglich: %Error%
log.foreignService=%Phase%: Auf Port %Port% antwortet ein fremder Dienst - der Start wird voraussichtlich fehlschlagen.
log.hint=HINWEIS: %Message%
log.otherInstanceOne=Es laeuft bereits eine weitere Dashboard-Instanz:
log.otherInstanceMany=Es laeuft bereits %Count% weitere Dashboard-Instanzen:
log.processLine=  PID %Pid% (%Process%): %CommandLine%
log.noProcessConsole=  (kein Prozess mit Skriptnamen gefunden - vermutlich in einer offenen Konsole gestartet)
log.alreadyRunningNoStop=%Phase%: Auf Port %Port% laeuft bereits ein Dashboard - wird NICHT gestoppt (-KeinAutoStopp).
log.alreadyRunningStop=%Phase%: Auf Port %Port% laeuft bereits ein Dashboard - die alte Instanz wird jetzt beendet.
log.runningInstance=  Laufende Instanz: PID %Pid% (%Process%), Port %Port%: %CommandLine%
log.noProcessStop=  (kein Prozess mit Skriptnamen gefunden - Konsole? Der Stopp laeuft trotzdem ueber /api/stop)
log.forceKill=  Sauberer Stopp reichte nicht - beende hart: PID %Pid% (%Process%)
log.killFailed=  PID %Pid% konnte nicht beendet werden: %Error%
log.oldStopped=%Phase%: Alte Instanz beendet - %Url% ist frei, der Start kann weitergehen.
log.rotated=== Log rotiert: vorige Datei liegt als %File% vor ===
log.suppressed=    ==> %Count%x in den letzten %Seconds%s aufgetreten, nicht einzeln protokolliert
log.moveJobStarted=Verschiebeauftrag #%Id% gestartet: %Count% Postfach/Postfaecher, '%Source%' -> '%Target%', Prioritaet: %Priority%, BadItemLimit: %BadItemLimit%, Vorabtest: %Pretest%, Modus: %Mode%, Batch: %Batch%
log.actionJobResumed=%Label% #%Id% abgeschlossen: %Done% suspendierte Anforderung/Anforderungen fortgesetzt.
log.actionJobRemoved=%Label% #%Id% abgeschlossen: %Done% abgeschlossene Anforderung/Anforderungen entfernt.
log.actionJobChecked=%Label% #%Id% abgeschlossen: WhatIf-Pruefung, %Done% von %Total% bestanden.
log.actionJobCreated=%Label% #%Id% abgeschlossen: %Done% MoveRequest(s) erstellt.
log.actionJobFailed=%Label% #%Id% %Status%: %Done% %Action%, %Errors% Fehler. %Message%
log.moveJob=Verschiebeauftrag
log.actionWordCreated=erstellt
log.actionWordResumed=fortgesetzt
log.actionWordRemoved=entfernt
log.modeSuspend=suspendieren vor dem Abschluss (95 %)
log.modeDirect=durchgaengige Migration
log.pretestCheckMove=Vorabtest mit -WhatIf, danach erstellen
log.pretestOnly=nur -WhatIf-Pruefung, nichts erstellen
log.pretestNone=kein Vorabtest
log.badItems=BadItems: %Value%
log.startWhatIfOnly=%Count% Postfach/Postfaecher werden nur mit -WhatIf geprueft - es wird nichts verschoben (Batch: %Batch%).
log.startCheckThen=%Count% Postfach/Postfaecher werden zuerst mit -WhatIf geprueft und danach nach '%Target%' verschoben (Prioritaet: %Priority%, %BadItems%, Batch: %Batch%).
log.startDirect=%Count% Postfach/Postfaecher werden nach '%Target%' verschoben (Prioritaet: %Priority%, %BadItems%, Batch: %Batch%).
log.runningInstanceOnly=  Laufende Instanz: %Instance%
log.scriptFailed=Skript wurde mit Fehlern beendet. Details siehe Log: %Path%
log.netshAcl=  netsh http add urlacl url=%Url% user=%User%
log.actionStarted=MoveRequest-Aktion #%Id% gestartet: %Action%, %Count%, Auswahl: %Selection%
log.statsPoolOpen=Statistik-Pool mit bis zu %Count% parallelen Abrufen geoeffnet.
log.statsPoolFailed=Statistik-Pool nicht nutzbar: %Error%
log.statsParallelEmpty=Paralleler Statistikabruf lieferte kein einziges Ergebnis - schalte ab und wiederhole sequenziell.
log.cacheCollision=Cache-Kollision fuer Schluessel '%Key%' erkannt (Cache: '%Cached%', aktuell: '%Current%') - frage neu ab.
log.statsFetchFailed=  Statistik-Abruf fehlgeschlagen fuer '%Name%': %Error%
log.allFinished=Alle %Count% MoveRequests sind in einem Endzustand. Es wird nur noch alle %Seconds% s geprueft.
log.apiError=API: %Error%
log.apiMissingStats=API: %Count% MoveRequest(s) ohne Statistik (nur die ersten 3 einzeln protokolliert).
log.apiCause=  Ursache (%Count%x): %Cause%
log.envelopeHint=HINWEIS: Envelope-Groesse ist der Engpass. In einer Exchange Management Shell ausfuehren und Skript neu starten:
log.envelopeCmd=  Set-PowerShellConfig -Identity WSMan:localhost -MaxEnvelopeSizeKb 16384
log.updateAvailable=Update verfuegbar: %Tag% (aktuell v%Version%) - %Url%
log.updateNone=Update-Check abgeschlossen: keine neuere Version als v%Version% gefunden.
log.logDirCreated=Log-Verzeichnis erstellt: %Path%
log.startBanner=== Live-Dashboard wird gestartet ===
log.intervals=Intervall: %Interval% s | Snapshot-Cache: %Cache% s | Abfrage-Timeout: %Timeout% s | Leerlaufintervall: %Idle% s
log.batchFilter=Batch-Filter aktiv: %Batch%
log.lightMode=Light-Modus aktiv (-Light): es werden nur Statusdaten geliefert - Get-MoveRequestStatistics bleibt aus, technische Spalten sind im Dashboard ausgeblendet.
log.noAdminNoPath=Ohne Admin-Rechte und ohne Skriptpfad (Start ueber eine Pipe?) - Weiterlauf ohne Erhoehung.
log.elevationRequested=Ohne Admin-Rechte gestartet - Neustart als Administrator eingeleitet (UAC-Frage). Das Ausgangsfenster schliesst sich, der erhoehte Neustart uebernimmt.
log.elevationDenied=Erhoehung abgelehnt (UAC) - das Skript laeuft NICHT als Administrator. System-/Arbitration-Postfaecher scheitern dann mit 'Der Zugriff wurde verweigert'.
log.elevationFailed=Erhoehung fehlgeschlagen: %Error% - Weiterlauf ohne Admin-Rechte.
log.otherInstanceKeeps=Die andere Instanz laeuft weiter und haelt %Url% - Start abgebrochen.
log.manualSearch=  Manuell suchen: Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Moverequest-Dashboard' } | Select-Object ProcessId, CommandLine
log.startOtherPort=  Oder abweichend starten: .\Exchange-MoveRequest-Dashboard.ps1 -Port 9090
log.expectedError32=Der Start wird voraussichtlich mit Fehler 32 scheitern - siehe Fehlerbehebung im Wiki.
log.context=Ausfuehrungskontext: %Name%, Administrator: %Admin%, PowerShell %Version% (%Bitness%)
log.updateDisabled=Update-Check deaktiviert (-KeinUpdateCheck).
log.updateStarted=Update-Check gegen GitLab-Releases gestartet (Projekt-ID %Id%, asynchron).
log.updateStartFailed=Update-Check konnte nicht gestartet werden: %Error%
log.snapinLoading=Lade Exchange PowerShell Snap-In (2019/SE)...
log.snapinLoaded=Exchange PowerShell Snap-In erfolgreich geladen.
log.snapinAlreadyLoaded=Exchange PowerShell Snap-In ist bereits geladen.
log.firstCollection=Erste Datensammlung wird durchgefuehrt ...
log.firstCollectionDone=Erste Sammlung (Grunddaten): %Count% MoveRequest(s), %Details% Detailzeile(n), %Seconds%s
log.detailsLater=Detaildaten (Prozent, Groessen, Zeiten) fuer %Count% Job(s) werden im naechsten Lauf nachgeholt.
log.prefixHeld=Das Praefix '%Url%' haelt weiterhin eine andere Instanz.
log.serverStartFailed=Fehler beim Starten des HTTP-Servers: %Error%
log.prefixBusy=Das URL-Praefix '%Url%' war zwischen Pruefung und Start belegt - neuer Versuch (%Attempt% von %Max%) nach erneuter Freimachung.
log.serverStarted=HTTP-Server gestartet auf: %Url%
log.openBrowser=Dashboard im Browser oeffnen: %Url%
log.stopHint=Zum Beenden: Strg+C oder im Dashboard 'Server stoppen' klicken.
log.causePrefix=URSACHE: Das URL-Praefix '%Url%' war schon vergeben - fast immer durch ein zweites Dashboard. Auch die alte Version 'live_moverequest_statistik.ps1' reserviert denselben Port.
log.diagnose=  %Text%
log.help1=ABHILFE 1: die andere Instanz beenden (Fenster schliessen bzw. PID beenden).
log.help2=ABHILFE 2: abweichend starten: .\Exchange-MoveRequest-Dashboard.ps1 -Port 9090
log.help3=ABHILFE 3: zum Nachsehen IM FEHLERFALL: netstat -ano | findstr :%Port%  und  netsh http show urlacl | findstr :%Port%
log.tip=TIPP: Skript als Administrator ausfuehren oder Port freigeben:
log.browserOpened=Browser geoeffnet.
log.browserFailed=Browser konnte nicht automatisch geoeffnet werden.
log.serverStopRequested=Server-Stop angefordert.
log.connectionClosed=Verbindung vom Browser geschlossen - Anfrage abgebrochen (beim Stoppen oder Schliessen des Tabs ganz normal).
log.listenerError=HTTP-Listener Fehler: %Error%
log.requestError=Fehler bei Anfrageverarbeitung: %Error%
log.critical=KRITISCHER FEHLER: %Error%
log.stack=Stack Trace: %Trace%
log.serverStopped=HTTP-Server sauber heruntergefahren.
log.stopFailed=Fehler beim Beenden des HTTP-Servers: %Error%
log.jobsStopped=Offene Verschiebe-Jobs beendet.
log.jobsStopFailed=Fehler beim Beenden der Verschiebe-Jobs: %Error%
log.runtime=Laufzeit: %Minutes% min | %Collections% Sammlung(en), %Queries% Statistikabruf(e), %CacheHits% Cache-Treffer
log.endBanner=== Live-Dashboard beendet ===
'@

    en = @'
ui.title=Exchange MoveRequest Live Dashboard
ui.subtitle=Server: %Server% | Refresh every %Seconds% seconds
ui.versionTitle=Script version (from the .NOTES block)
ui.updateBadgeTitle=Opens the release page of this project in the browser.
ui.updateBadge=Update available
ui.lastUpdateLoading=Last update: loading...
ui.live=LIVE
ui.loadingStart=Dashboard is starting ...
ui.totalMoveRequests=Total move requests:
ui.updates=Updates:
ui.newMoveRequest=New move request
ui.sourceDb=Source database (empty = all mailboxes)
ui.allDatabases=-- all databases --
ui.targetDb=Target database
ui.pleaseChoose=-- please choose --
ui.priority=Priority (-Priority)
ui.priorityLow=Low
ui.priorityNormal=Normal (default)
ui.priorityHigh=High
ui.priorityCritical=Critical
ui.priorityEmergency=Emergency
ui.badItems=Skip bad items (-BadItemLimit)
ui.badItemsNone=0 - none (default)
ui.mode=Mode
ui.modeDirect=Migrate straight through (until Completed)
ui.modeSuspend=Run to 95 % and suspend
ui.pretest=Pretest with -WhatIf
ui.pretestOff=off (move immediately)
ui.pretestCheckThenMove=check first, then move
ui.pretestOnly=check only (move nothing)
ui.mailboxType=Mailbox type
ui.mailboxTypeTitle=Special mailboxes are intentionally hidden in the normal view
ui.mailboxTypeUser=User mailboxes
ui.mailboxTypeSpecial=Special mailboxes (Arbitration, AuditLog, AuxAuditLog, PublicFolder, Archive)
ui.mailboxTypeArchive=Mailboxes with archive
ui.mailboxTypeAll=All (user and special mailboxes)
ui.filterMailboxes=Filter mailboxes
ui.filterMailboxesPlaceholder=Filter by name, address, alias, type or database
ui.selectAllVisible=Select all visible
ui.clearSelection=Clear selection
ui.mailboxesLoading=Mailboxes are loading ...
ui.startMoveRequest=Start move request
ui.selectedCount=0 mailbox/mailboxes selected
ui.resumeAllSuspended=Complete all suspended
ui.deleteAllCompleted=Delete all completed
ui.backgroundJobNote=Resume-MoveRequest or Remove-MoveRequest - runs as a background job
ui.detailsHeading=Detailed MoveRequest overview
ui.sortHint=Sort order: active jobs (InProgress, Queued) are always shown first
ui.searchPlaceholder=Search by name, status, database, batch...
ui.selectAllVisibleSuspendedTitle=Select all visible suspended requests (respects the search filter)
ui.completeSelection=Complete selection
ui.completeSelectionTitle=Complete the selected move requests with Resume-MoveRequest
ui.selectedCountShort=0 selected
ui.colDisplayName=Display name
ui.colStatus=Status
ui.colStatusDetail=Status detail
ui.colProgress=Progress
ui.colTransferred=Transferred
ui.colTotalSize=Total size
ui.colItems=Items
ui.colBadItems=Bad items
ui.colSourceDb=Source DB
ui.colTargetDb=Target DB
ui.colBatch=Batch
ui.colStart=Start
ui.colCompletion=Completion
ui.footer=Exchange MoveRequest Live Dashboard | Version %Version% | PowerShell HttpListener | Interval: %Seconds% s |
ui.lightMode=light mode |
ui.jsonApi=JSON API
ui.stopServer=Stop server
ui.language=Language
ui.languageDe=Deutsch
ui.languageEn=English

js.noMailboxes=no mailboxes found
js.loadedOf=%Done% of %Total% mailboxes loaded
js.mailboxesLoadedOne=%Count% mailbox loaded
js.mailboxesLoadedMany=%Count% mailboxes loaded
js.dashboardDataPending=Mailboxes loaded - dashboard data is still being fetched ...
js.dashboardDataReady=Dashboard data ready - mailboxes are loading in the background ...
js.lastUpdate=Last update: %Zeit%
js.dataAge=Data age: %Alter% s | Last collection took: %Dauer% s
js.detailPending= | details pending: %Count%
js.failedCount= | failed: %Count%
js.updateAvailable=Update available: %Tag%
js.timeout=Timeout after %Seconds% s. The server is still collecting or blocked. The last known data remains visible.
js.connectionLost=Connection to the server lost: %Message%
js.noData=No data available.
js.noMoveRequests=No move requests found.
js.completedInactiveJobs=Completed / inactive jobs
js.statsUnavailable=Statistics unavailable: %Cause%
js.unknownCause=unknown cause
js.detailsLoading=Detail data is being loaded.
js.detailsLoadingTitle=Detail data is being loaded
js.selectToComplete=Select to complete several move requests together
js.completeTitle=Complete this move request (Resume-MoveRequest)
js.complete=Complete
js.databasesLoadError=Databases could not be loaded: %Message%
js.mailboxesLoadError=Error loading mailboxes: %Message%
js.mailboxesQueried=Mailboxes queried - building the list ...
js.noMatchingMailboxes=No matching mailboxes found.
js.alreadyMoving=(already moving: %Status%)
js.unknown=unknown
js.archive=Archive
js.mailboxTypeUser=user mailboxes
js.mailboxTypeSpecial=special mailboxes
js.mailboxTypeArchive=mailboxes with archive
js.mailboxTypeAll=user and special mailboxes
js.mailboxes=mailboxes
js.visibleOf=%Visible% of %Total% %Type% visible
js.source=(source: %Source%)
js.allDatabases=(all databases)
js.selected=%Count% mailbox/mailboxes selected
js.modeSuspendHint=The move request stops before completion (ReadyToComplete, the classic 95 % stage). Finalization happens later, e.g. with Resume-MoveRequest - the mailbox is not locked before that.
js.modeDirectHint=The mailboxes are migrated completely to the target database and then finalized.
js.checkOnly=Check only (WhatIf)
js.checkAndMove=Check and move
js.startMove=Start move request
js.pretestOnly=check only (move nothing)
js.pretestCheckThenMove=check first, then move
js.pretestOff=off (move immediately)
js.selectTarget=Please select a target database.
js.sameDb=Source and target database are identical.
js.selectMailbox=Please select at least one mailbox.
js.confirmMove=Move %Count% mailbox/mailboxes to database "%Target%"?
js.confirmCheckOnly=Check %Count% mailbox/mailboxes in database "%Target%" only (WhatIf)?
js.confirmMoveDetails=\n\nSource: %Source%\nPriority: %Priority%\nSkip bad items: %BadItems%\nPretest: %Pretest%
js.confirmMode=\nMode: %Mode%
js.modeSuspendShort=run to 95 % and suspend
js.modeDirectShort=migrate straight through
js.whatIfStarted=WhatIf check is starting ...
js.jobStarted=Job is starting ...
js.jobStartedStrong=Job #%Id% started.
js.errorPrefix=Error: %Message%
js.actionRunning=Another operation is already running - please wait a moment.
js.actionStarted=Action is starting ...
js.confirmResumeBatch=Resume suspended requests in batch "%Batch%"?\n\nResume-MoveRequest: the move then continues until completion.
js.confirmResumeOne=Complete the move request for "%Name%"?\n\nResume-MoveRequest for exactly this request:\nthe move then continues until completion.
js.confirmResumeAll=Resume all suspended move requests?\n\nResume-MoveRequest for every suspended request (all batches).
js.confirmDeleteBatch=Delete completed requests in batch "%Batch%"?\n\nRemove-MoveRequest - only the move request entries are removed, the mailboxes remain untouched.
js.confirmDeleteAll=Delete all completed move requests?\n\nRemove-MoveRequest - only the move request entries are removed, the mailboxes remain untouched.
js.confirmCompleteSelectedOne=Complete 1 selected move request?
js.confirmCompleteSelectedMany=Complete %Count% selected move requests?
js.confirmCompleteSelectedDetails=\n\nResume-MoveRequest for:\n%List%%Rest%\n\nThe moves then continue until completion.
js.andMore=\n  ... and %Count% more
js.selectedInTable=%Count% selected
js.resumeSuspended=Complete suspended
js.deleteCompleted=Delete completed
js.statusRunning=Running
js.statusCompleted=Completed
js.statusFailed=Failed
js.resumeDone=suspended requests resumed
js.removeDone=completed requests removed
js.moveRequestsCreated=move requests created
js.errors=errors
js.suspendBeforeComplete=suspend before completion
js.migrateThrough=migrate straight through
js.priorityLabel=Priority: %Value%
js.badItemsLabel=Bad items: %Value%
js.whatIfOnly=check only
js.whatIfCheckMove=check + move
js.batchLabel=Batch: %Value%
js.startLabel=Start: %Value%
js.statusQueryFailed=Status query failed: %Message%
js.confirmStop=Do you really want to stop the dashboard server?
js.serverStopped=Server stopped.
js.serverStoppedDisconnected=Server stopped (connection closed).
js.start=START
js.stopped=STOPPED
js.timeoutStatus=TIMEOUT
js.offline=OFFLINE
js.filterArchive=archive

msg.noMailboxesSelected=No mailboxes selected.
msg.noTargetDb=No target database specified.
msg.sourceTargetSame=Source and target database are identical.
msg.targetNotFound=Target database '%Target%' was not found: %Error%
msg.targetNotMounted=Target database '%Target%' is not mounted. No move requests can be created for it.
msg.invalidPriority=Invalid priority '%Priority%'. Allowed: %Allowed%.
msg.invalidPretest=Invalid pretest '%Pretest%'. Allowed: off, check, only.
msg.invalidBadItems=Invalid BadItemLimit '%Value%'. Allowed: %Allowed%.
msg.sourceNotFound=Source database '%Source%' was not found: %Error%
msg.suspendUnavailable=The parameter -SuspendWhenReadyToComplete is not available on this server. Suspending is not possible.
msg.jobStartFailed=The background job could not be started: %Error%
msg.jobGone=The background job no longer exists (script may have been restarted).
msg.resumeCount=%Done% of %Total% suspended requests resumed, %Errors% errors.
msg.removeCount=%Done% of %Total% completed requests removed, %Errors% errors.
msg.whatIfPassedCount=%Done% of %Total% mailboxes passed the WhatIf check, %Errors% errors. No move requests were created.
msg.createdAfterWhatIf=%Done% of %Total% move requests created (all passed the WhatIf check first), %Errors% errors.
msg.createdCount=%Done% of %Total% move requests created, %Errors% errors.
msg.actionNoTarget=Neither a request nor a batch nor 'all' was specified.
msg.commandUnavailable=%Command% is not available on this server: %Error%
msg.requestNotFoundSingle=Request '%Identity%' is no longer a %Word% request.
msg.noneOfSelected=None of the %Count% selected requests is (still) a %Word% request.
msg.noMatchingMoveRequests=No %Word% move requests found.
msg.noneInBatch=No %Word% request exists in batch '%Batch%'.
msg.moveQueryFailed=The move requests could not be queried: %Error%
msg.resumeDone=Request resumed - the move now continues until completion.
msg.removeDone=Completed request removed - the mailbox remains untouched.
msg.actionStartedResume=Resume: %Count% (%Selection%) - Resume-MoveRequest runs in the background, the mailboxes continue until completion.
msg.actionStartedRemove=Remove: %Count% (%Selection%) - Remove-MoveRequest runs in the background, only the request entries are removed, the mailboxes remain untouched.
msg.batchLabel=batch '%Batch%'
msg.allRequests=all requests
msg.multipleSelection=multiple selection
msg.requestSingular=%Count% request
msg.requestPlural=%Count% requests
msg.databasesLoadFailed=Databases could not be determined: %Error%
msg.mailboxesLoadFailed=Mailboxes could not be loaded: %Error%
msg.incompleteRequest=Incomplete request.
msg.unexpectedShippingResponse=Unexpected response from the move module.
msg.unexpectedActionResponse=Unexpected response from the action module.
msg.statusLoadFailed=Status could not be determined: %Error%
msg.noActionSpecified=No action specified (Resume or Remove).
msg.noRequestBody=No request body submitted.
msg.whatIfPassed=WhatIf check passed - the mailbox can be moved, nothing was created.
msg.whatIfFailed=WhatIf check failed: %Error%
msg.moveCreatedSuspend=Move request created - stops before completion (95 %), priority: %Priority%.
msg.moveCreatedDirect=Move request created - migrates straight through, priority: %Priority%.
msg.snapinLoadFailed=Exchange snap-in could not be loaded: %Error%
msg.statsUnavailable=Statistics unavailable
msg.mailboxQueryFailed=Mailbox query '%Source%' failed: %Error%
msg.elevationDeniedText=The script was NOT started as administrator (UAC declined).\n\nSystem and arbitration mailboxes cannot be moved in this state - Exchange reports 'Access is denied'.\n\nPlease start it again and accept the UAC prompt.
msg.elevationDeniedTitle=Exchange-MoveRequest-Dashboard - without administrator rights

# --- Console and log file (v2.16) ----------------------------------------
log.level.info=INFO
log.level.warn=WARNING
log.level.error=ERROR
log.level.silent=SILENT
log.stopSent=/api/stop sent to the other instance.
log.stopFailed=/api/stop not possible: %Error%
log.foreignService=%Phase%: port %Port% is answered by a foreign service - startup will probably fail.
log.hint=NOTE: %Message%
log.otherInstanceOne=Another dashboard instance is already running:
log.otherInstanceMany=%Count% other dashboard instances are already running:
log.processLine=  PID %Pid% (%Process%): %CommandLine%
log.noProcessConsole=  (no process with the script name found - probably started in an open console)
log.alreadyRunningNoStop=%Phase%: a dashboard is already running on port %Port% - NOT stopped (-KeinAutoStopp).
log.alreadyRunningStop=%Phase%: a dashboard is already running on port %Port% - the old instance is being stopped now.
log.runningInstance=  Running instance: PID %Pid% (%Process%), port %Port%: %CommandLine%
log.noProcessStop=  (no process with the script name found - console? The stop is attempted via /api/stop anyway)
log.forceKill=  Clean stop was not enough - terminating hard: PID %Pid% (%Process%)
log.killFailed=  PID %Pid% could not be terminated: %Error%
log.oldStopped=%Phase%: old instance stopped - %Url% is free, startup can continue.
log.rotated=== Log rotated: the previous file is kept as %File% ===
log.suppressed=    ==> occurred %Count%x in the last %Seconds% s, not logged individually
log.moveJobStarted=Move job #%Id% started: %Count% mailbox/mailboxes, '%Source%' -> '%Target%', priority: %Priority%, BadItemLimit: %BadItemLimit%, pretest: %Pretest%, mode: %Mode%, batch: %Batch%
log.actionJobResumed=%Label% #%Id% completed: %Done% suspended request/requests resumed.
log.actionJobRemoved=%Label% #%Id% completed: %Done% completed request/requests removed.
log.actionJobChecked=%Label% #%Id% completed: WhatIf check, %Done% of %Total% passed.
log.actionJobCreated=%Label% #%Id% completed: %Done% move request(s) created.
log.actionJobFailed=%Label% #%Id% %Status%: %Done% %Action%, %Errors% errors. %Message%
log.missingRequests=Move request action: %Missing% of %Selected% selected requests not found: '%List%'.
log.actionStarted=Move request action #%Id% started: %Action%, %Count%, selection: %Selection%
log.statsPoolOpen=Statistics pool opened with up to %Count% parallel fetches.
log.statsPoolFailed=Statistics pool not usable: %Error%
log.statsParallelEmpty=Parallel statistics fetch returned no result at all - switching off and retrying sequentially.
log.cacheCollision=Cache collision detected for key '%Key%' (cache: '%Cached%', current: '%Current%') - fetching again.
log.statsFetchFailed=  Statistics fetch failed for '%Name%': %Error%
log.allFinished=All %Count% move requests are in a final state. Checking only every %Seconds% s now.
log.apiError=API: %Error%
log.apiMissingStats=API: %Count% move request(s) without statistics (only the first 3 logged individually).
log.apiCause=  Cause (%Count%x): %Cause%
log.envelopeHint=NOTE: envelope size is the bottleneck. Run in an Exchange Management Shell and restart the script:
log.envelopeCmd=  Set-PowerShellConfig -Identity WSMan:localhost -MaxEnvelopeSizeKb 16384
log.updateAvailable=Update available: %Tag% (current v%Version%) - %Url%
log.updateNone=Update check finished: no version newer than v%Version% found.
log.logDirCreated=Log directory created: %Path%
log.startBanner=== Live dashboard is starting ===
log.intervals=Interval: %Interval% s | snapshot cache: %Cache% s | query timeout: %Timeout% s | idle interval: %Idle% s
log.batchFilter=Batch filter active: %Batch%
log.lightMode=Light mode active (-Light): only status data is delivered - Get-MoveRequestStatistics is skipped, technical columns are hidden in the dashboard.
log.noAdminNoPath=Started without administrator rights and without a script path (started via a pipe?) - continuing without elevation.
log.elevationRequested=Started without administrator rights - restart as administrator initiated (UAC prompt). The original window closes, the elevated restart takes over.
log.elevationDenied=Elevation declined (UAC) - the script is NOT running as administrator. System/arbitration mailboxes will then fail with 'Access is denied'.
log.elevationFailed=Elevation failed: %Error% - continuing without administrator rights.
log.otherInstanceKeeps=The other instance keeps running and holds %Url% - startup aborted.
log.manualSearch=  Search manually: Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Moverequest-Dashboard' } | Select-Object ProcessId, CommandLine
log.startOtherPort=  Or start differently: .\Exchange-MoveRequest-Dashboard.ps1 -Port 9090
log.expectedError32=Startup will probably fail with error 32 - see troubleshooting in the wiki.
log.context=Execution context: %Name%, administrator: %Admin%, PowerShell %Version% (%Bitness%)
log.updateDisabled=Update check disabled (-KeinUpdateCheck).
log.updateStarted=Update check against GitLab releases started (project ID %Id%, asynchronous).
log.updateStartFailed=Update check could not be started: %Error%
log.snapinLoading=Loading Exchange PowerShell snap-in (2019/SE)...
log.snapinLoaded=Exchange PowerShell snap-in loaded successfully.
log.snapinAlreadyLoaded=Exchange PowerShell snap-in is already loaded.
log.firstCollection=First data collection is running ...
log.firstCollectionDone=First collection (base data): %Count% move request(s), %Details% detail row(s), %Seconds% s
log.detailsLater=Detail data (percent, sizes, times) for %Count% job(s) will be fetched in the next run.
log.prefixHeld=The prefix '%Url%' is still held by another instance.
log.serverStartFailed=Error starting the HTTP server: %Error%
log.prefixBusy=The URL prefix '%Url%' was taken between check and start - retrying (%Attempt% of %Max%) after releasing it again.
log.serverStarted=HTTP server started at: %Url%
log.openBrowser=Open the dashboard in the browser: %Url%
log.stopHint=To stop: Ctrl+C or click 'Stop server' in the dashboard.
log.causePrefix=CAUSE: the URL prefix '%Url%' was already taken - almost always by a second dashboard. The old version 'live_moverequest_statistik.ps1' reserves the same port as well.
log.diagnose=  %Text%
log.help1=REMEDY 1: stop the other instance (close the window or terminate the PID).
log.help2=REMEDY 2: start differently: .\Exchange-MoveRequest-Dashboard.ps1 -Port 9090
log.help3=REMEDY 3: for inspection IN THE ERROR CASE: netstat -ano | findstr :%Port%  and  netsh http show urlacl | findstr :%Port%
log.tip=TIP: run the script as administrator or free the port:
log.browserOpened=Browser opened.
log.browserFailed=Browser could not be opened automatically.
log.serverStopRequested=Server stop requested.
log.connectionClosed=Connection closed by the browser - request aborted (normal when stopping or closing the tab).
log.listenerError=HTTP listener error: %Error%
log.requestError=Error while processing the request: %Error%
log.critical=CRITICAL ERROR: %Error%
log.stack=Stack trace: %Trace%
log.serverStopped=HTTP server shut down cleanly.
log.stopFailed=Error stopping the HTTP server: %Error%
log.jobsStopped=Open move jobs stopped.
log.jobsStopFailed=Error stopping the move jobs: %Error%
log.runtime=Runtime: %Minutes% min | %Collections% collection(s), %Queries% statistics fetch(es), %CacheHits% cache hit(s)
log.endBanner=== Live dashboard stopped ===
log.moveJob=Move job
log.actionWordCreated=created
log.actionWordResumed=resumed
log.actionWordRemoved=removed
log.modeSuspend=run to 95 % and suspend
log.modeDirect=migrate straight through
log.pretestCheckMove=check first, then move
log.pretestOnly=check only (move nothing)
log.pretestNone=no pretest
log.badItems=Bad items: %Value%
log.startWhatIfOnly=%Count% mailbox/mailboxes will only be checked with -WhatIf - nothing will be moved (Batch: %Batch%).
log.startCheckThen=%Count% mailbox/mailboxes will first be checked with -WhatIf and then moved to '%Target%' (priority: %Priority%, %BadItems%, Batch: %Batch%).
log.startDirect=%Count% mailbox/mailboxes will be moved to '%Target%' (priority: %Priority%, %BadItems%, Batch: %Batch%).
log.runningInstanceOnly=  Running instance: %Instance%
log.scriptFailed=Script terminated with errors. See log: %Path%
log.netshAcl=  netsh http add urlacl url=%Url% user=%User%
'@
}

$script:Texte = @{
    de = ConvertTo-SprachTabelle -RohText $script:SprachRoh.de
    en = ConvertTo-SprachTabelle -RohText $script:SprachRoh.en
}

if ($Sprache -in @('de', 'en')) {
    $script:Sprache = $Sprache
}
else {
    $script:Sprache = Get-StandardSprache
}

function T {
    <#
    .SYNOPSIS
        Liefert einen lokalisierten Text. %Name%-Platzhalter werden aus dem
        uebergebenen Hashtable ersetzt.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [hashtable]$Werte,
        [string]$SprachCode = ""
    )

    if ([string]::IsNullOrWhiteSpace($SprachCode)) { $SprachCode = $script:Sprache }
    if (-not $script:Texte.ContainsKey($SprachCode)) { $SprachCode = 'de' }

    $Text = $script:Texte[$SprachCode][$Key]
    if ($null -eq $Text) { $Text = $script:Texte['de'][$Key] }
    if ($null -eq $Text) { return "[[$Key]]" }

    if ($Werte) {
        foreach ($Name in $Werte.Keys) {
            $Text = $Text.Replace("%$Name%", [string]$Werte[$Name])
        }
    }

    return $Text
}

function TM {
    <#
    .SYNOPSIS
        Kurzform fuer eine lokalisierte Meldung: TM 'log.key' @{ Wert = ... }
    .DESCRIPTION
        Genau wie T, nur mit sprechenderem Namen an den Aufrufstellen von
        Konsole, Logdatei und API-Meldungen. Fehlt ein Schluessel, liefert T
        den deutschen Text - die Anzeige bleibt damit immer lesbar.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Mandatory = $false, Position = 1)][hashtable]$Werte
    )

    return (T -Key $Key -Werte $Werte)
}

function Resolve-SprachPlatzhalter {
    <#
    .SYNOPSIS
        Ersetzt {{key}}-Platzhalter im Dashboard-HTML durch die Texte der
        gewaehlten Sprache.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$SprachCode = ""
    )

    if ([string]::IsNullOrWhiteSpace($SprachCode)) { $SprachCode = $script:Sprache }
    if (-not $script:Texte.ContainsKey($SprachCode)) { $SprachCode = 'de' }

    $Tabelle = $script:Texte[$SprachCode]
    foreach ($Key in $Tabelle.Keys) {
        $Text = $Text.Replace("{{$Key}}", [string]$Tabelle[$Key])
    }

    return $Text
}

function Get-AnfrageSprache {
    param($Anfrage)

    try {
        $AusQuery = [string]$Anfrage.QueryString['lang']
        if ($AusQuery -in @('de', 'en')) { return $AusQuery }
    }
    catch { }

    try {
        $AusCookie = [string]$Anfrage.Cookies['DashboardSprache'].Value
        if ($AusCookie -in @('de', 'en')) { return $AusCookie }
    }
    catch { }

    return $script:Sprache
}

# ============================================================================
# Region: Variablen-Definition
# ============================================================================

# Pfad für Log-Dateien
$LogVerzeichnis       = "C:\ExchangeMigrationLog"
$Zeitstempel          = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LogDateiPfad         = Join-Path -Path $LogVerzeichnis -ChildPath "LiveDashboard_$($Zeitstempel).log"

# Webserver-URL
$BaseURL              = "http://localhost:$Port/"

# Exchange Server Name
$ExchangeServer       = $env:COMPUTERNAME

# Aktive Jobs, für die Get-MoveRequestStatistics wirklich benötigt wird.
$StatusAktiv          = @('InProgress', 'CompletionInProgress', 'Queued',
                          'AutoSuspended', 'Suspended',
                          'StalledDueToTarget', 'StalledDueToSource')

# Endzustände – deren Statistik ist eingefroren und wird gecacht.
$StatusEnd            = @('Completed', 'CompletedWithWarning', 'Failed')

# ============================================================================
# NEU: Prioritätszuordnung – Niedrigere Zahl = weiter oben in der Liste
#      Aktive Jobs bekommen die niedrigsten Werte (1-3)
# ============================================================================
$StatusPrioritaet = @{
    'InProgress'            = 1    # Aktiv laufend           → ganz oben
    'CompletionInProgress'  = 2    # Abschluss läuft         → direkt danach
    'Queued'                = 3    # In Warteschlange         → bereit zum Start
    'AutoSuspended'         = 4    # Automatisch pausiert
    'Suspended'             = 5    # Manuell pausiert
    'StalledDueToTarget'    = 6    # Blockiert (Ziel)
    'StalledDueToSource'    = 7    # Blockiert (Quelle)
    'Failed'                = 8    # Fehlgeschlagen
    'CompletedWithWarning'  = 9    # Abgeschlossen mit Warnung
    'Completed'             = 10   # Erfolgreich fertig      → ganz unten
}

# Standard-Priorität für unbekannte Status (wird mittig eingeordnet)
$StandardPrioritaet = 99

# Standard-Farbe für unbekannte Status
$StandardFarbe = '#6c757d'

# Farbdefinitionen für die Status-Anzeige
$StatusFarben = @{
    'Completed'             = '#28a745'   # Grün
    'CompletedWithWarning'  = '#ffc107'   # Gelb
    'InProgress'            = '#17a2b8'   # Blau
    'Queued'                = '#6c757d'   # Grau
    'AutoSuspended'         = '#fd7e14'   # Orange
    'Suspended'             = '#fd7e14'   # Orange
    'Failed'                = '#dc3545'   # Rot
    'StalledDueToTarget'    = '#e83e8c'   # Pink
    'StalledDueToSource'    = '#e83e8c'   # Pink
    'CompletionInProgress'  = '#20c997'   # Türkis
}

# Flag zum Beenden des Servers
$script:ServerLaeuft = $true

# ============================================================================
# Region: Server-Zustand (v2.0)
# ============================================================================

# Letzter erfolgreich gebauter Snapshot. Wird bei jedem /api/data ausgeliefert.
$script:LetzterSnapshot    = $null
$script:LetzteSammlung     = $null
$script:StartZeit          = Get-Date

# Cache der fertigen/fehlgeschlagenen Jobs: MoveRequest-Identity -> Tabellenzeile
# WICHTIG: Schluessel ist die MoveRequest-Identity (eindeutig pro Job), NICHT
# ExchangeObjectId. ExchangeObjectId ist leer/nicht eindeutig und hat dazu
# gefuehrt, dass alle Completed-Jobs dieselbe gecachte Zeile zeigten.
$script:StatistikCache     = @{}

# Statistische Kennzahlen der letzten Sammlung (nur fürs Log)
$script:LetzteDauer        = 0
$script:LetzteAktiv        = 0
$script:Sammlungen          = 0
$script:CacheTreffer        = 0
$script:ExchangeAbfragen    = 0

# v2.3: Jobs, deren Detaildaten (Statistik) noch nicht geholt wurden. Die
# Reihenfolge der Detailabrufe orientiert sich an dieser Menge – so kommt
# kein Job durch eine harte Abrufgrenze dauerhaft zu kurz.
$script:OffeneDetails       = @{}

# v2.3: Runspace-Pool für parallele Get-MoveRequestStatistics-Abrufe.
# Wird beim ersten Detail-Lauf angelegt und bleibt offen (das Exchange-
# Snapin kostet je Runspace einmalig mehrere Sekunden). Nach einem
# einmaligen Fehler wird die Parallelität dauerhaft abgeschaltet.
$script:StatistikPool       = $null
$script:StatistikParallelAus = $false

# ============================================================================
# Region: Logging
# ============================================================================
# Add-Content öffnet und schließt die Logdatei bei JEDEM Aufruf. Bei 235 Jobs
# und mehreren Logs pro Poll ergab das über 200 synchrone Dateioperationen pro
# Poll – mitten im Request-Pfad. Ein dauerhaft offener StreamWriter ersetzt das
# komplett. Zusätzlich werden wiederholte Meldungen innerhalb eines Zeitfensters
# nur gezählt statt geschrieben, und die Datei wird bei Bedarf rotiert.

$script:LogStream        = $null
$script:LogBytes         = 0

# Zeitfenster-Deduplizierung: gleiche Meldung hoechstens alle X Sekunden loggen
$script:LogZeit          = @{}     # Schluessel -> Zeitpunkt der letzten Ausgabe
$script:LogZaehler       = @{}     # Schluessel -> seitdem unterdrueckte Wiederholungen
$script:LogIntervallSek  = 300     # 5 Minuten

# Groessenbegrenzung: "something ran full" war auch die Logdatei
$script:LogMaxBytes      = 10MB
$script:LogMaxDateien    = 5       # LiveDashboard_x.log.1 ... .5
$script:LogMaxSchluessel = 500     # Eintraege in den Deduplizierungs-Tabellen

function Open-Log {
    <#
    .SYNOPSIS
        Öffnet den Log-Stream einmalig für die gesamte Laufzeit.
    #>
    if ($script:LogStream) { return }

    if (-not (Test-Path -Path $LogVerzeichnis)) {
        New-Item -ItemType Directory -Path $LogVerzeichnis -Force | Out-Null
    }

    $script:LogStream = New-Object System.IO.StreamWriter(
        $LogDateiPfad,
        $true,
        [System.Text.Encoding]::UTF8
    )
    $script:LogStream.AutoFlush = $true

    # Bereits vorhandene Groesse uebernehmen, damit nach einem Neustart
    # nicht die komplette Historie in eine frische Datei passt.
    if (Test-Path -Path $LogDateiPfad) {
        $script:LogBytes = (Get-Item -Path $LogDateiPfad).Length
    }
    else {
        $script:LogBytes = 0
    }
}

function Rotiere-Log {
    <#
    .SYNOPSIS
        Verschiebt das aktuelle Log, damit es nicht unbegrenzt wächst.
        .DESCRIPTION
        LiveDashboard_x.log      -> wird neu begonnen
        LiveDashboard_x.log.1    -> frischeste Sicherung
        ...
        LiveDashboard_x.log.$LogMaxDateien -> älteste, wird überschrieben
    #>
    $Ziel = "$LogDateiPfad.$script:LogMaxDateien"
    if (Test-Path -Path $Ziel) { Remove-Item -Path $Ziel -Force -ErrorAction SilentlyContinue }

    for ($i = $script:LogMaxDateien - 1; $i -ge 1; $i--) {
        $Von = "$LogDateiPfad.$i"
        if (Test-Path -Path $Von) {
            Move-Item -Path $Von -Destination "$LogDateiPfad.$($i + 1)" -Force -ErrorAction SilentlyContinue
        }
    }

    try { $script:LogStream.Flush(); $script:LogStream.Close() } catch { }
    $script:LogStream = $null

    Move-Item -Path $LogDateiPfad -Destination "$LogDateiPfad.1" -Force -ErrorAction SilentlyContinue
    $script:LogBytes = 0

    Open-Log
    Write-LogZeile -Zeile (TM 'log.rotated' @{ File = (Split-Path -Leaf "$LogDateiPfad.1") })
}

function Close-Log {
    <#
    .SYNOPSIS
        Schliesst den Log-Stream sauber.
    #>
    if ($script:LogStream) {
        try { $script:LogStream.Flush(); $script:LogStream.Close() } catch { }
        $script:LogStream = $null
    }
}

function Write-LogZeile {
    <#
    .SYNOPSIS
        Schreibt eine Zeile ausschliesslich in die Logdatei (ohne Konsole).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Zeile
    )

    try {
        if (-not $script:LogStream) { Open-Log }

        # Groesse im Voraus hochzaehlen, damit nicht pro Zeile das Dateisystem
        # abgefragt werden muss. 2 Byte fuer CRLF.
        $script:LogBytes += $Zeile.Length + 2
        if ($script:LogBytes -ge $script:LogMaxBytes) { Rotiere-Log }

        $script:LogStream.WriteLine($Zeile)
    }
    catch {
        # Datei nicht erreichbar/gelöscht -> nicht in eine Endlosschleife verfallen
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Schreibt eine Nachricht in die Log-Datei und auf die Konsole.
        Identische Wiederholungen werden innerhalb von $LogIntervallSek
        gezählt statt erneut geschrieben.
    .PARAMETER Nachricht
        Die zu protokollierende Nachricht.
    .PARAMETER Typ
        INFO, WARNUNG, FEHLER, STILL (STILL = nur in die Datei)
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Nachricht,

        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARNUNG", "FEHLER", "STILL")]
        [string]$Typ = "INFO"
    )

    $Jetzt = Get-Date

    # --- Wiederholungen desselben Textes einsparen -------------------------
    # Schlüssel aus Typ + Text: dieselbe Meldung wird innerhalb von
    # $LogIntervallSek nur einmal geschrieben, danach folgt ein Hinweis,
    # wie oft sie in der Zwischenzeit aufgetreten ist.
    $Schluessel = "$Typ|$Nachricht"
    $Ausgefallen = 0

    if ($script:LogZeit.ContainsKey($Schluessel)) {
        $Abstand = ($Jetzt - $script:LogZeit[$Schluessel]).TotalSeconds
        if ($Abstand -lt $script:LogIntervallSek) {
            $script:LogZaehler[$Schluessel] = 1 + [int]$script:LogZaehler[$Schluessel]
            return
        }
        $Ausgefallen = [int]$script:LogZaehler[$Schluessel]
    }
    $script:LogZeit[$Schluessel]     = $Jetzt
    $script:LogZaehler[$Schluessel]  = 0

    # Die Deduplizierungs-Tabellen nicht unbegrenzt wachsen lassen. Es wird
    # nicht nach Alter gefiltert, sondern die ältesten Einträge werden
    # entfernt - nur so wirkt die Grenze auch bei vielen neuen Meldungen.
    if ($script:LogZeit.Count -gt $script:LogMaxSchluessel) {
        $Verwerfen = $script:LogZeit.Count - [int]($script:LogMaxSchluessel / 2)
        $Alt = $script:LogZeit.Keys | Sort-Object { $script:LogZeit[$_] } | Select-Object -First $Verwerfen
        foreach ($SchluesselAlt in $Alt) {
            $script:LogZeit.Remove($SchluesselAlt)
            $script:LogZaehler.Remove($SchluesselAlt)
        }
    }

    # Stufe und Meldung erscheinen in der gewaehlten Sprache (v2.16). Der
    # interne Typ bleibt INFO/WARNUNG/FEHLER/STILL - nur die Anzeige wechselt.
    $StufenSchluessel = switch ($Typ) {
        "WARNUNG" { "warn" }
        "FEHLER"  { "error" }
        "STILL"   { "silent" }
        default   { "info" }
    }
    $Stufe = TM "log.level.$StufenSchluessel"

    $LogZeile = "[$( $Jetzt.ToString('yyyy-MM-dd HH:mm:ss') )] [$Stufe] $Nachricht"
    Write-LogZeile -Zeile $LogZeile

    if ($Ausgefallen -gt 0) {
        Write-LogZeile -Zeile (TM 'log.suppressed' @{
            Count   = $Ausgefallen
            Seconds = [int]$script:LogIntervallSek
        })
    }

    if ($Typ -eq "STILL") { return }

    $Farben = @{ INFO='Cyan'; WARNUNG='Yellow'; FEHLER='Red' }
    Write-Host $LogZeile -ForegroundColor $Farben[$Typ]
}

# ============================================================================
# Region: Hilfsfunktionen
# ============================================================================

function Get-Text {
    <#
    .SYNOPSIS
        Wandelt einen möglicherweise $null-Wert sicher in Text um.
    #>
    param($Wert)

    if ($null -eq $Wert) { return "" }
    return [string]$Wert
}

function Get-DetailText {
    <#
    .SYNOPSIS
        Liefert ToString() eines Wertes, ohne bei $null eine Exception zu werfen.
        (Das war eine stille Fehlerquelle: ein $null hat ganze Jobs aus der
         Tabelle verschwinden lassen.)
    .DESCRIPTION
        Auch eine leere Zeichenkette wird zu "N/A". Sonst hieße die
        Statuskachel im Dashboard leer und die Gruppierung ergäbe eine
        namenlose Gruppe.
    #>
    param($Wert)

    if ($null -eq $Wert) { return "N/A" }
    if ($Wert -is [string] -and [string]::IsNullOrWhiteSpace($Wert)) { return "N/A" }
    return $Wert.ToString()
}

function Format-GroesseKurz {
    <#
    .SYNOPSIS
        Formatiert eine Exchange-Groessenangabe kurz als ganze MB- oder GB-Zahl.
    .DESCRIPTION
        Get-MoveRequestStatistics liefert ByteQuantifiedSize-Werte, deren ToString()
        z.B. "1.834 GB (1,969,304,264 bytes)" ergibt - zu lang fuer die Tabelle.
        Gewuenscht ist nur noch "1969 MB" bzw. "2 GB" (gerundet, ohne Nachkomma).
        Ab 1 GB wird in GB, darunter in MB angezeigt.
    #>
    param($Wert)

    if ($null -eq $Wert) { return "N/A" }
    if ($Wert -is [string] -and [string]::IsNullOrWhiteSpace($Wert)) { return "N/A" }

    [long]$Bytes = 0
    $Gefunden = $false

    # 1. ByteQuantifiedSize-Objekt: ToBytes() ist am zuverlaessigsten
    try {
        if (-not ($Wert -is [string]) -and $null -ne $Wert.PSObject.Methods['ToBytes']) {
            $Bytes = [long]$Wert.ToBytes()
            $Gefunden = $true
        }
    } catch { }

    $Text = [string]$Wert

    # 2. String mit Byte-Angabe in Klammern: "1.834 GB (1,969,304,264 bytes)"
    if (-not $Gefunden) {
        $Treffer = [regex]::Match($Text, '\(([\d\.,''\s]+)\s*bytes\)')
        if ($Treffer.Success) {
            $Ziffern = $Treffer.Groups[1].Value -replace '[^\d]', ''
            if ($Ziffern -match '^\d+$') {
                $Bytes = [long]$Ziffern
                $Gefunden = $true
            }
        }
    }

    # 3. Fallback: Zahl + Einheit, z.B. "1.834 GB" oder "956,5 MB"
    if (-not $Gefunden) {
        $Treffer = [regex]::Match($Text, '([\d\.,]+)\s*(GB|MB|KB|Bytes|B)\b', 'IgnoreCase')
        if ($Treffer.Success) {
            $ZahlText = $Treffer.Groups[1].Value
            $Einheit  = $Treffer.Groups[2].Value.ToUpper()
            # Tausendertrennzeichen entfernen, Dezimalkomma normalisieren
            if ($ZahlText -match '\.' -and $ZahlText -match ',') { $ZahlText = $ZahlText -replace ',', '' }
            elseif ($ZahlText -match ',' -and $ZahlText -notmatch '\.') { $ZahlText = $ZahlText -replace ',', '.' }
            $Zahl = 0.0
            if ([double]::TryParse($ZahlText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$Zahl)) {
                $Faktor = switch ($Einheit) {
                    'GB'    { 1GB; break }
                    'MB'    { 1MB; break }
                    'KB'    { 1KB; break }
                    default { 1; break }
                }
                $Bytes = [long][math]::Round($Zahl * $Faktor)
                $Gefunden = $true
            }
        }
    }

    if (-not $Gefunden) { return "N/A" }
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB)) GB" }
    return "$([math]::Round($Bytes / 1MB)) MB"
}

function Get-StatusFarbe {
    <#
    .SYNOPSIS
        Gibt die zugeordnete HTML-Farbe für einen MoveRequest-Status zurück.
    .PARAMETER Status
        Der Status des MoveRequests. Ein leerer oder unbekannter Status ist
        erlaubt und ergibt die Standardfarbe.
    .NOTES
        Status darf bewusst NICHT Mandatory sein: die Parameterbindung lehnt
        eine leere Zeichenkette ab und wirft, bevor der Fallback unten greift.
        Genau das hat bei einem Job mit leerem Status die komplette Sammlung
        gekillt - 0 Zeilen im Dashboard statt einer Zeile mit Standardfarbe.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Status = ""
    )

    if ([string]::IsNullOrWhiteSpace($Status)) { return $StandardFarbe }

    if ($StatusFarben.ContainsKey($Status)) {
        return $StatusFarben[$Status]
    }
    else {
        return $StandardFarbe
    }
}

function Get-StatusPrioritaet {
    <#
    .SYNOPSIS
        Gibt die Sortierpriorität für einen MoveRequest-Status zurück.
        Niedrigere Werte = höhere Priorität = weiter oben in der Liste.
    .PARAMETER Status
        Der Status des MoveRequests. Ein leerer oder unbekannter Status ist
        erlaubt und ergibt die Standardpriorität.
    .EXAMPLE
        Get-StatusPrioritaet -Status "InProgress"   # Gibt 1 zurück (ganz oben)
        Get-StatusPrioritaet -Status "Completed"     # Gibt 10 zurück (ganz unten)
    .NOTES
        Status darf bewusst NICHT Mandatory sein, siehe Get-StatusFarbe.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Status = ""
    )

    if ([string]::IsNullOrWhiteSpace($Status)) { return $StandardPrioritaet }

    if ($StatusPrioritaet.ContainsKey($Status)) {
        return $StatusPrioritaet[$Status]
    }
    else {
        return $StandardPrioritaet
    }
}

function Set-SnapshotAlter {
    <#
    .SYNOPSIS
        Stempelt das Alter des Snapshots und gibt ihn zurück.

    .DESCRIPTION
        Das Alter ist die Zeit seit dem ENDE der letzten Sammlung. Wird es ab
        dem Startzeitpunkt gemessen, ist ein Snapshot, der 19 s lang gesammelt
        wurde, bereits bei Auslieferung abgelaufen.

        Der Snapshot wird bewusst in-place gestempelt: Er wird bei jeder
        Sammlung komplett ersetzt, das Nachtragen verändert also keinen Zustand.
    #>
    param($Snapshot)

    if ($null -eq $Snapshot) { return $null }

    if ($script:LetzteSammlung) {
        $Snapshot.AlterSekunden = [math]::Round(((Get-Date) - $script:LetzteSammlung).TotalSeconds, 1)
    }

    return $Snapshot
}

function Sende-Antwort {
    <#
    .SYNOPSIS
        Schreibt eine Antwort in den Response-Stream. Das Schreiben selbst wird
        vom aufrufenden finally-Block abgesichert, damit bei einem abgebrochenen
        Request keine Verbindung hängen bleibt.
    #>
    param(
        [Parameter(Mandatory = $true)]$Antwort,
        [Parameter(Mandatory = $true)][string]$Inhalt,
        [Parameter(Mandatory = $true)][string]$ContentType,
        [int]$StatusCode = 200
    )

    $Puffer = [System.Text.Encoding]::UTF8.GetBytes($Inhalt)

    $Antwort.ContentType     = $ContentType
    $Antwort.ContentLength64 = $Puffer.Length
    $Antwort.StatusCode      = $StatusCode

    # Der Browser darf den Polling-Response nicht cachen
    try { $Antwort.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate") } catch { }

    $Antwort.OutputStream.Write($Puffer, 0, $Puffer.Length)
}

function New-FehlgeschlageneZeile {
    <#
    .SYNOPSIS
        Baut eine Detailzeile aus dem MoveRequest-Objekt, wenn die Statistik
        nicht abrufbar war.
    .DESCRIPTION
        Ohne diese Funktion fiel ein Job bei einem Envelope-Fehler komplett aus
        der Tabelle: Get-MoveRequest meldete 235, die Tabelle zeigte 226. Der
        Operator konnte nicht mehr sehen, WELCHE Jobs betroffen sind. Jetzt
        bleibt die Zeile stehen, die Statistikfelder zeigen "N/A", und der
        Fehlertext landet in der Nachrichtenspalte.
    .PARAMETER MoveRequest
        Das MoveRequest-Objekt aus Get-MoveRequest.
    .PARAMETER Ursache
        Fehlermeldung des Statistikabrufs.
    .OUTPUTS
        Hashtable mit derselben Feldstruktur wie eine erfolgreiche Zeile.
    #>
    param(
        [Parameter(Mandatory = $true)]$MoveRequest,
        [Parameter(Mandatory = $false)][string]$Ursache = "Statistik nicht abrufbar"
    )

    $StatusString = if ($MoveRequest.Status) { [string]$MoveRequest.Status } else { "Unbekannt" }

    return @{
        DisplayName          = Get-Text $MoveRequest.DisplayName
        Alias                = Get-Text ($MoveRequest.DisplayName -replace '@.*', '')
        # Identity erlaubt spaeter pro Zeile eine einzelne Anforderung
        # anzusprechen (Button "Abschließen" bei suspendierten Jobs).
        Identity             = Get-Text $MoveRequest.Identity
        Status               = $StatusString
        StatusDetail         = "Statistik nicht abrufbar"
        StatusFarbe          = (Get-StatusFarbe -Status $StatusString)
        StatusPrioritaet     = (Get-StatusPrioritaet -Status $StatusString)
        Aktiv                = ($StatusAktiv -contains $StatusString)
        ProzentAbgeschlossen = 0
        BalkenFarbe          = '#6c757d'      # grau = unbekannt, nicht 0 %
        BytesUebertragen     = "N/A"
        GesamtGroesse        = "N/A"
        ItemsUebertragen     = 0
        BadItemsGefunden     = 0
        LargeItemsGefunden   = 0
        QuellDatenbank       = "N/A"
        ZielDatenbank        = "N/A"
        BatchName            = Get-Text $MoveRequest.BatchName
        StartZeit            = "N/A"
        AbschlussZeit        = "N/A"
        Nachricht            = $Ursache
        StatistikFehler      = $true
    }
}

function New-Grundzeile {
    <#
    .SYNOPSIS
        Baut eine Detailzeile nur aus dem MoveRequest-Objekt – ohne
        Get-MoveRequestStatistics.
    .DESCRIPTION
        Der erste Lauf einer Sammlung liefert ausschliesslich solche
        Grundzeilen. Ein einzelner Get-MoveRequest-Abruf dauert nur
        Sekunden, waehrend hunderte Statistikabrufe die Request-Queue
        mehrere Minuten blockierten – genau das war der Grund, warum das
        Dashboard und das Postfach-Laden beim Start so lange brauchten.

        Die Statistikfelder tragen den Platzhalter "..." und den Marker
        DetailOffen. Der naechste Sammlungslauf hoelt sie nach; das
        Frontend zeigt bis dahin einen neutralen "..."-Balken statt einer
        scheinbaren 0 %.

        Mit -Light entfaellt der Nachlauf: es wird bewusst keine Statistik
        abgerufen, die Platzhalter sind "-" und DetailOffen bleibt false.
    .PARAMETER MoveRequest
        Das MoveRequest-Objekt aus Get-MoveRequest.
    .PARAMETER Light
        Light-Modus: Zeile ohne technische Werte und sofort endgueltig.
    .OUTPUTS
        Hashtable mit derselben Feldstruktur wie eine volle Zeile.
    #>
    param(
        [Parameter(Mandatory = $true)]$MoveRequest,

        [Parameter(Mandatory = $false)][switch]$Light
    )

    $StatusString = if ($MoveRequest.Status) { [string]$MoveRequest.Status } else { "Unbekannt" }

    # Light-Modus (-Light): es wird bewusst keine Statistik abgerufen, also
    # gibt es auch keine technischen Werte. Die Zeile ist sofort endgueltig
    # (DetailOffen $false) - sonst muesste das Frontend ewig auf Daten
    # warten, die nie kommen.
    $Platzhalter = if ($Light) { "-" } else { "..." }

    # Quell- und Ziel-Datenbank stehen bereits am MoveRequest – nur die
    # Detailangaben (Prozent, Groessen, Zeiten) brauchen die Statistik.
    $Quelle = "N/A"
    $Ziel   = "N/A"
    try {
        $Quelle = Get-DatenbankAnzeige $MoveRequest.SourceDatabase
        if ([string]::IsNullOrWhiteSpace($Quelle)) { $Quelle = "N/A" }
        $Ziel = Get-DatenbankAnzeige $MoveRequest.TargetDatabase
        if ([string]::IsNullOrWhiteSpace($Ziel)) { $Ziel = "N/A" }
    }
    catch { }

    return @{
        DisplayName          = Get-Text $MoveRequest.DisplayName
        Alias                = Get-Text ($MoveRequest.DisplayName -replace '@.*', '')
        Identity             = Get-Text $MoveRequest.Identity
        Status               = $StatusString
        StatusDetail         = $Platzhalter
        StatusFarbe          = (Get-StatusFarbe -Status $StatusString)
        StatusPrioritaet     = (Get-StatusPrioritaet -Status $StatusString)
        Aktiv                = ($StatusAktiv -contains $StatusString)
        ProzentAbgeschlossen = 0
        BalkenFarbe          = '#e9ecef'      # hellgrau = wird geladen, nicht 0 %
        BytesUebertragen     = $Platzhalter
        GesamtGroesse        = $Platzhalter
        ItemsUebertragen     = $Platzhalter
        BadItemsGefunden     = $Platzhalter
        LargeItemsGefunden   = $Platzhalter
        QuellDatenbank       = $Quelle
        ZielDatenbank        = $Ziel
        BatchName            = Get-Text $MoveRequest.BatchName
        StartZeit            = $Platzhalter
        AbschlussZeit        = $Platzhalter
        Nachricht            = if ($Light) { "" } else { "Detaildaten werden nachgeladen" }
        StatistikFehler      = $false
        DetailOffen          = (-not [bool]$Light)
    }
}

function Get-MoveRequestSchluessel {
    <#
    .SYNOPSIS
        Baut einen stabilen, eindeutigen Cache-Schluessel pro MoveRequest.
    .DESCRIPTION
        BUGFIX 29.09.2026: Der Cache nutzte zuvor [string]$MoveRequest.ExchangeObjectId.
        Diese Eigenschaft ist bei MoveRequests leer bzw. nicht eindeutig, sodass
        alle Completed-Jobs auf denselben Schluessel ("") fielen. Nach dem ersten
        gecachten Job lieferte jeder weitere Completed-Job dieselbe Zeile
        (z.B. immer "Brunke Thomas"). Deshalb jetzt: Identity zuerst, dann
        RequestGuid/ExchangeGuid, erst als Fallback DisplayName+BatchName.
    #>
    param(
        [Parameter(Mandatory = $true)]$MoveRequest
    )

    foreach ($Prop in @('Identity', 'RequestGuid', 'ExchangeGuid', 'Guid')) {
        try {
            $Wert = $MoveRequest.$Prop
            if ($null -ne $Wert -and -not [string]::IsNullOrWhiteSpace([string]$Wert)) {
                return "$Prop`:$([string]$Wert)"
            }
        } catch { }
    }

    $Name  = Get-Text $MoveRequest.DisplayName
    $Batch = Get-Text $MoveRequest.BatchName
    return "Name:$Name|Batch:$Batch"
}

function Get-DashboardProzess {
    <#
    .SYNOPSIS
        Liefert laufende Dashboard-Prozesse als Objekte (PID, Prozess,
        Port, Kommandozeile).
    .DESCRIPTION
        Erkennt sowohl den aktuellen Skriptnamen als auch die alte Version
        'live_moverequest_statistik.ps1'. Der Port wird aus der Kommandozeile
        gelesen; fehlt -Port, gilt der Standardport 8585.

        GRENZE: Ein Dashboard, das in einer offenen Konsole gestartet wurde
        (.\Exchange-MoveRequest-Dashboard.ps1 eingegeben), traegt den
        Skriptnamen NICHT in der Kommandozeile der powershell.exe - solche
        Instanzen sind hier unsichtbar. Fuer sie gibt es den HTTP-Weg
        (Test-DashboardAntwort / Stop-AnderesDashboard).
    .PARAMETER Port
        Nur Prozesse mit diesem Port liefern. 0 = alle Ports.
    .OUTPUTS
        Array von PSCustomObject. Leer, wenn nichts gefunden wurde.
    #>
    param(
        [Parameter(Mandatory = $false)][int]$Port = 0
    )

    $Treffer = @()

    try {
        $SkriptMuster = 'Exchange-MoveRequest-Dashboard\.ps1|live_moverequest_statistik\.ps1'
        $Prozesse = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
            Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $SkriptMuster })

        foreach ($Prozess in $Prozesse) {
            $Kommandozeile = [string]$Prozess.CommandLine

            $ProzessPort = 8585
            if ($Kommandozeile -match '(?i)-Port[=\s]+(\d+)') {
                $ProzessPort = [int]$Matches[1]
            }

            if ($Port -gt 0 -and $ProzessPort -ne $Port) { continue }

            $Treffer += [pscustomobject]@{
                Pid         = [int]$Prozess.ProcessId
                Prozess     = [string]$Prozess.Name
                Port        = $ProzessPort
                CommandLine = $Kommandozeile
            }
        }
    }
    catch {
        # Prozessliste nicht lesbar (Rechte) - dann eben keine Treffer,
        # der eigentliche Fehler wird dadurch nie versteckt.
    }

    # WICHTIG: KEIN Komma-Operator. "return , $Treffer" liefert dem Aufrufer
    # ein Array, dessen EINZIGES Element wiederum ein Array ist. Der Aufrufer
    # wickelt das mit @() um und bekommt ein Element mit leeren Feldern -
    # es entstand die Fehlwarnung "Es laeuft bereits eine weitere
    # Dashboard-Instanz" samt der leeren Logzeile "PID  (), Port :".
    return $Treffer
}

function Get-LaufendeDashboardInstanzen {
    <#
    .SYNOPSIS
        Liefert alle laufenden Dashboard-Prozesse als Textzeilen fuer das Log.
    .OUTPUTS
        Array von Textzeilen "PID <nr> (<prozess>), Port <n>: <kommandozeile>".
    #>

    $Zeilen = @()

    foreach ($Prozess in @(Get-DashboardProzess)) {
        $Zeilen += "PID $($Prozess.Pid) ($($Prozess.Prozess)), Port $($Prozess.Port): $($Prozess.CommandLine)"
    }

    # Siehe Get-DashboardProzess: kein Komma-Operator, sonst entsteht beim
    # Aufrufer mit @(...) ein Phantom-Element ohne Inhalt.
    return $Zeilen
}

function Test-BrowserVerbindungsabbruch {
    <#
    .SYNOPSIS
        Prueft, ob eine Exception nur bedeutet, dass der Browser die
        Verbindung zuerst zugeklemmt hat - und darum KEIN Fehler ist.
    .DESCRIPTION
        Beim Stoppen ueber die Seite, beim Schliessen des Tabs oder beim
        Abbruch eines laufenden Polls ist der Client weg, waehrend das Skript
        gerade in den Response-Stream schreibt. Formal kommt dabei eine
        HttpListenerException mit Win32-Fehler 64 ("Der angegebene
        Netzwerkname ist nicht mehr verfuegbar") bzw. ein abgebrochener
        Socket heraus - inhaltlich ist das ganz normal.

        Frueher stand genau das als WARNUNG im Log und wirkte wie ein Fehler
        beim Stoppen, obwohl der Server sauber heruntergefahren ist.

        PowerShell liefert die Exception als Wrapper (MethodInvocationException)
        mit InnerException - deshalb wird die Kette durchlaufen und erst
        zuletzt auf die Meldung geschaut.
    .PARAMETER Exception
        Die abgefangene Exception ($_.Exception).
    .OUTPUTS
        True, wenn der Client die Verbindung zuerst geschlossen hat.
    #>
    param(
        [Parameter(Mandatory = $false)]$Exception
    )

    if ($null -eq $Exception) { return $false }

    # Win32-Codes, die nur "die andere Seite ist weg" bedeuten:
    #   64    ERROR_BAD_NET_NAME         Netzwerkname nicht mehr verfuegbar
    #   995   ERROR_OPERATION_ABORTED    Vorgang abgebrochen
    #   1225  ERROR_OPERATION_ABORTED    Vorgang abgebrochen
    #   1236  ERROR_CONNECTION_ABORTED   Verbindung abgebrochen
    #   10053 WSAECONNABORTED            Verbindung unerwartet beendet
    #   10054 WSAECONNRESET              vom Partner zurueckgesetzt
    #   10058 WSAESHUTDOWN               Socket steht nicht mehr
    $TrennungsCodes = @(64, 995, 1225, 1236, 10053, 10054, 10058)

    $Aktuell = $Exception
    while ($null -ne $Aktuell) {
        if ($Aktuell -is [System.Net.HttpListenerException]) {
            if ($TrennungsCodes -contains [int]$Aktuell.ErrorCode) { return $true }
        }
        $Aktuell = $Aktuell.InnerException
    }

    # Sicherheitsnetz: dieselbe Ursache, aber in einem anderen Exception-Typ
    # oder nur als Meldungstext durchgereicht.
    $Meldung = [string]$Exception.Message
    if ($Meldung -match 'netzwerkname|network name is no longer|forcibly closed|connection reset|connection was aborted') {
        return $true
    }

    return $false
}

function Test-DashboardAntwort {
    <#
    .SYNOPSIS
        Prueft, was auf einem Port antwortet: nichts, ein weiteres
        Dashboard oder ein fremder Dienst.
    .DESCRIPTION
        Ein HTTP-Abruf ist die einzige verlaessliche Suche nach einer
        zweiten Instanz. Die Prozesssuche uebersieht alles, was in einer
        offenen Konsole gestartet wurde - und genau der antwortende
        HttpListener haelt auch das URL-Praefix, das dem eigenen Start
        fehlt (Win32 Fehler 32).
    .PARAMETER Url
        Basis-URL des Dashboards, z.B. http://localhost:8585/
        (Endebruchstrich ist einzubauen.)
    .OUTPUTS
        ""          nichts erreichbar - Port ist frei bzw. laeuft nichts,
                    das antwortet
        "Dashboard" ein weiteres Dashboard antwortet (erkennbar am Titel)
        "Fremd"     ein anderer Dienst antwortet
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url
    )

    try {
        $Anfrage = [System.Net.HttpWebRequest]::Create($Url)
        $Anfrage.Method           = "GET"
        $Anfrage.Timeout          = 2000
        $Anfrage.ReadWriteTimeout = 2000
        $Anfrage.UserAgent        = "Exchange-MoveRequest-Dashboard-Startpruefung"
        $Anfrage.AllowAutoRedirect = $false

        $Antwort = $Anfrage.GetResponse()
        $Stream  = $Antwort.GetResponseStream()
        $Leser   = New-Object System.IO.StreamReader($Stream, [System.Text.Encoding]::UTF8)
        $Inhalt  = $Leser.ReadToEnd()
        $Leser.Close()
        $Antwort.Close()

        if ($Inhalt -match 'Exchange MoveRequest Live-Dashboard') { return "Dashboard" }
        return "Fremd"
    }
    catch [System.Net.WebException] {
        # Antwort kam, aber nicht 200 -> fremder Dienst.
        if ($_.Exception.Response) { return "Fremd" }
        # Verbindung abgelehnt, Timeout, DNS -> nichts erreichbar.
        return ""
    }
    catch {
        return ""
    }
}

function Stop-AnderesDashboard {
    <#
    .SYNOPSIS
        Beendet ein weiteres Dashboard auf dem Port sauber ueber seine
        eigene /api/stop-Route.
    .DESCRIPTION
        Sauber heisst: die andere Instanz schliesst ihren HttpListener und
        gibt damit das URL-Praefix frei. Der Prozess selbst darf weiterleben
        (offene Konsole mit Prompt) - gehalten wird nur das Praefix, und
        genau das ist der Grund fuer den Startfehler.

        Danach wird bis zu -WartezeitSekunden nachgeprueft, ob die
        Dashboard-Antwort verschwindet.
    .PARAMETER BasisUrl
        Basis-URL des Dashboards, z.B. http://localhost:8585/
    .PARAMETER WartezeitSekunden
        Maximal wartende Zeit auf das Freigeben des Praefixes (Standard 15).
    .OUTPUTS
        $true  das Praefix ist frei (antwortet nicht mehr mit Dashboard)
        $false die andere Instanz antwortet noch
    #>
    param(
        [Parameter(Mandatory = $true)][string]$BasisUrl,

        [Parameter(Mandatory = $false)][int]$WartezeitSekunden = 15
    )

    try {
        $Anfrage = [System.Net.HttpWebRequest]::Create($BasisUrl + "api/stop")
        $Anfrage.Method    = "GET"
        $Anfrage.Timeout   = 3000
        $Anfrage.UserAgent = "Exchange-MoveRequest-Dashboard-Start"

        $Antwort = $Anfrage.GetResponse()
        $Antwort.Close()
        Write-Log -Nachricht (TM 'log.stopSent') -Typ "INFO"
    }
    catch {
        Write-Log -Nachricht (TM 'log.stopFailed' @{ Error = $_.Exception.Message }) -Typ "INFO"
    }

    for ($Versuch = 0; $Versuch -lt ($WartezeitSekunden * 2); $Versuch++) {
        Start-Sleep -Milliseconds 500
        if ((Test-DashboardAntwort -Url $BasisUrl) -ne "Dashboard") { return $true }
    }

    return $false
}

function Resolve-DashboardPortKonflikt {
    <#
    .SYNOPSIS
        Prueft einen Port auf ein zweites Dashboard und raeumt das
        URL-Praefix frei (Auto-Stopp ueber /api/stop, sonst hart).
    .DESCRIPTION
        Die gleiche Pruefung laeuft an mehreren Stellen: frueh im Start
        (bevor Zeit in Snap-In und erste Sammlung fliesset), direkt vor
        JEDEM Versuch, den HttpListener zu starten, und nach einem
        Fehler 32.

        Genau dieses Zwischenfenster ist der Grund fuer die Wiederholung:
        zwischen der Startpruefung und $Listener.Start() liegen rund
        11 Sekunden Exchange-Sammlung. Darin kann eine zweite Instanz das
        Praefix uebernehmen - im Praxistest war der Port um 12:00:22 noch
        frei und um 12:00:33 belegt, der Start schlug mit Fehler 32 fehl.

        Ein Aufruf bei freiem Port ist billig: nur ein sofort fehlschlagender
        Verbindungsversuch, keine Wartezeit.
    .PARAMETER Port
        Zu pruefender Port (Parameter -Port).
    .PARAMETER BasisUrl
        Basis-URL des Dashboards, z.B. http://localhost:8585/.
    .PARAMETER Phase
        Kennung fuer die Logzeile, z.B. "Startpruefung" oder "Startversuch 2".
    .PARAMETER KeinAutoStopp
        Gefundene Instanz nicht beenden, nur melden.
    .PARAMETER MeldeFreieProzesse
        Auch dann melden, wenn der Port frei ist, aber andere
        Dashboard-Prozesse laufen (anderer Port oder gerade am Starten).
    .OUTPUTS
        "Frei"      nichts haelt den Port (mehr)
        "Belegt"    ein weiteres Dashboard haelt das Praefix weiterhin
        "Fremd"     ein fremder Dienst antwortet
        "OhneStopp" Dashboard gefunden, aber -KeinAutoStopp gesetzt
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$BasisUrl,
        [Parameter(Mandatory = $false)][string]$Phase = "Portpruefung",
        [Parameter(Mandatory = $false)][switch]$KeinAutoStopp,
        [Parameter(Mandatory = $false)][switch]$MeldeFreieProzesse
    )

    $PortZustand = Test-DashboardAntwort -Url $BasisUrl

    if ($PortZustand -eq "Fremd") {
        Write-Log -Nachricht (TM 'log.foreignService' @{ Phase = $Phase; Port = $Port }) -Typ "WARNUNG"
        return "Fremd"
    }

    if ($PortZustand -ne "Dashboard") {
        # Port frei. Auf Wunsch trotzdem nach Prozessen mit Skriptnamen
        # suchen - eine solche Instanz kann gerade erst am Starten sein
        # oder ihren Port auf einem anderen halten.
        if ($MeldeFreieProzesse) {
            $WeitereInstanzen = @(Get-LaufendeDashboardInstanzen)
            if ($WeitereInstanzen.Count -gt 0) {
                $Anzahl  = $WeitereInstanzen.Count
                if ($Anzahl -gt 1) {
                    $Meldung = TM 'log.otherInstanceMany' @{ Count = $Anzahl }
                }
                else {
                    $Meldung = TM 'log.otherInstanceOne'
                }
                Write-Log -Nachricht (TM 'log.hint' @{ Message = $Meldung }) -Typ "WARNUNG"
                foreach ($Instanz in $WeitereInstanzen) {
                    Write-Log -Nachricht ([string]$Instanz) -Typ "INFO"
                }
            }
        }
        return "Frei"
    }

    # --- ein weiteres Dashboard antwortet -----------------------------------
    $AndereInstanzen = @(Get-DashboardProzess -Port $Port)

    if ($KeinAutoStopp) {
        Write-Log -Nachricht (TM 'log.alreadyRunningNoStop' @{ Phase = $Phase; Port = $Port }) -Typ "WARNUNG"
        foreach ($Prozess in $AndereInstanzen) {
            Write-Log -Nachricht (TM 'log.processLine' @{ Pid = $Prozess.Pid; Process = $Prozess.Prozess; CommandLine = $Prozess.CommandLine }) -Typ "INFO"
        }
        if ($AndereInstanzen.Count -eq 0) {
            Write-Log -Nachricht (TM 'log.noProcessConsole') -Typ "INFO"
        }
        return "OhneStopp"
    }

    Write-Log -Nachricht (TM 'log.alreadyRunningStop' @{ Phase = $Phase; Port = $Port }) -Typ "WARNUNG"
    foreach ($Prozess in $AndereInstanzen) {
        Write-Log -Nachricht (TM 'log.runningInstance' @{ Pid = $Prozess.Pid; Process = $Prozess.Prozess; Port = $Prozess.Port; CommandLine = $Prozess.CommandLine }) -Typ "INFO"
    }
    if ($AndereInstanzen.Count -eq 0) {
        Write-Log -Nachricht (TM 'log.noProcessStop') -Typ "INFO"
    }

    $PraefixFrei = Stop-AnderesDashboard -BasisUrl $BasisUrl

    if (-not $PraefixFrei) {
        # Die andere Instanz hat nicht reagiert (Request-Loop haengt?).
        # Jetzt hart beenden - ausschliesslich Prozesse mit Skriptnamen
        # UND genau diesem Port.
        $AndereHart = @(Get-DashboardProzess -Port $Port)
        foreach ($Prozess in $AndereHart) {
            Write-Log -Nachricht (TM 'log.forceKill' @{ Pid = $Prozess.Pid; Process = $Prozess.Prozess }) -Typ "WARNUNG"
            try { Stop-Process -Id $Prozess.Pid -Force -ErrorAction Stop }
            catch { Write-Log -Nachricht (TM 'log.killFailed' @{ Pid = $Prozess.Pid; Error = $_.Exception.Message }) -Typ "WARNUNG" }
        }
        if ($AndereHart.Count -gt 0) { Start-Sleep -Seconds 2 }
        $PraefixFrei = ((Test-DashboardAntwort -Url $BasisUrl) -ne "Dashboard")
    }

    if ($PraefixFrei) {
        Write-Log -Nachricht (TM 'log.oldStopped' @{ Phase = $Phase; Url = $BasisUrl }) -Typ "INFO"
        return "Frei"
    }

    return "Belegt"
}

function Get-PortDiagnose {
    <#
    .SYNOPSIS
        Beschreibt, was zu einem Zeitpunkt X auf einem Port zu sehen war.
    .DESCRIPTION
        Wird ausschliesslich im Fehlerfall des HttpListener.Start()
        aufgerufen. Die Aufzeichung muss IM MOMENT DES FEHLERS erfolgen -
        eine Pruefung danach ist wertlos, weil die fehlgeschlagene
        Registrierung den Zustand bereits wieder aufgeraeumt hat.

        Geliefert werden TCP-Listener (PID und Prozessname) sowie
        URL-Reservierungen aus netsh fuer den Port.
    .PARAMETER Port
        Zu untersuchender Port (Parameter -Port).
    .OUTPUTS
        Array von Textzeilen. Leer, wenn nichts zu sehen war.
    #>
    param(
        [Parameter(Mandatory = $true)][int]$Port
    )

    $Zeilen = @()

    # --- TCP-Listener -------------------------------------------------------
    $ListenerGefunden = $false
    try {
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) {
            $Eintraege = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
            foreach ($Eintrag in $Eintraege) {
                $ListenerGefunden = $true
                $ProzessName = "unbekannt"
                try {
                    $ProzessName = (Get-Process -Id $Eintrag.OwningProcess -ErrorAction Stop).ProcessName
                }
                catch { }
                $Zeilen += "Port $Port lauscht auf $($Eintrag.LocalAddress) - PID $($Eintrag.OwningProcess) ($ProzessName)"
            }
        }
    }
    catch { }

    if (-not $ListenerGefunden) {
        $Zeilen += "Port ${Port}: zum Fehlerzeitpunkt kein TCP-Listener mehr - die gescheiterte Registrierung war sofort wieder frei."
    }

    # --- URL-Reservierungen (http.sys) -------------------------------------
    $ReservierungGefunden = $false
    try {
        $NetshAusgabe   = @(netsh http show urlacl)
        $Reservierungen = @($NetshAusgabe | Where-Object { $_ -match ":$Port" })
        foreach ($Zeile in $Reservierungen) {
            $ReservierungGefunden = $true
            $Zeilen += ("URL-Reservierung: " + $Zeile.Trim())
        }
    }
    catch { }

    if (-not $ReservierungGefunden) {
        $Zeilen += "URL-Reservierung fuer Port ${Port}: keine vorhanden (kein netsh-Eintrag noetig)."
    }

    # Siehe Get-DashboardProzess: kein Komma-Operator, sonst entsteht beim
    # Aufrufer mit @(...) ein Phantom-Element ohne Inhalt.
    return $Zeilen
}

# ============================================================================
# ============================================================================
# Region: Selbsterhoehung (v2.14) - elevated Neustart
# ============================================================================
# System- und Arbitration-Postfaecher lassen sich nur mit dem erhoehten
# Token verschieben: ohne UAC bleiben privilegierte Gruppen im Token auf
# "deny-only", und der Mailbox Replication Service antwortet auf jeden
# Versuch mit "Der Zugriff wurde verweigert". Deshalb startet sich das
# Skript ohne Admin-Rechte einmal selbst mit RunAs neu.

function Test-IstAdministrator {
    <#
    .SYNOPSIS
        Prueft, ob das Skript mit erhoehten Rechten (Administrator) laeuft.
    .OUTPUTS
        Boolean; $false, wenn die Identitaet nicht abgefragt werden kann
    #>
    try {
        $Ident = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $Principal = New-Object System.Security.Principal.WindowsPrincipal($Ident)
        return $Principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function New-ElevationsArgumente {
    <#
    .SYNOPSIS
        Baut die Argumentliste fuer den elevated Neustart des Skripts.
    .DESCRIPTION
        powershell.exe -File erwartet die Parameter als Kommandozeilentext.
        Zahlen und Zeichenketten kommen in Anfuehrungszeichen an (der
        -File-Parser entfernt sie wieder), gesetzte Schalter als -Name.
        Ausdruecklich abgeschaltete Schalter werden NICHT mitgenommen:
        powershell.exe -File kann -Name:$false nicht uebernehmen (es
        schlaegt mit einem Typfehler fehl), und ein abgeschalteter
        Schalter entspricht ohnehin dem Default - das Kind startet so
        mit exakt denselben Einstellungen wie der Aufrufer.
    .PARAMETER SkriptPfad
        $PSCommandPath des laufenden Skripts.
    .PARAMETER GebundeneParameter
        $PSBoundParameters - alle vom Aufrufer gesetzten Parameter.
        Nicht gesetzte Parameter fehlen komplett; das Kind behaelt die
        Skript-Defaults.
    .OUTPUTS
        String[] - Argumente fuer Start-Process -ArgumentList
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SkriptPfad,

        [Parameter(Mandatory = $false)]
        [System.Collections.IDictionary]$GebundeneParameter
    )

    $Argumente = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $SkriptPfad))

    if ($null -ne $GebundeneParameter) {
        foreach ($Name in $GebundeneParameter.Keys) {
            $Wert = $GebundeneParameter[$Name]
            if (($Wert -is [System.Management.Automation.SwitchParameter]) -or ($Wert -is [bool])) {
                if ([bool]$Wert) { $Argumente += ('-{0}' -f $Name) }
            }
            else {
                $Argumente += ('-{0}' -f $Name)
                $Argumente += ('"{0}"' -f $Wert)
            }
        }
    }

    return $Argumente
}

function Show-ElevationsHinweis {
    <#
    .SYNOPSIS
        Hinweisdialog, wenn die UAC-Frage abgelehnt wurde.
    .DESCRIPTION
        Beim Doppelklick schliesst sich das Fenster nach der Ablehnung -
        die Log-Warnung ueberlebt zwar, wird aber niemand lesen. Der
        Dialog macht die fehlenden Rechte sofort sichtbar. Schlaegt er
        fehl (z.B. ohne Windows Forms), wird still weitergemacht; die
        Warnung im Log bleibt in jedem Fall.
    #>
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $Text  = "Das Skript wurde NICHT als Administrator gestartet (UAC abgelehnt).`n`n" +
                 "System- und Arbitration-Postfaecher lassen sich dann nicht verschieben -" +
                 " Exchange meldet 'Der Zugriff wurde verweigert'.`n`n" +
                 "Bitte erneut starten und der UAC-Frage zustimmen."
        $Titel = "Exchange-MoveRequest-Dashboard - ohne Admin-Rechte"
        [System.Windows.Forms.MessageBox]::Show($Text, $Titel,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
    catch { }
}
# Region: Verschiebeanforderungen (WebGUI) - v2.2
# ============================================================================

# Alle gestarteten Verschiebeauftraege. Schluessel ist die laufende
# Auftragsnummer als String. Die Erstellung der MoveRequests laeuft in einem
# eigenen Hintergrund-Job (Start-Job), damit das Dashboard waehrenddessen
# weiterarbeitet und die Live-Ansicht nicht stehen bleibt.
$script:VersandAuftraege        = @{}
$script:VersandAuftragNr        = 0
$script:SuspendParameterPrueft  = $null    # einmalige Pruefung, danach gepuffert
$script:VersandAufbewahrungMin  = 60       # Minuten, danach verschwindet ein abgeschlossener Auftrag

function Get-DatenbankListe {
    <#
    .SYNOPSIS
        Liefert alle Postfachdatenbanken der Organisation, sortiert nach Name.
        Wird fuer die Quell- und Ziel-Auswahl der Verschiebeanforderung benutzt.
    .OUTPUTS
        Array von PSCustomObject mit den Eigenschaften Name und Server.
    #>

    $Datenbanken = @(Get-MailboxDatabase -ErrorAction Stop | Sort-Object Name)

    # Komma vor @(): eine leere Liste bleibt ein leeres Array und wird nicht
    # zu $null - sonst liefert die API "Datenbanken: null".
    return ,@($Datenbanken | ForEach-Object {
        [pscustomobject]@{
            Name   = Get-Text $_.Name
            Server = Get-Text $_.Server
        }
    })
}

function Get-DatenbankAnzeige {
    <#
    .SYNOPSIS
        Vereinfacht eine Datenbankangabe auf den Namen.
    .DESCRIPTION
        Je nach Abfrage liefert Exchange den reinen Namen ("DB01") oder den
        vollen Distinguished Name ("CN=DB01,CN=Databases,CN=Exchange ...").
        In der Oberflaeche und in der Sortierung soll immer nur "DB01"
        stehen - deshalb hier der eine Umweg fuer beide Faelle.
    .PARAMETER Wert
        Beliebige Datenbankangabe, auch leer oder $null.
    #>
    param($Wert)

    $Text = Get-Text $Wert
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }

    if ($Text -match '^CN=([^,]+)') { return $Matches[1] }
    return $Text
}

function Get-PostfachTyp {
    <#
    .SYNOPSIS
        Ordnet einen RecipientTypeDetails-Wert einer Anzeigekategorie zu.

        Zwei Kategorien: "Benutzer" fuer ganz normale Postfaecher und die
        Sonderpostfaecher (Arbitration, AuditLog, AuxAuditLog, PublicFolder,
        Archiv, SystemMailbox, Migration, Discovery). Health-Postfaecher
        (Monitoring) bleiben wie bisher verborgen - Rueckgabe "".

        Die Zuordnung geschieht ueber Teilbegriffe statt ueber feste Werte,
        weil die Bezeichnungen zwischen Exchange-Versionen leicht
        abweichen (ArbitrationMailbox, SystemMailbox{...}, PlusArchive, ...).

    .PARAMETER RecipientTypeDetails
        RecipientTypeDetails des Postfachs - darf und darf leer sein.
    .PARAMETER Name
        Identity, Anzeigename und Alias des Postfachs, zusammengefuegt in
        Einen String. Wird NUR ausgewertet, wenn der RecipientTypeDetails-
        Wert leer oder unbekannt ist: die Namensmuster fangen dann System-
        und Arbitration-Postfaecher ab, die ohne brauchbaren Typ geliefert
        werden (sonst faelen sie als "Benutzer" in die normale Liste).
    .OUTPUTS
        String - "Benutzer", die Bezeichnung der Sonderart oder ""
        (Postfach wird gar nicht angezeigt).
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$RecipientTypeDetails = "",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Name = ""
    )

    # --- Quelle 1: RecipientTypeDetails (die zuverlaessigste Angabe) --
    # Die Reihenfolge ist entscheidend: "AuxAuditLogMailbox" enthaelt
    # ebenfalls "Audit" und muesste sonst faelschlich als AuditLog landen.
    if (-not [string]::IsNullOrWhiteSpace($RecipientTypeDetails)) {
        if ($RecipientTypeDetails -match 'AuxAudit')      { return "AuxAuditLog" }
        if ($RecipientTypeDetails -match 'Audit')         { return "AuditLog" }
        if ($RecipientTypeDetails -match 'Arbitration')   { return "Arbitration" }
        if ($RecipientTypeDetails -match 'PublicFolder')  { return "PublicFolder" }
        if ($RecipientTypeDetails -match 'Archive')       { return "Archiv" }
        if ($RecipientTypeDetails -match 'SystemMailbox') { return "SystemMailbox" }
        if ($RecipientTypeDetails -match 'Migration')     { return "Migration" }
        if ($RecipientTypeDetails -match 'Discovery')     { return "Discovery" }
        # HealthMailbox und MonitoringMailbox (Managed Availability) -
        # beide bleiben verborgen, sonst wuechse die Benutzerliste um
        # tausende System-Eintraege.
        if ($RecipientTypeDetails -match 'Health')        { return "" }
        if ($RecipientTypeDetails -match 'Monitoring')    { return "" }

        # Ausdruecklicher Benutzer-RTD: die Namensmuster duerfen dann
        # nichts mehr ueberschreiben - der ausdruecklich gemeldete Typ
        # gewinnt. Ohne diese Regel ergabe ein normales Benutzerpostfach
        # mit zufaellig passendem Namen eine Sonderkategorie.
        if ($RecipientTypeDetails -match 'UserMailbox|SharedMailbox|LinkedMailbox|RoomMailbox|EquipmentMailbox|TeamMailbox|LegacyMailbox|SchedulingMailbox|MailboxPlan') {
            return "Benutzer"
        }
    }

    # --- Quelle 2: Namensmuster ---------------------------------------
    # Greift nur bei leerem oder unbekanntem RecipientTypeDetails. Die
    # Muster bleiben absichtlich ohne Startanker und mit Trennzeichen
    # (SystemMailbox{, FederatedEmail., Migration.), weil die Identity
    # auch als DN kommen kann ("CN=SystemMailbox{...},CN=System,...");
    # Treffer sind ausserdem immer mit den echten Sonderpostfach-Namen
    # dokumentiert (MS: FederatedEmail, Migration., SystemMailbox{...}).
    # Reihenfolge wie oben: AuxAudit vor Audit, sonst landete
    # "AuxAuditMailbox" als AuditLog.
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        if ($Name -match 'AuxAuditMailbox')                     { return "AuxAuditLog" }
        if ($Name -match 'AuditMailbox')                        { return "AuditLog" }
        if ($Name -match 'HealthMailbox')                       { return "" }
        if ($Name -match 'MsExchDiscoveryMailbox')              { return "Discovery" }
        if ($Name -match 'DiscoverySearchMailbox')              { return "Discovery" }
        if ($Name -match 'SystemMailbox\{')                     { return "SystemMailbox" }
        if ($Name -match 'FederatedEmail\.')                    { return "Arbitration" }
        if ($Name -match 'Migration\.')                         { return "Migration" }
    }

    return "Benutzer"
}

function Get-BenutzerListe {
    <#
    .SYNOPSIS
        Liefert die Postfaecher einer Quelldatenbank zur Auswahl.
        Ohne Quell-Datenbank werden alle Postfaecher aller Datenbanken
        inklusive ihrer Datenbankzugehoerigkeit geliefert.

    .DESCRIPTION
        Zusätzlich wird pro Postfach markiert, ob bereits ein MoveRequest
        existiert. Solche Postfaecher werden in der Oberfläche deaktiviert
        angezeigt, damit nicht versehentlich doppelt verschoben wird.

        Postfaecher lassen sich ueber -Typ trennen: Benutzerpostfaecher
        (Standard), Sonderpostfaecher (Arbitration, AuditLog, AuxAuditLog,
        PublicFolder, Archiv, SystemMailbox, Migration, Discovery), alles
        zusammen oder alle Postfaecher mit aktiviertem Archiv
        (Typ archiv). Health-Postfaecher werden in keiner Ansicht gezeigt.

        WICHTIG: Get-Mailbox OHNE Schalter liefert System- und
        Arbitration-Postfaecher NICHT - die brauchen jeweils eigene
        Schalter (-Arbitration, -AuditLog, -AuxAuditLog, -Migration,
        -PublicFolder, -Archive). Darum werden mehrere Abragen
        zusammengefuehrt; ein Fehler einzelner Quellen bleibt ohne Folgen
        auf die uebrigen.

    .PARAMETER QuellDatenbank
        Name der Postfachdatenbank, deren Postfaecher gelistet werden.
        Leer lassen zeigt ALLE Postfaecher aller Datenbanken an - mit
        Angabe der jeweiligen Datenbank pro Postfach.
    .PARAMETER Typ
        benutzer (Standard) = normale Postfaecher,
        sonder   = nur die Sonderpostfaecher,
        alle     = beides zusammen,
        archiv   = alle Postfaecher mit aktiviertem Archiv.
    .OUTPUTS
        Array von PSCustomObject: AnzeigeName, Adresse, Alias, Datenbank,
        Typ (Kategorie), Archiv (Postfach hat ein Archiv), Schluessel
        (Identitaet fuer Auswahl und Verschiebung), Bewegt, Status.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$QuellDatenbank = "",

        [Parameter(Mandatory = $false)]
        [ValidateSet("benutzer", "sonder", "alle", "archiv")]
        [string]$Typ = "benutzer"
    )

    # Ohne Quelle wird die gesamte Organisation abgefragt.
    $BasisAbfrage = @{ ResultSize = 'Unlimited'; ErrorAction = 'Stop' }
    if (-not [string]::IsNullOrWhiteSpace($QuellDatenbank)) {
        $BasisAbfrage['Database'] = $QuellDatenbank
    }

    # --- Zusammenfuehrung mehrerer Get-Mailbox-Abfragen ---------------
    # Ursache fuer leere Sonderlisten: Get-Mailbox ohne Schalter gibt die
    # System- und Arbitration-Postfaecher nicht heraus (Microsoft-Doku:
    # "return only arbitration mailboxes" braucht -Arbitration; AuditLog
    # und AuxAuditLog haben eigene Schalter). Es erschien daher nur das
    # Discoverysuchpostfaech, waehrend SystemMailbox{...}, FederatedEmail
    # und Migration.fehlten.
    # -Monitoring bleibt bewusst draussen: Health-Mailboxen sollen wie
    # bisher nirgends auftauchen.
    $ZusatzSchalter = @('Arbitration', 'AuditLog', 'AuxAuditLog',
                        'Migration', 'PublicFolder', 'Archive')

    # Verfuegbarkeit vorab pruefen: ein Schalter, den diese Exchange-
    # Version nicht kennt, darf die Liste nicht zerstoeren.
    $SchalterVerfuegbar = @{}
    $MailboxBefehl = Get-Command Get-Mailbox -ErrorAction SilentlyContinue
    if ($null -ne $MailboxBefehl) {
        foreach ($Schalter in $ZusatzSchalter) {
            $SchalterVerfuegbar[$Schalter] = $MailboxBefehl.Parameters.ContainsKey($Schalter)
        }
    }

    # Die Grundabfrage laeuft immer - alle Zusaetze sind Zusatz, kein
    # Ersatz. Reihenfolge: Standard zuerst, damit ein doppelt
    # geliefertes Objekt (z.B. Hauptpostfach aus -Archive) sein
    # urspruengliches Objekt behaelt.
    $Abfragen = @( @{ Name = 'Standard'; Schalter = '' } )
    foreach ($Schalter in $ZusatzSchalter) {
        if ($SchalterVerfuegbar[$Schalter]) {
            $Abfragen += @{ Name = $Schalter; Schalter = $Schalter }
        }
    }

    $Gesammelt = @{}   # Schluessel -> Mailbox-Objekt (erster Treffer gewinnt)
    $Quellen   = @{}   # Schluessel -> Namen der Quellen, die es geliefert haben
    $Laufnummer = 0

    foreach ($Abfrage in $Abfragen) {
        $Parameter = $BasisAbfrage.Clone()
        if (-not [string]::IsNullOrWhiteSpace([string]$Abfrage['Schalter'])) {
            $Parameter[$Abfrage['Schalter']] = $true
        }

        try {
            foreach ($Postfach in @(Get-Mailbox @Parameter)) {
                # Schluessel fuer die Zusammenfuehrung: Identity, sonst
                # DN, sonst Anzeigename - einzelne Eigenschaften koennen
                # bei Sonderpostfaechern fehlen.
                $Schluessel = Get-Text $Postfach.Identity
                if ([string]::IsNullOrWhiteSpace($Schluessel)) { $Schluessel = Get-Text $Postfach.DistinguishedName }
                if ([string]::IsNullOrWhiteSpace($Schluessel)) { $Schluessel = Get-Text $Postfach.DisplayName }
                if ([string]::IsNullOrWhiteSpace($Schluessel)) { $Schluessel = Get-Text $Postfach.PrimarySmtpAddress }
                if ([string]::IsNullOrWhiteSpace($Schluessel)) { $Laufnummer++; $Schluessel = "ohne-schluessel-$Laufnummer" }

                if (-not $Gesammelt.ContainsKey($Schluessel)) {
                    $Gesammelt[$Schluessel] = $Postfach
                    $Quellen[$Schluessel]   = @()
                }
                if (@($Quellen[$Schluessel]) -notcontains [string]$Abfrage['Name']) {
                    $Quellen[$Schluessel] += [string]$Abfrage['Name']
                }
            }
        }
        catch {
            # Einzelne Quelle nicht erreichbar: die uebrigen liefern
            # weiterhin eine brauchbare Liste, also nur protokollieren.
            Write-Log "Postfachabfrage '$($Abfrage['Name'])' schlug fehl: $($_.Exception.Message)" "WARNUNG"
        }
    }

    # Sortierung erst nach der Zusammenfuehrung - die Reihenfolge der
    # Abfragen soll die Anzeige nicht bestimmen. Als dritter Schluessel
    # dienst die Identity, weil mehrere SystemMailboxen denselben
    # Anzeigenamen ("Microsoft Exchange") tragen.
    # ACHTUNG: die Property-Liste bewusst EINZEILIG mit @(...) - bei
    # Zeilenumbruechen wertete PowerShell 5.1 die Expression-Hashtables
    # als eigene Ausdruecke aus und die Hashtables landeten mit in der
    # Ergebnisliste (drei Phantom-Eintraege "System.Collections.Hashtable").
    $SortierFelder  = @('Datenbank', 'AnzeigeName', 'Identitaet')
    $SortierObjekte = @($Gesammelt.Keys | ForEach-Object {
        [pscustomobject]@{
            Schluessel  = $_
            Datenbank   = Get-DatenbankAnzeige $Gesammelt[$_].Database
            AnzeigeName = Get-Text $Gesammelt[$_].DisplayName
            Identitaet  = Get-Text $Gesammelt[$_].Identity
        }
    })
    $SchluesselSortiert = @($SortierObjekte | Sort-Object -Property $SortierFelder | ForEach-Object { $_.Schluessel })

    # Alle MoveRequests einmalig abrufen und auf zwei Schluessel abbilden:
    # DistinguishedName des Postfachs und den Anzeigenamen. Danach kostet die
    # Zuordnung pro Postfach keinen zusätzlichen Exchange-Aufruf.
    $Bewegte = @{}
    foreach ($MoveRequest in @(Get-MoveRequest -ResultSize Unlimited -ErrorAction SilentlyContinue)) {
        $Status = if ($MoveRequest.Status) { [string]$MoveRequest.Status } else { "Unbekannt" }

        foreach ($Eigenschaft in @('Identity', 'DisplayName')) {
            try {
                $Schluessel = [string]$MoveRequest.$Eigenschaft
                if (-not [string]::IsNullOrWhiteSpace($Schluessel) -and -not $Bewegte.ContainsKey($Schluessel)) {
                    $Bewegte[$Schluessel] = $Status
                }
            }
            catch { }
        }
    }

    # @() rundet auch den Sonderfall ab: keine Treffer ergibt ein leeres
    # Array statt $null (JSON "Benutzer: null" hielte die JS-Seite fuer
    # einen Fehler).
    $Ergebnis = @(foreach ($Eintrag in $SchluesselSortiert) {
        $Postfach     = $Gesammelt[$Eintrag]
        $QuellenListe = @($Quellen[$Eintrag])

        # Archiv-Kennung: jede Quelle, die die -Archive-Abfrage geliefert
        # hat, ist ein Postfach mit aktiviertem Archiv - unabhaengig davon,
        # ob es noch aus der Grundabfrage kam.
        $HatArchiv = $QuellenListe -contains 'Archive'

        # Kategorie ermitteln: "Benutzer", die Bezeichnung der Sonderart
        # oder "" (Health-Postfach - gar nicht zeigen). Der Namensschnipsel
        # ist die zweite Quelle fuer Postfaecher ohne brauchbaren
        # RecipientTypeDetails-Wert (SystemMailbox{...} und Konsorten).
        $SuchNamen = ((Get-Text $Postfach.Identity) + ' ' +
                      (Get-Text $Postfach.DisplayName) + ' ' +
                      (Get-Text $Postfach.Alias)).Trim()
        $Art = Get-PostfachTyp -RecipientTypeDetails (Get-Text $Postfach.RecipientTypeDetails) `
                               -Name $SuchNamen

        # Postfach, das NUR die Archiv-Abfrage liefert, ist ein eigenes
        # Archiv-Postfach -> Kategorie "Archiv". Kommt es auch aus der
        # Grundabfrage (Hauptpostfach mit Archiv), bleibt es Benutzer-
        # postfach - sonst verschwanden Archivbenutzer aus der normalen
        # Ansicht, waehrend sie dort weiterhin gebraucht werden.
        if ($Art -eq "Benutzer" -and $HatArchiv -and ($QuellenListe -notcontains 'Standard')) {
            $Art = "Archiv"
        }

        $Passt = switch ($Typ) {
            "benutzer" { $Art -eq "Benutzer" }
            "sonder"   { $Art -ne "Benutzer" -and $Art -ne "" }
            "alle"     { $Art -ne "" }
            "archiv"   { $HatArchiv -and $Art -ne "" }
        }
        if (-not $Passt) { continue }

        $Status = $null

        if ($Bewegte.ContainsKey([string]$Postfach.DistinguishedName)) {
            $Status = $Bewegte[[string]$Postfach.DistinguishedName]
        }
        elseif ($Bewegte.ContainsKey([string]$Postfach.DisplayName)) {
            $Status = $Bewegte[[string]$Postfach.DisplayName]
        }

        # Auswahl-Schluessel: zunaechst die SMTP-Adresse. Sonderpostfaecher
        # haben nicht immer eine eigene Adresse - ohne Rueckfaellung stuerzte
        # die Auswahl auf einem leeren Wert zusammen (alle solchen
        # Postfaecher gehoerten dann zu EINEM Kaestchen und die Verschiebung
        # haette nur eines davon getroffen). Darum Alias, Anzeige- und
        # schliesslich den DN als Ersatz - New-MoveRequest akzeptiert alle
        # vier Formen als -Identity.
        $Schluessel = Get-Text $Postfach.PrimarySmtpAddress
        if ([string]::IsNullOrWhiteSpace($Schluessel)) { $Schluessel = Get-Text $Postfach.Alias }
        if ([string]::IsNullOrWhiteSpace($Schluessel)) { $Schluessel = Get-Text $Postfach.DisplayName }
        if ([string]::IsNullOrWhiteSpace($Schluessel)) { $Schluessel = Get-Text $Postfach.DistinguishedName }

        [pscustomobject]@{
            AnzeigeName = Get-Text $Postfach.DisplayName
            Adresse     = Get-Text $Postfach.PrimarySmtpAddress
            Alias       = Get-Text $Postfach.Alias
            Datenbank   = Get-DatenbankAnzeige $Postfach.Database
            Typ         = $Art
            Archiv      = [bool]$HatArchiv
            Schluessel  = $Schluessel
            Bewegt      = ($null -ne $Status)
            Status      = Get-Text $Status
        }
    })

    # Komma vor @(): die Rueckgabe bleibt auch bei null Treffern ein leeres
    # Array und wird beim schlichten Aufrufer ($Benutzer = Get-...) nicht zu
    # $null - sonst lieferte die API "Benutzer: null" (gleiche Regel wie in
    # Get-DatenbankListe). Aufrufer duerfen die Rueckgabe deshalb NICHT mit
    # @(...) umschliessen, sonst entsteht ein Phantom-Element.
    return ,@($Ergebnis)
}

function Start-Verschiebeauftrag {
    <#
    .SYNOPSIS
        Validiert die Eingaben und startet die Erstellung der MoveRequests in
        einem Hintergrund-Job.

    .DESCRIPTION
        Zwei Modi:

        Durchgaengig   New-MoveRequest ohne Zusaatzparameter - der Zug laeuft
                       bis Completed.

        Suspend        New-MoveRequest -SuspendWhenReadyToComplete: der Zug
                       laeuft bis "ReadyToComplete" (klassische 95-%-Stufe)
                       und haelt dort an, bevor die Finalisierung das Postfach
                       sperrt. Spaeter per Resume-MoveRequest fertigstellen.

        Der Job laeuft ausserhalb der Request-Schleife. Deshalb antwortet die
        API sofort und das Live-Dashboard blickt waehrenddessen weiter.

    .PARAMETER Quelle
        Quelldatenbank (nur fuer die Protokollierung und Validierung).
    .PARAMETER Ziel
        Ziel-Datenbank fuer -TargetDatabase.
    .PARAMETER Benutzer
        Adressen (PrimarySmtpAddress) der zu verschiebenden Postfaecher.
    .PARAMETER MitSuspend
        $true = bis 95 % laufen lassen und suspendieren.
    .PARAMETER BatchName
        Optionaler Batch-Name fuer spaetere Resume-/Remove-Aktionen.
    .PARAMETER Prioritaet
        Wert fuer -Priority (Low, Normal, High, Critical, Emergency).
        Leer = Normal.
    .PARAMETER Vorabtest
        'aus'     = wie bisher, direkt erstellen.
        'pruefen' = vor jedem Postfach einen Test mit -WhatIf ausfuehren
                    und nur bei Bestehen den echten MoveRequest erstellen.
        'nur'     = ausschliesslich mit -WhatIf pruefen, es werden keine
                    MoveRequests erstellt.
    .PARAMETER BadItemLimit
        Wert fuer -BadItemLimit: Anzahl kaputter Objekte, die beim Verschieben
        uebersprungen werden duerfen. Erlaubt: 0, 1, 10, 20, 50, 100.
        0 = Exchange-Standard (kein Fehler wird toleriert).
    .OUTPUTS
        Hashtable. Entweder 'Fehler' (Validierung fehlgeschlagen) oder
        'AuftragId' plus 'Meldung'.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Quelle = "",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Ziel = "",

        [Parameter(Mandatory = $false)]
        [AllowEmptyCollection()]
        [string[]]$Benutzer = @(),

        [Parameter(Mandatory = $false)]
        [bool]$MitSuspend = $false,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$BatchName = "",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Prioritaet = "Normal",

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Vorabtest = "aus",

        [Parameter(Mandatory = $false)]
        [int]$BadItemLimit = 0
    )

    $Benutzer = @($Benutzer | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })

    if ($Benutzer.Count -eq 0) {
        return @{ Fehler = (TM 'msg.noMailboxesSelected') }
    }
    if ([string]::IsNullOrWhiteSpace($Ziel)) {
        return @{ Fehler = (TM 'msg.noTargetDb') }
    }
    if (-not [string]::IsNullOrWhiteSpace($Quelle) -and $Quelle -eq $Ziel) {
        return @{ Fehler = (TM 'msg.sourceTargetSame') }
    }

    # --- Ziel-Datenbank pruefen: existent und gemountet ---------------------
    # Nur die harten Faelle werden blockiert. Eine eingehende Pruefung der
    # Systemmailboxen hat sich in der Praxis als Fehlalarm herausgestellt
    # (ein ganz normales New-MoveRequest reicht) - deshalb wird hier nichts
    # weiter abgefragt. Tritt beim Verschieben ein MAPI-Fehler auf, liefert
    # der Hintergrund-Job trotzdem einen verstaendlichen Zusatz-Hinweis.
    $ZielDb = $null
    try {
        $ZielDb = Get-MailboxDatabase -Identity $Ziel -Status -ErrorAction Stop
    }
    catch {
        return @{ Fehler = (TM 'msg.targetNotFound' @{ Target = $Ziel; Error = $_.Exception.Message }) }
    }

    $IstGemountet = $true
    try { $IstGemountet = [bool]$ZielDb.Mounted } catch { }
    if (-not $IstGemountet) {
        return @{ Fehler = (TM 'msg.targetNotMounted' @{ Target = $Ziel }) }
    }

    # Prioritaet pruefen (Werte von -Priority bei New-MoveRequest)
    if ([string]::IsNullOrWhiteSpace($Prioritaet)) { $Prioritaet = "Normal" }
    $ZulaessigePrioritaeten = @('Low', 'Normal', 'High', 'Critical', 'Emergency')
    if ($ZulaessigePrioritaeten -notcontains $Prioritaet) {
        return @{ Fehler = (TM 'msg.invalidPriority' @{ Priority = $Prioritaet; Allowed = ($ZulaessigePrioritaeten -join ', ') }) }
    }
    # Schreibweise normieren, damit Log und Job immer gleiche Gross-/Klein-
    # schreibung sehen (der Vergleich oben ist ohnehin nicht schriftsprachlich).
    $Prioritaet = @($ZulaessigePrioritaeten | Where-Object { $_ -eq $Prioritaet })[0]

    # Vorabtest-Modus (-WhatIf) pruefen: aus / pruefen / nur
    if ([string]::IsNullOrWhiteSpace($Vorabtest)) { $Vorabtest = "aus" }
    $ZulaessigeVorabtests = @('aus', 'pruefen', 'nur')
    if ($ZulaessigeVorabtests -notcontains $Vorabtest) {
        return @{ Fehler = (TM 'msg.invalidPretest' @{ Pretest = $Vorabtest }) }
    }
    $Vorabtest = @($ZulaessigeVorabtests | Where-Object { $_ -eq $Vorabtest })[0]

    # BadItemLimit: nur die in der Oberflaeche angebotenen Werte zulassen
    $ZulaessigeBadItems = @(0, 1, 10, 20, 50, 100)
    if ($ZulaessigeBadItems -notcontains $BadItemLimit) {
        return @{ Fehler = (TM 'msg.invalidBadItems' @{ Value = $BadItemLimit; Allowed = ($ZulaessigeBadItems -join ', ') }) }
    }

    if (-not [string]::IsNullOrWhiteSpace($Quelle)) {
        try {
            Get-MailboxDatabase -Identity $Quelle -ErrorAction Stop | Out-Null
        }
        catch {
            return @{ Fehler = (TM 'msg.sourceNotFound' @{ Source = $Quelle; Error = $_.Exception.Message }) }
        }
    }

    # Pruefen, ob der Suspend-Parameter existiert (nur einmal pro Laufzeit)
    if ($null -eq $script:SuspendParameterPrueft) {
        try {
            $Befehl   = Get-Command New-MoveRequest -ErrorAction Stop
            $Parameter = $Befehl.Parameters

            # Bei Cmdlets steckt die Liste in .Parameters, bei Funktionen erst
            # in .ScriptBlock.Parameters. Ohne diese Unterscheidung faellt die
            # Pruefung stillschweigend auf "nein" zurueck.
            if ($null -eq $Parameter -and $Befehl.ScriptBlock) {
                $Parameter = $Befehl.ScriptBlock.Parameters
            }

            $script:SuspendParameterPrueft = ($null -ne $Parameter -and $Parameter.ContainsKey('SuspendWhenReadyToComplete'))
        }
        catch {
            $script:SuspendParameterPrueft = $false
        }
    }
    if ($MitSuspend -and -not $script:SuspendParameterPrueft) {
        return @{ Fehler = (TM 'msg.suspendUnavailable') }
    }

    if ([string]::IsNullOrWhiteSpace($BatchName)) {
        $BatchName = "WebGUI_" + (Get-Date -Format "yyyyMMdd_HHmmss")
    }

    # --- Hintergrund-Job ---------------------------------------------------
    # Der Job ist absichtlich eigenstaendig: er darf keine Variablen oder
    # Funktionen des Hauptskripts referenzieren, weil Start-Job in einer
    # frischen PowerShell-Prozessumgebung laeuft.
    $SkriptBlock = {
        param(
            [string]$ZielDatenbank,
            [string[]]$Adressen,
            [bool]$MitSuspend,
            [string]$Batch,
            [string]$Prioritaet,
            [string]$Vorabtest,
            [int]$BadItemLimit
        )
        # Fehler verstehen machen (v2.13): der Hintergrund-Job laeuft in
        # einer frischen PowerShell - ohne Ausfuehrungskontext und
        # technische Details war unklar, warum der Mailbox Replication
        # Service "Der Zugriff wurde verweigert" gab, waehrend derselbe
        # Befehl in der Exchange Management Shell lief. Die Funktion steht
        # HIER im Skriptblock: Start-Job kennt weder Variablen noch
        # Funktionen des Hauptskripts - deshalb steht derselbe Code in
        # beiden Job-Bloecken.
        function Baue-FehlerText {
            param(
                [System.Management.Automation.ErrorRecord]$Fehler,

                [Parameter(Mandatory = $false)]
                [AllowEmptyString()]
                [string]$ZielDb = ""
            )

            $Text = [string]$Fehler.Exception.Message

            # Ziel-DB-Problem aus der Praxis: der MRS kommt nicht an den
            # Store der Ziel-Datenbank.
            if (-not [string]::IsNullOrWhiteSpace($ZielDb) -and
                $Text -match 'NoSupport|Unable to open message store|Fehler beim Kommunizieren mit der Postfachdatenbank') {
                $Text += " || Hinweis: Der Store der Ziel-Datenbank $ZielDb konnte nicht geoeffnet werden. " +
                         "Pruefen: ist die DB gemountet und besitzt sie eine Systemmailbox? " +
                         "(Get-MailboxDatabase -Identity $ZielDb -Status | Select Name,Mounted,Status)"
            }

            # Der MRS hat die Identitaet aufgeloest UND den Aufruf danach
            # abgelehnt: Rechte-/Kontextproblem, kein technischer Fehler.
            if ($Text -match 'Zugriff wurde verweigert|Access is denied|Access denied|UnauthorizedAccess') {
                $Text += " || Hinweis: Der Mailbox Replication Service hat den Aufruf abgelehnt - " +
                         "ein Rechte- oder Kontextproblem, kein technischer Fehler. Vergleichstest: " +
                         "denselben Befehl manuell in der Exchange Management Shell ausfuehren. " +
                         "Geht er dort, liegt es am Startkontext des Dashboards (ggf. als " +
                         "Administrator starten) - den mitgelieferten Kontext unten auswerten."
            }

            # Technische Details: der Exception-Typ sagt mehr als der
            # Klartext - und kam bisher in der Meldung gar nicht vor.
            $Text += " || Technisch: " + [string]$Fehler.Exception.GetType().FullName
            if ($Fehler.Exception.InnerException) {
                $Text += " | Inner: " + [string]$Fehler.Exception.InnerException.Message
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$Fehler.FullyQualifiedErrorId)) {
                $Text += " | FQID: " + [string]$Fehler.FullyQualifiedErrorId
            }

            # Welches Konto laeuft IM JOB? Start-Job ist ein Kindprozess
            # des Dashboards mit demselben Token - steht dieser Kontext hier
            # drin, ist die Vermutung, der Job laeuft in einem anderen
            # Konto, ausgeschlossen.
            try {
                $Ident = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $IstAdmin = (New-Object System.Security.Principal.WindowsPrincipal($Ident)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
                $Bitness  = if ([Environment]::Is64BitProcess) { '64-Bit' } else { '32-Bit' }
                $Text += " || Kontext: " + [string]$Ident.Name +
                         " | Administrator: " + $IstAdmin +
                         " | PowerShell " + [string]$PSVersionTable.PSVersion + " ($Bitness)"
            }
            catch { }

            return $Text
        }
        try {
            if (-not (Get-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue)) {
                Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
            }
        }
        catch {
            $Grund = "Exchange Snap-In konnte nicht geladen werden: " + (Baue-FehlerText -Fehler $_)
            foreach ($Adresse in $Adressen) {
                [pscustomobject]@{ Benutzer = $Adresse; Ok = $false; Meldung = $Grund }
            }
            return
        }

        foreach ($Adresse in $Adressen) {
            $Ok      = $false
            $Meldung = ""

            # KEIN -Confirm: New-*Cmdlets haben keine Rueckfrage, und ein
            # ueberfluessiger Switch landet nur als Unsinn im Cmdlet-Log.
            # Wichtig: Switch-Parameter werden per Splatting mit $true
            # uebergeben - das erscheint im Event-Log als
            # -SuspendWhenReadyToComplete "True", was korrekt ist
            # (Exchange loggt die Werte als String, "-Confirm False" sah
            # also auch vorher richtig aus und war nie die Fehlerursache).
            $Parameter = @{
                Identity       = $Adresse
                TargetDatabase = $ZielDatenbank
                BatchName      = $Batch
                ErrorAction    = "Stop"
            }

            # -Priority (Low/Normal/High/Critical/Emergency), Standard Normal
            if (-not [string]::IsNullOrWhiteSpace($Prioritaet)) {
                $Parameter['Priority'] = $Prioritaet
            }

            # -BadItemLimit: Anzahl kaputter Objekte, die uebersprungen
            # werden duerfen (0 = Exchange-Standard, nichts toleriert)
            $Parameter['BadItemLimit'] = $BadItemLimit

            if ($MitSuspend) {
                $Parameter['SuspendWhenReadyToComplete'] = $true
            }

            # $Weitermachen = $false bedeutet: Ergebnis steht schon fest,
            # der echte Lauf (oder der Rest der Schleife) wird uebersprungen.
            $Weitermachen = $true

            # --- Vorabtest mit -WhatIf ---------------------------------------
            # New-MoveRequest validiert auch bei -WhatIf (inklusive des
            # Store-Aufbaus zur Ziel-Datenbank) und erstellt nichts. Damit
            # laesst sich vorher pruefen, ob das Postfach ueberhaupt
            # verschiebbar ist.
            if ($Vorabtest -eq 'nur' -or $Vorabtest -eq 'pruefen') {
                try {
                    $PruefParameter = @{}
                    foreach ($Schluessel in @($Parameter.Keys)) {
                        $PruefParameter[$Schluessel] = $Parameter[$Schluessel]
                    }
                    $PruefParameter['WhatIf'] = $true

                    New-MoveRequest @PruefParameter | Out-Null

                    if ($Vorabtest -eq 'nur') {
                        $Ok            = $true
                        $Meldung       = (TM 'msg.whatIfPassed')
                        $Weitermachen  = $false
                    }
                }
                catch {
                    # Technik/Kontext/Store-Hinweis baut die Funktion - mit
                    # demselben Text wie im echten Lauf, nur mit Prefix.
                    $Meldung      = (TM 'msg.whatIfFailed' @{ Error = (Baue-FehlerText -Fehler $_ -ZielDb $ZielDatenbank) })
                    $Weitermachen = $false
                }
            }

            if ($Weitermachen) {
                try {
                    New-MoveRequest @Parameter | Out-Null

                    $Ok = $true
                    if ($Vorabtest -eq 'pruefen') {
                        $Meldung = (TM 'msg.whatIfPassed') + ", "
                    }
                    else {
                        $Meldung = ""
                    }

                    if ($MitSuspend) {
                        $Meldung += (TM 'msg.moveCreatedSuspend' @{ Priority = $Prioritaet })
                    }
                    else {
                        $Meldung += (TM 'msg.moveCreatedDirect' @{ Priority = $Prioritaet })
                    }
                }
                catch {
                    $Meldung = Baue-FehlerText -Fehler $_ -ZielDb $ZielDatenbank
                }
            }

            # Ausgabe in den Job-Outputstream: das Dashboard sieht so den
            # Fortschritt, solange der Job laeuft (Receive-Job -Keep).
            [pscustomobject]@{ Benutzer = $Adresse; Ok = $Ok; Meldung = $Meldung }
        }
    }

    try {
        $Job = Start-Job -Name "WebGUI_Verschiebung" -ScriptBlock $SkriptBlock `
                         -ArgumentList $Ziel, $Benutzer, $MitSuspend, $BatchName, $Prioritaet, $Vorabtest, $BadItemLimit
    }
    catch {
        return @{ Fehler = (TM 'msg.jobStartFailed' @{ Error = $_.Exception.Message }) }
    }

    $script:VersandAuftragNr++
    $AuftragId = $script:VersandAuftragNr

    $script:VersandAuftraege[[string]$AuftragId] = [pscustomobject]@{
        Id            = $AuftragId
        JobId         = $Job.Id
        StartZeit     = Get-Date
        EndeZeit      = $null
        Art           = 'Verschiebung'
        Quelle        = $Quelle
        Ziel          = $Ziel
        Suspend       = $MitSuspend
        Gesamt        = $Benutzer.Count
        Erstellt      = 0
        FehlerAnzahl  = 0
        BatchName     = $BatchName
        Prioritaet    = $Prioritaet
        Vorabtest     = $Vorabtest
        BadItemLimit  = $BadItemLimit
        Status        = "Running"
        Meldung       = ""
        Ergebnis      = @()
        Abgeschlossen = $false
    }

    $ModusText     = if ($MitSuspend) { "suspendieren vor dem Abschluss (95 %)" } else { "durchgaengige Migration" }
    $VorabtestText = switch ($Vorabtest) {
        'pruefen' { "Vorabtest mit -WhatIf, danach erstellen" }
        'nur'     { "nur -WhatIf-Pruefung, nichts erstellen" }
        default   { "kein Vorabtest" }
    }
    Write-Log -Nachricht (TM 'log.moveJobStarted' @{
        Id         = $AuftragId
        Count      = $Benutzer.Count
        Source     = $Quelle
        Target     = $Ziel
        Priority   = $Prioritaet
        BadItemLimit = $BadItemLimit
        Pretest    = $VorabtestText
        Mode       = $ModusText
        Batch      = $BatchName
    }) -Typ "INFO"

    $BadItemsText = "BadItems: $BadItemLimit"
    if ($Vorabtest -eq 'nur') {
        $StartMeldung = "$($Benutzer.Count) Postfach/Postfaecher werden nur mit -WhatIf geprueft - es wird nichts verschoben (Batch: $BatchName)."
    }
    elseif ($Vorabtest -eq 'pruefen') {
        $StartMeldung = "$($Benutzer.Count) Postfach/Postfaecher werden zuerst mit -WhatIf geprueft und danach nach '$Ziel' verschoben (Prioritaet: $Prioritaet, $BadItemsText, Batch: $BatchName)."
    }
    else {
        $StartMeldung = "$($Benutzer.Count) Postfach/Postfaecher werden nach '$Ziel' verschoben (Prioritaet: $Prioritaet, $BadItemsText, Batch: $BatchName)."
    }

    return @{
        AuftragId = $AuftragId
        Meldung   = $StartMeldung
    }
}

function Get-VersandStatus {
    <#
    .SYNOPSIS
        Liefert den Stand aller Verschiebeauftraege fuer /api/move-status.

    .DESCRIPTION
        Erledigte Hintergrund-Jobs werden hier abgeholt (Receive-Job) und
        entfernt (Remove-Job). Solange der Job laeuft, wird mit -Keep nur
        mitgezaehlt, wie viele Ergebnisse bereits vorliegen - die bereits
        ausgelieferten Zeilen gehen dadurch nicht verloren.

        Abgeschlossene Auftraege bleiben $script:VersandAufbewahrungMin
        Minuten sichtbar, danach werden sie verworfen.
    .OUTPUTS
        Array von PSCustomObject, neueste zuerst.
    #>

    $Jetzt     = Get-Date
    $Rueckgabe = New-Object System.Collections.Generic.List[object]

    foreach ($Schluessel in @($script:VersandAuftraege.Keys)) {
        $Auftrag = $script:VersandAuftraege[$Schluessel]

        if ($Auftrag.Abgeschlossen -and $Auftrag.EndeZeit -and
            ($Jetzt - $Auftrag.EndeZeit).TotalMinutes -gt $script:VersandAufbewahrungMin) {
            $script:VersandAuftraege.Remove($Schluessel)
            continue
        }

        # Art der Aktion: 'Verschiebung' (Standard), 'Resume' oder
        # 'Entfernen' - steuert Meldungstext und Log-Woerter unten.
        $ArtText = [string]$Auftrag.Art
        if ([string]::IsNullOrWhiteSpace($ArtText)) { $ArtText = 'Verschiebung' }
        $ArtLabel = 'Verschiebeauftrag'
        if ($ArtText -ne 'Verschiebung') { $ArtLabel = 'MoveRequest-Aktion' }

        if (-not $Auftrag.Abgeschlossen) {
            $Job = $null
            if ($Auftrag.JobId) { $Job = Get-Job -Id $Auftrag.JobId -ErrorAction SilentlyContinue }

            if ($null -eq $Job) {
                $Auftrag.Status        = "Failed"
                $Auftrag.Meldung       = "Der Hintergrund-Job ist nicht mehr vorhanden (Skript evtl. neu gestartet)."
                $Auftrag.Abgeschlossen = $true
                $Auftrag.EndeZeit      = $Jetzt
            }
            elseif (@('NotStarted', 'Running', 'Blocked') -contains [string]$Job.State) {
                $Teil = @(Receive-Job -Id $Auftrag.JobId -Keep -ErrorAction SilentlyContinue |
                    Where-Object { $_ -and $_.PSObject.Properties['Benutzer'] })

                $Auftrag.Erstellt     = @($Teil | Where-Object { $_.Ok }).Count
                $Auftrag.FehlerAnzahl = @($Teil | Where-Object { -not $_.Ok }).Count
                $Auftrag.Status       = "Laufend"
            }
            else {
                # Completed / Failed / Stopped: Ergebnis komplett abholen
                $FehlerStream = @()
                $RohErgebnis  = @(Receive-Job -Id $Auftrag.JobId -ErrorAction SilentlyContinue -ErrorVariable +FehlerStream)
                Remove-Job -Id $Auftrag.JobId -Force -ErrorAction SilentlyContinue

                $Auftrag.JobId         = $null
                # Receive-Job haeftet PSComputerName/RunspaceId an die Objekte
                # an - fuer die JSON-Antwort auf ein Trio reduzieren.
                $Auftrag.Ergebnis      = @($RohErgebnis |
                                            Where-Object { $_ -and $_.PSObject.Properties['Benutzer'] } |
                                            ForEach-Object {
                                                [pscustomobject]@{
                                                    Benutzer = [string]$_.Benutzer
                                                    Ok       = [bool]$_.Ok
                                                    Meldung  = [string]$_.Meldung
                                                }
                                            })
                $Auftrag.Erstellt      = @($Auftrag.Ergebnis | Where-Object { $_.Ok }).Count
                $Auftrag.FehlerAnzahl  = @($Auftrag.Ergebnis | Where-Object { -not $_.Ok }).Count
                $Auftrag.EndeZeit      = $Jetzt
                $Auftrag.Abgeschlossen = $true
                Status        = if ([string]$Job.State -eq 'Completed') { "Completed" } else { "Failed" }

                $JobFehler = @()
                foreach ($FehlerText in $FehlerStream) { $JobFehler += [string]$FehlerText }
                try {
                    if ($Job.ChildJobs -and $Job.ChildJobs[0].JobStateInfo.Reason) {
                        $JobFehler += [string]$Job.ChildJobs[0].JobStateInfo.Reason
                    }
                }
                catch { }

                if ($JobFehler.Count -gt 0) {
                    $Auftrag.Meldung = ($JobFehler -join " | ")
                }
                else {
                    switch ($ArtText) {
                        'Resume' {
                            $Auftrag.Meldung = "$($Auftrag.Erstellt) von $($Auftrag.Gesamt) suspendierten Anforderungen fortgesetzt, $($Auftrag.FehlerAnzahl) Fehler."
                        }
                        'Entfernen' {
                            $Auftrag.Meldung = "$($Auftrag.Erstellt) von $($Auftrag.Gesamt) abgeschlossenen Anforderungen entfernt, $($Auftrag.FehlerAnzahl) Fehler."
                        }
                        default {
                            switch ([string]$Auftrag.Vorabtest) {
                                'nur' {
                                    $Auftrag.Meldung = "$($Auftrag.Erstellt) von $($Auftrag.Gesamt) Postfaecher bestanden die WhatIf-Pruefung, $($Auftrag.FehlerAnzahl) Fehler. Es wurden keine MoveRequests erstellt."
                                }
                                'pruefen' {
                                    $Auftrag.Meldung = "$($Auftrag.Erstellt) von $($Auftrag.Gesamt) MoveRequests erstellt (alle bestanden zuerst die WhatIf-Pruefung), $($Auftrag.FehlerAnzahl) Fehler."
                                }
                                default {
                                    $Auftrag.Meldung = "$($Auftrag.Erstellt) von $($Auftrag.Gesamt) MoveRequests erstellt, $($Auftrag.FehlerAnzahl) Fehler."
                                }
                            }
                        }
                    }
                }

                $AktionsWort = TM 'log.actionWordCreated'
                if ($ArtText -eq 'Resume')    { $AktionsWort = TM 'log.actionWordResumed' }
                if ($ArtText -eq 'Entfernen') { $AktionsWort = TM 'log.actionWordRemoved' }

                if ($Auftrag.Status -eq "Completed" -and $Auftrag.FehlerAnzahl -eq 0) {
                    if ($ArtText -eq 'Resume') {
                        Write-Log -Nachricht (TM 'log.actionJobResumed' @{ Label = $ArtLabel; Id = $Auftrag.Id; Done = $Auftrag.Erstellt }) -Typ "INFO"
                    }
                    elseif ($ArtText -eq 'Entfernen') {
                        Write-Log -Nachricht (TM 'log.actionJobRemoved' @{ Label = $ArtLabel; Id = $Auftrag.Id; Done = $Auftrag.Erstellt }) -Typ "INFO"
                    }
                    elseif ([string]$Auftrag.Vorabtest -eq 'nur') {
                        Write-Log -Nachricht (TM 'log.actionJobChecked' @{ Label = $ArtLabel; Id = $Auftrag.Id; Done = $Auftrag.Erstellt; Total = $Auftrag.Gesamt }) -Typ "INFO"
                    }
                    else {
                        Write-Log -Nachricht (TM 'log.actionJobCreated' @{ Label = $ArtLabel; Id = $Auftrag.Id; Done = $Auftrag.Erstellt }) -Typ "INFO"
                    }
                }
                else {
                    Write-Log -Nachricht (TM 'log.actionJobFailed' @{
                        Label   = $ArtLabel
                        Id      = $Auftrag.Id
                        Status  = $Auftrag.Status
                        Done    = $Auftrag.Erstellt
                        Action  = $AktionsWort
                        Errors  = $Auftrag.FehlerAnzahl
                        Message = $Auftrag.Meldung
                    }) -Typ "WARNUNG"
                }
            }
        }

        $Rueckgabe.Add([pscustomobject]@{
            Id        = $Auftrag.Id
            Status    = $Auftrag.Status
            Art       = $ArtText
            Quelle    = $Auftrag.Quelle
            Ziel      = $Auftrag.Ziel
            Suspend   = $Auftrag.Suspend
            Gesamt    = $Auftrag.Gesamt
            Erstellt  = $Auftrag.Erstellt
            Fehler    = $Auftrag.FehlerAnzahl
            BatchName = $Auftrag.BatchName
            Prioritaet = $Auftrag.Prioritaet
            Vorabtest = $Auftrag.Vorabtest
            BadItemLimit = $Auftrag.BadItemLimit
            Meldung   = $Auftrag.Meldung
            Ergebnis  = @($Auftrag.Ergebnis)
            Start     = $Auftrag.StartZeit.ToString("HH:mm:ss")
        })
    }

    return ,@($Rueckgabe | Sort-Object Id -Descending)
}

function Start-MoveAktion {
    <#
    .SYNOPSIS
        Fortsetzen suspendierter oder Loeschen abgeschlossener MoveRequests
        (Resume-MoveRequest / Remove-MoveRequest) - als Hintergrund-Job.

    .DESCRIPTION
        Zwei Aktionen ueber denselben Weg:

        Resume      Suspendierte Anforderungen werden fortgesetzt und laufen
                    danach bis zum Abschluss weiter - der klassische Fall
                    nach der 95-%-Suspendierung (-SuspendWhenReadyToComplete).

        Entfernen   Abgeschlossene MoveRequests werden aus Exchange entfernt.
                    Betroffen sind ausschliesslich die Anforderungs-Eintraege,
                    die Postfaecher bleiben unberuehrt (Exchange raegt sie
                    nach 24 h ohnehin selbst auf).

        Ausgewaehlt wird entweder eine Anforderung (Identity - eine oder
        mehrere, die Mehrfachauswahl der GUI schickt alle auf einmal),
        ein ganzer Batch (BatchName) oder alles (Alle). Wie bei der
        Verschiebung laeuft die Arbeit in einem eigenen Hintergrund-Job:
        die Anfrage antwortet sofort und der Fortschritt kommt ueber
        /api/move-status. Ein Resume ueber hunderte Anforderungen
        wuerde sonst die komplette Request-Schleife anhalten.

    .PARAMETER Aktion
        'Resume' (suspendierte fortssetzen) oder 'Entfernen'
        (abgeschlossene entfernen).
    .PARAMETER BatchName
        Einschraenkung auf einen Batch. Leer ist nur zusammen mit -Alle
        oder -Identity zulaessig.
    .PARAMETER Alle
        $true = alle passenden Anforderungen, unabhaengig vom Batch.
    .PARAMETER Identity
        Identity EINER Anforderung (die Tabelle liefert sie pro Zeile)
        oder ein Array von Identities aus der Mehrfachauswahl. Leer,
        wenn ueber Batch oder Alle gearbeitet wird. Identities, die nicht
        aufgeloest werden koennen, werden protokolliert und uebersprungen -
        der Rest der Auswahl laeuft trotzdem.
    .OUTPUTS
        Hashtable. Entweder 'Fehler' (Validierung/Abfrage fehlgeschlagen) oder
        'AuftragId' plus 'Meldung'.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Resume', 'Entfernen')]
        [string]$Aktion,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$BatchName = "",

        [Parameter(Mandatory = $false)]
        [bool]$Alle = $false,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowEmptyCollection()]
        [string[]]$Identity = @()
    )

    # Identity kann EINE Anforderung (Einzel-Button) oder MEHRERE enthalten
    # (Mehrfachauswahl in der GUI). Leere Eintraege und Dubletten fallen raus.
    $ZielIds = @($Identity |
        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
        Select-Object -Unique)
    $Einzelziel = $ZielIds.Count -gt 0

    if (-not $Alle -and -not $Einzelziel -and [string]::IsNullOrWhiteSpace($BatchName)) {
        return @{ Fehler = (TM 'msg.actionNoTarget') }
    }

    # Der Zielbefehl muss existieren, sonst liefert der Job nur Fehlerzeilen.
    $BefehlsName = 'Remove-MoveRequest'
    if ($Aktion -eq 'Resume') { $BefehlsName = 'Resume-MoveRequest' }
    try {
        Get-Command $BefehlsName -ErrorAction Stop | Out-Null
    }
    catch {
        return @{ Fehler = (TM 'msg.commandUnavailable' @{ Command = $BefehlsName; Error = $_.Exception.Message }) }
    }

    # --- passende Anforderungen suchen -------------------------------------
    try {
        if ($Einzelziel) {
            # Jede Identity einzeln auflösen: eine Mehrfachauswahl darf nicht
            # an einer unbekannten Adresse hängenbleiben. Identities, die
            # nicht mehr existieren (z.B. zwischenzeitlich abgeschlossene),
            # werden protokolliert und übersprungen.
            $Gefunden    = @()
            $OhneTreffer = @()

            foreach ($EineIdentity in $ZielIds) {
                try {
                    $Gefunden += @(Get-MoveRequest -Identity $EineIdentity -ErrorAction Stop)
                }
                catch {
                    $OhneTreffer += $EineIdentity
                }
            }

            if ($OhneTreffer.Count -gt 0) {
                $Nennung = ($OhneTreffer | Select-Object -First 5) -join "', '"
                Write-Log -Nachricht (TM 'log.missingRequests' @{
                    Missing   = $OhneTreffer.Count
                    Selected  = $ZielIds.Count
                    List      = $Nennung
                }) -Typ "WARNUNG"
            }

            $AlleAnforderungen = $Gefunden
        }
        elseif ($Alle) {
            $AlleAnforderungen = @(Get-MoveRequest -ResultSize Unlimited -ErrorAction Stop)
        }
        else {
            $AlleAnforderungen = @(Get-MoveRequest -BatchName $BatchName -ResultSize Unlimited -ErrorAction Stop)
        }
    }
    catch {
        return @{ Fehler = (TM 'msg.moveQueryFailed' @{ Error = $_.Exception.Message }) }
    }

    # Suspendiert: 'Suspended' (SuspendWhenReadyToComplete) und
    # 'AutoSuspended' (automatisches Anhalten) - deshalb -like '*Suspend*'.
    $Passende = @($AlleAnforderungen | Where-Object {
        if ($Aktion -eq 'Resume') { [string]$_.Status -like '*Suspend*' }
        else { [string]$_.Status -eq 'Completed' }
    })

    if ($Passende.Count -eq 0) {
        $Wort = 'completed'
        if ($Aktion -eq 'Resume') { $Wort = 'suspended' }
        if ($Einzelziel) {
            if ($ZielIds.Count -eq 1) {
                return @{ Fehler = (TM 'msg.requestNotFoundSingle' @{ Identity = $ZielIds[0]; Word = $Wort }) }
            }
            return @{ Fehler = (TM 'msg.noneOfSelected' @{ Count = $ZielIds.Count; Word = $Wort }) }
        }
        if ($Alle) {
            return @{ Fehler = (TM 'msg.noMatchingMoveRequests' @{ Word = $Wort }) }
        }
        return @{ Fehler = (TM 'msg.noneInBatch' @{ Batch = $BatchName; Word = $Wort }) }
    }

    $Eintraege = @(foreach ($Anforderung in $Passende) {
        $Anzeige = [string]$Anforderung.DisplayName
        if ([string]::IsNullOrWhiteSpace($Anzeige)) { $Anzeige = [string]$Anforderung.Identity }
        [pscustomobject]@{
            Identity = [string]$Anforderung.Identity
            Anzeige  = $Anzeige
        }
    })

    $Gesamt = $Eintraege.Count

    # --- Hintergrund-Job ---------------------------------------------------
    # Eigenstaendig wie beim Verschiebeauftrag: Start-Job laeuft in einer
    # frischen PowerShell und kennt weder Variablen noch Funktionen hier.
    $SkriptBlock = {
        param(
            [array]$Eintraege,
            [string]$Aktion
        )
        # Fehler verstehen machen (v2.13): der Hintergrund-Job laeuft in
        # einer frischen PowerShell - ohne Ausfuehrungskontext und
        # technische Details war unklar, warum der Mailbox Replication
        # Service "Der Zugriff wurde verweigert" gab, waehrend derselbe
        # Befehl in der Exchange Management Shell lief. Die Funktion steht
        # HIER im Skriptblock: Start-Job kennt weder Variablen noch
        # Funktionen des Hauptskripts - deshalb steht derselbe Code in
        # beiden Job-Bloecken.
        function Baue-FehlerText {
            param(
                [System.Management.Automation.ErrorRecord]$Fehler,

                [Parameter(Mandatory = $false)]
                [AllowEmptyString()]
                [string]$ZielDb = ""
            )

            $Text = [string]$Fehler.Exception.Message

            # Ziel-DB-Problem aus der Praxis: der MRS kommt nicht an den
            # Store der Ziel-Datenbank.
            if (-not [string]::IsNullOrWhiteSpace($ZielDb) -and
                $Text -match 'NoSupport|Unable to open message store|Fehler beim Kommunizieren mit der Postfachdatenbank') {
                $Text += " || Hinweis: Der Store der Ziel-Datenbank $ZielDb konnte nicht geoeffnet werden. " +
                         "Pruefen: ist die DB gemountet und besitzt sie eine Systemmailbox? " +
                         "(Get-MailboxDatabase -Identity $ZielDb -Status | Select Name,Mounted,Status)"
            }

            # Der MRS hat die Identitaet aufgeloest UND den Aufruf danach
            # abgelehnt: Rechte-/Kontextproblem, kein technischer Fehler.
            if ($Text -match 'Zugriff wurde verweigert|Access is denied|Access denied|UnauthorizedAccess') {
                $Text += " || Hinweis: Der Mailbox Replication Service hat den Aufruf abgelehnt - " +
                         "ein Rechte- oder Kontextproblem, kein technischer Fehler. Vergleichstest: " +
                         "denselben Befehl manuell in der Exchange Management Shell ausfuehren. " +
                         "Geht er dort, liegt es am Startkontext des Dashboards (ggf. als " +
                         "Administrator starten) - den mitgelieferten Kontext unten auswerten."
            }

            # Technische Details: der Exception-Typ sagt mehr als der
            # Klartext - und kam bisher in der Meldung gar nicht vor.
            $Text += " || Technisch: " + [string]$Fehler.Exception.GetType().FullName
            if ($Fehler.Exception.InnerException) {
                $Text += " | Inner: " + [string]$Fehler.Exception.InnerException.Message
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$Fehler.FullyQualifiedErrorId)) {
                $Text += " | FQID: " + [string]$Fehler.FullyQualifiedErrorId
            }

            # Welches Konto laeuft IM JOB? Start-Job ist ein Kindprozess
            # des Dashboards mit demselben Token - steht dieser Kontext hier
            # drin, ist die Vermutung, der Job laeuft in einem anderen
            # Konto, ausgeschlossen.
            try {
                $Ident = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $IstAdmin = (New-Object System.Security.Principal.WindowsPrincipal($Ident)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
                $Bitness  = if ([Environment]::Is64BitProcess) { '64-Bit' } else { '32-Bit' }
                $Text += " || Kontext: " + [string]$Ident.Name +
                         " | Administrator: " + $IstAdmin +
                         " | PowerShell " + [string]$PSVersionTable.PSVersion + " ($Bitness)"
            }
            catch { }

            return $Text
        }
        try {
            if (-not (Get-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue)) {
                Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
            }
        }
        catch {
            $Grund = "Exchange Snap-In konnte nicht geladen werden: " + (Baue-FehlerText -Fehler $_)
            foreach ($Eintrag in $Eintraege) {
                [pscustomobject]@{ Benutzer = $Eintrag.Anzeige; Ok = $false; Meldung = $Grund }
            }
            return
        }

        foreach ($Eintrag in $Eintraege) {
            $Ok      = $false
            $Meldung = ""

            try {
                if ($Aktion -eq 'Resume') {
                    Resume-MoveRequest -Identity $Eintrag.Identity -ErrorAction Stop | Out-Null
                    $Ok      = $true
                    $Meldung = "Anforderung fortgesetzt - die Verschiebung laeuft jetzt bis zum Abschluss weiter."
                }
                else {
                    # Remove-* wuerde rueckfragen. Im Hintergrund-Job gibt es
                    # niemanden, der antworten koennte - deshalb -Confirm:$false.
                    Remove-MoveRequest -Identity $Eintrag.Identity -Confirm:$false -ErrorAction Stop | Out-Null
                    $Ok      = $true
                    $Meldung = "Abgeschlossene Anforderung entfernt - das Postfach bleibt unberuehrt."
                }
            }
            catch {
                $Meldung = Baue-FehlerText -Fehler $_
            }

            [pscustomobject]@{ Benutzer = $Eintrag.Anzeige; Ok = $Ok; Meldung = $Meldung }
        }
    }

    try {
        $Job = Start-Job -Name "WebGUI_MoveAktion" -ScriptBlock $SkriptBlock `
                         -ArgumentList $Eintraege, $Aktion
    }
    catch {
        return @{ Fehler = (TM 'msg.jobStartFailed' @{ Error = $_.Exception.Message }) }
    }

    $script:VersandAuftragNr++
    $AuftragId = $script:VersandAuftragNr

    $BatchAnzeige = $BatchName
    if ($Alle) { $BatchAnzeige = "" }
    $AuswahlText = "Batch '$BatchName'"
    if ($Alle) { $AuswahlText = "alle Anforderungen" }

    # Einzelziel: im Auftrag keine Batch-Kennung zeigen - der Name der
    # Anforderung steht ohnehin in der Meldung, und ein Batch-Button am
    # Auftrag wuerde hier fälschlich den ganzen Batch fortsetzen.
    if ($Einzelziel) {
        $BatchAnzeige = ""

        if ($ZielIds.Count -eq 1) {
            # Eine Anforderung: den Namen zeigen, nicht die Identity - so
            # steht in der Meldung, was der Benutzer in der Zeile anklickte.
            $EinzelName = [string]$Passende[0].DisplayName
            if ([string]::IsNullOrWhiteSpace($EinzelName)) { $EinzelName = [string]$Passende[0].Identity }
            $AuswahlText = "'$EinzelName'"
        }
        else {
            # Mehrfachauswahl: der Batch-Button am Auftrag wuerde hier
            # faelschlich den ganzen Batch fortsetzen - deshalb keine
            # Batch-Kennung, und "Mehrfachauswahl" statt einer Zahl: $AnzahlText
            # sagt ohnehin, wie viele Anforderungen wirklich dran sind.
            $AuswahlText = "Mehrfachauswahl"
        }
    }

    $script:VersandAuftraege[[string]$AuftragId] = [pscustomobject]@{
        Id            = $AuftragId
        JobId         = $Job.Id
        StartZeit     = Get-Date
        EndeZeit      = $null
        Art           = $Aktion
        Quelle        = ""
        Ziel          = ""
        Suspend       = $false
        Gesamt        = $Gesamt
        Erstellt      = 0
        FehlerAnzahl  = 0
        BatchName     = $BatchAnzeige
        Prioritaet    = ""
        Vorabtest     = ""
        BadItemLimit  = 0
        Status        = "Running"
        Meldung       = ""
        Ergebnis      = @()
        Abgeschlossen = $false
    }

    $AnzahlText = "$Gesamt Anforderung"
    if ($Gesamt -ne 1) { $AnzahlText = "$Gesamt Anforderungen" }

    Write-Log -Nachricht (TM 'log.actionStarted' @{
        Id       = $AuftragId
        Action   = $Aktion
        Count    = $AnzahlText
        Selection = $AuswahlText
    }) -Typ "INFO"

    if ($Aktion -eq 'Resume') {
        $StartMeldung = "Fortsetzung: $AnzahlText ($AuswahlText) - Resume-MoveRequest laeuft im Hintergrund, die Postfaecher ziehen bis zum Abschluss durch."
    }
    else {
        $StartMeldung = "Entfernen: $AnzahlText ($AuswahlText) - Remove-MoveRequest laeuft im Hintergrund, nur die Anforderungs-Eintraege, die Postfaecher bleiben unberuehrt."
    }

    return @{
        AuftragId = $AuftragId
        Meldung   = $StartMeldung
    }
}

# ============================================================================
# Region: Datensammlung
# ============================================================================

# Skript fuer einen Statistikabruf in einem Pool-Runspace. Jeder Pool-Runspace
# ist frisch: dort ist weder das Exchange-Snapin noch eine der Skriptfunktionen
# vorhanden. Deshalb darf hier nur das Cmdlet benutzt werden - die Umgebung
# wird vor jedem Abruf geprueft und bei Bedarf nachgeladen.
$script:StatistikAbrufSkript = {
    param($MoveRequest)

    if (-not (Get-Command Get-MoveRequestStatistics -ErrorAction SilentlyContinue)) {
        foreach ($Snapin in @('Microsoft.Exchange.Management.PowerShell.SnapIn',
                              'Microsoft.Exchange.Management.PowerShell')) {
            try {
                Add-PSSnapin -Name $Snapin -ErrorAction Stop
                break
            }
            catch { }
        }
        if (-not (Get-Command Get-MoveRequestStatistics -ErrorAction SilentlyContinue)) {
            throw "Exchange-Snapin konnte nicht geladen werden."
        }
    }

    $MoveRequest | Get-MoveRequestStatistics -ErrorAction Stop
}

function Invoke-StatistikSequenziell {
    <#
    .SYNOPSIS
        Holt Statistiken der Reihe nach im aktuellen Runspace.
    .DESCRIPTION
        Wird genutzt, wenn kein Pool zur Verfügung steht (Tests mit
        Mock-Funktionen, -Parallelitaet 1) und als Fallback, wenn der
        Pool nicht liefert.
    .PARAMETER Auftraege
        PSCustomObject mit Schluessel und MoveRequest.
    .PARAMETER Ergebnisse
        Ergebnis-Hashtable; wird als Referenz befüllt.
    #>
    param(
        [Parameter(Mandatory = $false)][object[]]$Auftraege = @(),
        [Parameter(Mandatory = $true)][hashtable]$Ergebnisse
    )

    foreach ($Auftrag in $Auftraege) {
        if ($Ergebnisse.ContainsKey([string]$Auftrag.Schluessel)) { continue }
        try {
            $Stats = $Auftrag.MoveRequest | Get-MoveRequestStatistics -ErrorAction Stop
            $Ergebnisse[[string]$Auftrag.Schluessel] = @{ Stats = $Stats; Fehler = $null }
        }
        catch {
            $Ergebnisse[[string]$Auftrag.Schluessel] = @{ Stats = $null; Fehler = $_.Exception.Message }
        }
    }
}

function Invoke-StatistikAbrufe {
    <#
    .SYNOPSIS
        Holt die Statistiken für eine Liste von MoveRequests und liefert je
        Job den Statistik-Satz oder die Fehlermeldung.

    .DESCRIPTION
        Die Einzelabrufe laufen - sofern möglich - parallel über einen
        Runspace-Pool. Bei 300 laufenden Jobs war das der Hauptengpass: die
        sequenziellen Abrufe hielten die Request-Queue mehrere Minuten
        blockiert, und jede andere Anfrage (Postfächer, Datenbanken,
        Statusabfragen) musste warten.

        Sicherheitsnetze:
        * Parallel nur, wenn Get-MoveRequestStatistics als echtes Cmdlet
          vorliegt - Mock-Funktionen in Tests sind in einem fremden
          Runspace unsichtbar, dort wird sequenziell gearbeitet.
        * Schlägt der Pool komplett fehl (z.B. fehlendes Snapin im
          Pool-Runspace), wird er dauerhaft abgeschaltet und die Abrufe
          laufen sequenziell nach.
    .PARAMETER Auftraege
        PSCustomObject mit den Eigenschaften Schluessel (string) und
        MoveRequest.
    .OUTPUTS
        Hashtable: Schluessel -> @{ Stats = <Statistik|$null>; Fehler = <text|$null> }
    #>
    param(
        [Parameter(Mandatory = $false)][object[]]$Auftraege = @()
    )

    $Ergebnisse = @{}
    if ($null -eq $Auftraege -or $Auftraege.Count -eq 0) { return $Ergebnisse }

    $script:ExchangeAbfragen += $Auftraege.Count

    # Parallel nur mit echtem Cmdlet und solange kein Fehler vorliegt.
    $NutzePool = $false
    if ($Parallelitaet -gt 1 -and -not $script:StatistikParallelAus) {
        $Befehl = Get-Command Get-MoveRequestStatistics -ErrorAction SilentlyContinue
        $NutzePool = ($null -ne $Befehl -and $Befehl.CommandType -eq 'Cmdlet')
    }

    if (-not $NutzePool) {
        Invoke-StatistikSequenziell -Auftraege $Auftraege -Ergebnisse $Ergebnisse
        return $Ergebnisse
    }

    try {
        if ($null -eq $script:StatistikPool) {
            $script:StatistikPool = [runspacefactory]::CreateRunspacePool(1, $Parallelitaet)
            $script:StatistikPool.Open()
            Write-Log -Nachricht (TM 'log.statsPoolOpen' @{ Count = $Parallelitaet }) -Typ "INFO"
        }

        # Alle Abrufe starten - sie laufen im Pool parallel.
        $Laeufe = New-Object System.Collections.Generic.List[object]
        foreach ($Auftrag in $Auftraege) {
            $ps = [powershell]::Create()
            try {
                $ps.RunspacePool = $script:StatistikPool
                [void]$ps.AddScript($script:StatistikAbrufSkript).AddArgument($Auftrag.MoveRequest)
                $Laeufe.Add([pscustomobject]@{
                    PS      = $ps
                    Auftrag = $Auftrag
                    Handle  = $ps.BeginInvoke()
                })
            }
            catch {
                $ps.Dispose()
                $Ergebnisse[[string]$Auftrag.Schluessel] = @{ Stats = $null; Fehler = $_.Exception.Message }
            }
        }

        # Ergebnisse einsammeln: die Gesamtdauer entspricht dem langsamsten
        # Lauf statt der Summe aller Einzelabrufe.
        # Kein @() vor EndInvoke: der Array-Operator wirft auf Collections
        # in PS 5.1 mitunter einen ArgumentException - Count/Indexer tun es nicht.
        foreach ($Lauf in $Laeufe) {
            try {
                $Werte      = $Lauf.PS.EndInvoke($Lauf.Handle)
                $FehlerText = $null
                if ($Lauf.PS.HadErrors -or $Lauf.PS.Streams.Error.Count -gt 0) {
                    $FehlerText = ($Lauf.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join " | "
                }

                if ($Werte.Count -gt 0 -and [string]::IsNullOrWhiteSpace($FehlerText)) {
                    $Ergebnisse[[string]$Lauf.Auftrag.Schluessel] = @{ Stats = $Werte[0]; Fehler = $null }
                }
                else {
                    if ([string]::IsNullOrWhiteSpace($FehlerText)) { $FehlerText = "leere Antwort" }
                    $Ergebnisse[[string]$Lauf.Auftrag.Schluessel] = @{ Stats = $null; Fehler = $FehlerText }
                }
            }
            catch {
                $Ergebnisse[[string]$Lauf.Auftrag.Schluessel] = @{ Stats = $null; Fehler = $_.Exception.Message }
            }
            finally {
                $Lauf.PS.Dispose()
            }
        }
    }
    catch {
        Write-Log -Nachricht (TM 'log.statsPoolFailed' @{ Error = $_.Exception.Message }) -Typ "WARNUNG"
    }

    # --- Sicherheitsnetz: liefert der Pool gar kein Ergebnis, lag es fast
    # immer am fehlenden Exchange-Snapin. Parallelität dauerhaft abstellen
    # und die Abrufe sequenziell wiederholen - dort ist das Snapin geladen.
    $Erfolge = 0
    foreach ($Schluessel in $Ergebnisse.Keys) {
        if ([string]::IsNullOrWhiteSpace([string]$Ergebnisse[$Schluessel].Fehler)) { $Erfolge++ }
    }

    if ($Erfolge -eq 0) {
        $script:StatistikParallelAus = $true
        if ($null -ne $script:StatistikPool) {
            try { $script:StatistikPool.Close() ; $script:StatistikPool.Dispose() } catch { }
            $script:StatistikPool = $null
        }
        Write-Log -Nachricht (TM 'log.statsParallelEmpty') -Typ "WARNUNG"
        Invoke-StatistikSequenziell -Auftraege $Auftraege -Ergebnisse $Ergebnisse
    }

    return $Ergebnisse
}

function Get-MoveRequestDaten {
    <#
    .SYNOPSIS
        Ruft die aktuellen MoveRequest-Daten ab und gibt sie als Hashtable zurück.

    .DESCRIPTION
        Neu in v2.0:

        * Schnellpfad: Liegt ein Snapshot vor, der jünger als $CacheIntervall
          ist, wird er sofort zurückgegeben – ohne Exchange-Kontakt. Damit
          beantwortet ein Burst von überlappenden Requests alle bis auf den
          ersten praktisch sofort, statt jeden einzeln die komplette Sammlung
          durchlaufen zu lassen. Genau das war die Ursache für die
          Request-Queue, die nach wenigen Minuten alles blockierte.

        * Get-MoveRequestStatistics wird nur noch für Jobs aufgerufen, die
          wirklich neu sind. Jobs in einem Endzustand kommen aus
          $script:StatistikCache, sobald sie einmalig geholt wurden. Das
          reduziert die Exchange-Last und die Nutzlast drastisch und war die
          Hauptursache für die "maxenvelopesizekb"-Fehler.

        * Neu in v2.3 - schlanker Erstablauf: Solange noch kein Snapshot
          existiert, liefert der erste Lauf ausschliesslich Grundzeilen aus
          Get-MoveRequest (Sekunden statt Minuten). Prozent, Größen und
          Zeiten kommen im nächsten Lauf nach; bis dahin zeigt die Tabelle
          "..." in der Fortschrittsspalte (Feld DetailOffen). Das war der
          Grund, warum das Dashboard beim Start so lange leer blieb und
          jede andere Anfrage (Postfächer, Datenbanken) in der
          Request-Queue hinterherhing.

        * Neu in v2.3: Die Statistikabrufe eines Laufs laufen parallel über
          einen Runspace-Pool ($Parallelitaet), begrenzt auf
          $MaxDetailAbrufe Abrufe pro Lauf. Offene Details werden zuerst
          nachgeholt, damit keine Abrufgrenze einen Job dauerhaft übergeht.

        * Schlägt die Sammlung fehl, wird der letzte bekannte Stand
          weiter ausgeliefert (mit Fehlerhinweis) statt leere Daten.
    #>

    $Jetzt = Get-Date

    # --- Schnellpfad: frischen Snapshot sofort ausliefern -------------------
    $EffektivesCacheIntervall = $CacheIntervall
    if ($script:LetzterSnapshot -and $script:LetzteAktiv -eq 0 -and $script:OffeneDetails.Count -eq 0) {
        # Nichts läuft mehr UND alle Detaildaten sind da -> deutlich
        # seltener neu sammeln. Solange Details offen sind, darf der
        # Leerlauf-Modus die Nachhol-Laeufe nicht auf 60 s hinauszögern.
        $EffektivesCacheIntervall = [math]::Max($CacheIntervall, $LeerlaufIntervall)
    }

    if ($script:LetzterSnapshot -and $script:LetzteSammlung) {
        $Alter = ($Jetzt - $script:LetzteSammlung).TotalSeconds
        if ($Alter -lt $EffektivesCacheIntervall) {
            $script:CacheTreffer++
            return (Set-SnapshotAlter -Snapshot $script:LetzterSnapshot)
        }
    }

    $StoppUhr   = [System.Diagnostics.Stopwatch]::StartNew()
    $script:Sammlungen++

    $Ergebnis = @{
        Zeitstempel   = $Jetzt.ToString("dd.MM.yyyy HH:mm:ss")
        Server        = $ExchangeServer
        Gesamt        = 0
        StatusGruppen = @()
        Details       = @()
        Fehler        = $null
        FehlerAnzahl  = 0
        FehlerBeispiel = $null
        DauerSekunden = 0
        AlterSekunden = 0
        DetailOffen   = 0
        Abfragezeit   = (Get-Date -Format "HH:mm:ss")
    }

    # Fehlschläge einsammeln. Nicht mehr 235 Einzelzeilen ins Log schreiben.
    $FehlerListe    = New-Object System.Collections.Generic.List[string]
    $FehlerUrsachen = @{}
    $EnvelopeFehler = $false

    try {
        # Einmalig Altlast aus der ExchangeObjectId-Zeit entfernen: ein Leer-Key
        # ("") enthielt genau eine fremde Zeile und hat alle Completed-Jobs
        # dupliziert. Ohne dieses Remove wuerde der Eintrag bis zum Neustart
        # weiterleben (wird durch die Selbstheilung unten aber auch erkannt).
        if ($script:StatistikCache.ContainsKey("")) { $script:StatistikCache.Remove("") }

        # Alle MoveRequests abrufen
        $AbfrageParameter = @{ ResultSize = 'Unlimited'; ErrorAction = 'Stop' }
        if ($BatchName) { $AbfrageParameter['BatchName'] = $BatchName }

        $AlleMoveRequests = @(Get-MoveRequest @AbfrageParameter)
        $AnzahlGesamt     = $AlleMoveRequests.Count
        $Ergebnis.Gesamt  = $AnzahlGesamt

        $DetailDaten   = New-Object System.Collections.Generic.List[object]
        $NeuGeholt     = 0
        $AusCache      = 0
        $Abfragen      = 0
        $Offen         = 0

        # --- Phase 1: vorbereiten ----------------------------------------
        # Erster Lauf ohne Snapshot: keine Statistikabrufe, nur Grundzeilen
        # aus Get-MoveRequest. Ein einzelner Aufruf dauert Sekunden - die
        # Detaildaten kommen im naechsten Lauf nach. Genau diese Abfrage
        # war bisher der Engpass: hunderte sequenzielle Statistikabrufe
        # blockierten die Request-Queue Minuten lang.
        $ErsterLauf = ($null -eq $script:LetzterSnapshot)

        # Menge der zuletzt offenen Details merken - sie bestimmt die
        # Reihenfolge der Abrufe.
        $OffeneFrueher = $script:OffeneDetails

        $CacheTreffer = @{}
        $ZumAbrufen   = New-Object System.Collections.Generic.List[object]

        foreach ($MoveRequest in $AlleMoveRequests) {
            $Schluessel = Get-MoveRequestSchluessel -MoveRequest $MoveRequest
            $Status     = [string]$MoveRequest.Status

            # --- Endzustand aus dem Cache --------------------------------
            if ($StatusEnd -contains $Status -and $script:StatistikCache.ContainsKey($Schluessel)) {
                $Gecacht = $script:StatistikCache[$Schluessel]
                # Selbstheilung: Falls ein alter, kollidierter Eintrag (z.B. Leer-Key
                # aus der ExchangeObjectId-Zeit) einen fremden Namen liefert, nicht
                # übernehmen, sondern neu abfragen.
                $AktuellerName = Get-Text $MoveRequest.DisplayName
                if ($Gecacht -and $Gecacht.DisplayName -eq $AktuellerName) {
                    $CacheTreffer[$Schluessel] = $Gecacht
                    continue
                }
                else {
                    Write-Log -Nachricht (TM 'log.cacheCollision' @{
                        Key     = $Schluessel
                        Cached  = $Gecacht.DisplayName
                        Current = $AktuellerName
                    }) -Typ "WARNUNG"
                    $script:StatistikCache.Remove($Schluessel)
                }
            }

            # Grunddaten-Lauf: gar keine Statistikabrufe. Ebenso der
            # Light-Modus (-Light): dort werden GRUNDSAETZLICH keine
            # technischen Werte abgefragt - das ist der ganze Zweck des
            # Schalters und der Grund, warum er schneller laeuft.
            if ($ErsterLauf -or $Light) { continue }

            # Alle Kandidaten sammeln - die Abrufgrenze greift erst nach der
            # Sortierung, damit offene Details zuerst drankommen.
            $ZumAbrufen.Add([pscustomobject]@{
                Schluessel  = $Schluessel
                MoveRequest = $MoveRequest
            })
        }

        # --- Phase 2: Statistikabrufe (parallel ueber den Pool) ----------
        if ($MaxDetailAbrufe -gt 0 -and $ZumAbrufen.Count -gt $MaxDetailAbrufe) {
            # Zuerst Jobs, deren Details noch offen sind. Ohne diese Prioritaet
            # waeren es immer dieselben (zuerst sortierten) Jobs, und der Rest
            # kaeme nie an die Reihe. Danach die Abrufgrenze anwenden.
            $ZumAbrufen = @($ZumAbrufen | Sort-Object `
                @{ Expression = { -not $OffeneFrueher.ContainsKey([string]$_.Schluessel) } }, `
                @{ Expression = { Get-StatusPrioritaet -Status ([string]$_.MoveRequest.Status) } }, `
                @{ Expression = { Get-Text $_.MoveRequest.DisplayName } }) |
                Select-Object -First $MaxDetailAbrufe
        }

        # WICHTIG: kein @() vor der Uebergabe - der Array-Operator wirft auf
        # einer Generic-List in PS 5.1 einen ArgumentException. Der
        # [object[]]-Parameter konvertiert die Liste selbst.
        $AbrufErgebnisse = Invoke-StatistikAbrufe -Auftraege $ZumAbrufen
        $Abfragen        = $ZumAbrufen.Count

        # --- Phase 3: Zeilen bauen ---------------------------------------
        $NeueOffene = @{}

        foreach ($MoveRequest in $AlleMoveRequests) {
            $Schluessel = Get-MoveRequestSchluessel -MoveRequest $MoveRequest
            $Status     = [string]$MoveRequest.Status

            if ($CacheTreffer.ContainsKey($Schluessel)) {
                $DetailDaten.Add($CacheTreffer[$Schluessel])
                $AusCache++
                continue
            }

            if (-not $AbrufErgebnisse.ContainsKey($Schluessel)) {
                # Detaildaten noch offen - Grundzeile, wird nachgeladen.
                # Im Light-Modus ist die Zeile dagegen sofort endgueltig:
                # Details werden nie angefordert, also duerfen sie auch
                # nicht als "offen" zaehlen (sonst laeuft das Dashboard
                # ewig im Nachhol-Modus).
                $DetailDaten.Add((New-Grundzeile -MoveRequest $MoveRequest -Light:([bool]$Light)))
                if (-not $Light) {
                    $NeueOffene[$Schluessel] = $true
                    $Offen++
                }
                continue
            }

            $Eintrag = $AbrufErgebnisse[$Schluessel]
            $Stats   = $Eintrag.Stats

            if (-not [string]::IsNullOrWhiteSpace([string]$Eintrag.Fehler) -or $null -eq $Stats) {
                # Wichtig: die Ursache nennt der Fehlermeldung-Text. Im alten
                # Skript stand hier "Fehler bei '': ...", weil $_.DisplayName
                # im catch-Block nicht der MoveRequest, sondern der ErrorRecord ist.
                $Ursache = if ([string]::IsNullOrWhiteSpace([string]$Eintrag.Fehler)) { "leere Antwort" } else { [string]$Eintrag.Fehler }
                $FehlerListe.Add("$($MoveRequest.DisplayName): $Ursache")

                if (-not $FehlerUrsachen.ContainsKey($Ursache)) { $FehlerUrsachen[$Ursache] = 0 }
                $FehlerUrsachen[$Ursache]++

                if ($Ursache -match "envelope|Envelope|MaxEnvelope|WSMan") { $EnvelopeFehler = $true }

                # Erste drei Fehler ausgeben, danach nur noch zusammenfassen
                if ($FehlerListe.Count -le 3) {
                    Write-Log -Nachricht (TM 'log.statsFetchFailed' @{
                        Name  = $MoveRequest.DisplayName
                        Error = $Ursache
                    }) -Typ "WARNUNG"
                }

                # Die Zeile trotzdem ausgeben. Sonst verschwindet der Job
                # komplett aus der Tabelle und man sieht nicht, wen es trifft.
                $DetailDaten.Add((New-FehlgeschlageneZeile -MoveRequest $MoveRequest -Ursache $Ursache))
                continue
            }

            # Prozentwert sicher als Integer
            $ProzentWert = 0
            if ($null -ne $Stats.PercentComplete) {
                $ProzentWert = [math]::Min(100, [math]::Max(0, [int]$Stats.PercentComplete))
            }

            # Fortschrittsbalken-Farbe berechnen
            $BalkenFarbe = switch ($true) {
                ($ProzentWert -eq 100) { '#28a745'; break }
                ($ProzentWert -ge 75)  { '#17a2b8'; break }
                ($ProzentWert -ge 50)  { '#ffc107'; break }
                ($ProzentWert -ge 25)  { '#fd7e14'; break }
                default                { '#dc3545' }
            }

            $StatusString = Get-DetailText $Stats.Status
            $IstAktiv     = ($StatusAktiv -contains $StatusString)

            $Zeile = @{
                DisplayName          = Get-Text $Stats.DisplayName
                Alias                = Get-Text $Stats.Alias
                # Identity aus dem MoveRequest (nicht aus der Statistik) -
                # sie ist der sichere Angriffspunkt fuer Resume-MoveRequest.
                Identity             = Get-Text $MoveRequest.Identity
                Status               = $StatusString
                StatusDetail         = Get-DetailText $Stats.StatusDetail
                StatusFarbe          = (Get-StatusFarbe -Status $StatusString)
                # NEU: Prioritätswert für die Sortierung mitgeben
                StatusPrioritaet     = (Get-StatusPrioritaet -Status $StatusString)
                Aktiv                = $IstAktiv
                ProzentAbgeschlossen = $ProzentWert
                BalkenFarbe          = $BalkenFarbe
                BytesUebertragen     = Format-GroesseKurz $Stats.BytesTransferred
                GesamtGroesse        = Format-GroesseKurz $Stats.TotalMailboxSize
                ItemsUebertragen     = [int]$Stats.ItemsTransferred
                BadItemsGefunden     = [int]$Stats.BadItemsEncountered
                LargeItemsGefunden   = [int]$Stats.LargeItemsEncountered
                QuellDatenbank       = Get-Text $Stats.SourceDatabase
                ZielDatenbank        = Get-Text $Stats.TargetDatabase
                BatchName            = Get-Text $MoveRequest.BatchName
                StartZeit            = if ($Stats.StartTimestamp) { $Stats.StartTimestamp.ToString("dd.MM.yyyy HH:mm") } else { "N/A" }
                AbschlussZeit        = if ($Stats.CompletionTimestamp) { $Stats.CompletionTimestamp.ToString("dd.MM.yyyy HH:mm") } else { "N/A" }
                Nachricht            = Get-Text $Stats.Message
                StatistikFehler      = $false
            }

            $DetailDaten.Add($Zeile)

            # Endzustände dauerhaft cachen – für sie ändert sich nie etwas
            if (-not $IstAktiv -and $StatusEnd -contains $StatusString) {
                $script:StatistikCache[$Schluessel] = $Zeile
            }

            $NeuGeholt++

            # Referenz auf den letzten Statistik-Satz sofort freigeben
            $Stats = $null
        }

        # Offene Details auf die tatsaechlichen Jobs begrenzen - entfernte
        # Jobs duerfen nicht ewig in der Menge stehen bleiben.
        $script:OffeneDetails = $NeueOffene
        $Ergebnis.DetailOffen = $Offen

        # --- Sortierung: aktive Jobs zuerst, dann Name ----------------------
        $Sortiert = @($DetailDaten | Sort-Object `
            @{ Expression = { $_.StatusPrioritaet } }, `
            @{ Expression = { $_.DisplayName } })

        $Ergebnis.Details = $Sortiert
        $script:LetzteAktiv = @($Sortiert | Where-Object { $_.Aktiv }).Count

        # --- Status-Gruppierung (ebenfalls nach Priorität sortiert) ---------
        $Gruppiert = $Sortiert |
            Group-Object { $_.Status } |
            Sort-Object { (Get-StatusPrioritaet -Status $_.Name) }

        $Ergebnis.StatusGruppen = @($Gruppiert | ForEach-Object {
            $Prozent = if ($AnzahlGesamt -gt 0) { [math]::Round(($_.Count / $AnzahlGesamt) * 100, 1) } else { 0 }
            @{
                Name    = $_.Name
                Anzahl  = $_.Count
                Prozent = $Prozent
                Farbe   = (Get-StatusFarbe -Status $_.Name)
            }
        })

        # --- Zusammenfassung ins Log ----------------------------------------
        $StoppUhr.Stop()
        $Ergebnis.DauerSekunden = [math]::Round($StoppUhr.Elapsed.TotalSeconds, 1)
        $script:LetzteDauer      = $Ergebnis.DauerSekunden

        $Meldung = "Sammlung #$($script:Sammlungen): $AnzahlGesamt MoveRequest(s) in $($Ergebnis.DauerSekunden)s - $Abfragen Statistikabruf(e), $AusCache aus Cache, $script:LetzteAktiv aktiv, $Offen Detaildaten offen, $($FehlerListe.Count) Fehler"
        Write-Log -Nachricht $Meldung -Typ "STILL"

        if ($script:LetzteAktiv -eq 0 -and $AnzahlGesamt -gt 0) {
            Write-Log -Nachricht (TM 'log.allFinished' @{
                Count   = $AnzahlGesamt
                Seconds = $LeerlaufIntervall
            }) -Typ "STILL"
        }
    }
    catch {
        $FehlerNachricht = $_.Exception.Message
        $Ergebnis.Fehler  = (TM 'msg.moveQueryFailed' @{ Error = $FehlerNachricht })
        Write-Log -Nachricht (TM 'log.apiError' @{ Error = $Ergebnis.Fehler }) -Typ "FEHLER"
    }
    finally {
        $StoppUhr.Stop()
        if ($Ergebnis.DauerSekunden -eq 0) {
            $Ergebnis.DauerSekunden = [math]::Round($StoppUhr.Elapsed.TotalSeconds, 1)
        }

        $Ergebnis.FehlerAnzahl   = $FehlerListe.Count
        $Ergebnis.FehlerBeispiel  = if ($FehlerListe.Count -gt 0) { $FehlerListe[0] } else { $null }
        if ($FehlerListe.Count -gt 3) {
            $Ergebnis.Fehler = "$($FehlerListe.Count) MoveRequest(s) lieferten keine Statistik. Beispiel: $($FehlerListe[3])"
        }
        elseif ($FehlerListe.Count -gt 0) {
            $Ergebnis.Fehler = "$($FehlerListe.Count) MoveRequest(s) lieferten keine Statistik. Beispiel: $($FehlerListe[0])"
        }

        if ($FehlerListe.Count -gt 3) {
            Write-Log -Nachricht (TM 'log.apiMissingStats' @{ Count = $FehlerListe.Count }) -Typ "WARNUNG"
        }
        foreach ($Ursache in $FehlerUrsachen.Keys) {
            Write-Log -Nachricht (TM 'log.apiCause' @{
                Count = $FehlerUrsachen[$Ursache]
                Cause = $Ursache
            }) -Typ "WARNUNG"
        }
        if ($EnvelopeFehler) {
            Write-Log -Nachricht (TM 'log.envelopeHint') -Typ "WARNUNG"
            Write-Log -Nachricht (TM 'log.envelopeCmd') -Typ "WARNUNG"
        }

        # Groesster Posten: die deserialisierten Objekte explizit freigeben.
        # In einem langlebigen Runspace sammeln sich sonst 235 Statistik-Sätze
        # pro Poll auf dem Large Object Heap an - das war das "laeuft voll".
        $AlleMoveRequests = $null
        $MoveRequest      = $null
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()

        # Nur bei erfolgreicher Sammlung cachen, damit ein Fehler nicht den
        # letzten guten Stand zerstoert.
        if ($Ergebnis.Details.Count -gt 0 -or $Ergebnis.Gesamt -eq 0) {
            $script:LetzterSnapshot = $Ergebnis

            # WICHTIG: Der Zeitstempel wird hier am ENDE der Sammlung gesetzt,
            # nicht am Anfang. Andernfalls ist ein Snapshot, der 19 s lang
            # gesammelt wurde, bereits abgelaufen, sobald er fertig ist -
            # der Schnellpfad wuerde nie greifen und jeder Request wuerde
            # wieder die volle Sammlung ausloesen.
            $script:LetzteSammlung = Get-Date
        }
    }

    return (Set-SnapshotAlter -Snapshot $script:LetzterSnapshot)
}

function Get-SkriptVersion {
    <#
    .SYNOPSIS
        Liefert die Versionsnummer aus dem .NOTES-Block dieses Skripts.

        Dort steht die Nummer in der Form "Version:   2.11 (...)" - der
        Regex-Schnitt liefert daraus "2.11". Header, Seitentitel und
        Fusszeile des Dashboards werden so aus EINER Quelle bespielt: eine
        aktualisierte Version kann nie vergessen werden und Skript und
        Oberflaeche koennen nicht auseinanderlaufen.

        Das Ergebnis wird gepuffert, die Datei wird also nur einmal gelesen.
    .PARAMETER Pfad
        Zu lesende Datei - Standard ist dieses Skript selbst. Der Parameter
        existiert nur fuer Tests; produktiv wird nie uebergeben.
    .OUTPUTS
        String - z.B. "2.11"; "unbekannt", wenn die Datei nicht lesbar ist
        (z.B. beim Start ueber eine Pipe).
    #>
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Pfad = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($script:SkriptVersionCache)) {
        return $script:SkriptVersionCache
    }

    $Version = "unbekannt"

    try {
        if ([string]::IsNullOrWhiteSpace($Pfad)) { $Pfad = [string]$PSCommandPath }
        if ([string]::IsNullOrWhiteSpace($Pfad)) { $Pfad = [string]$MyInvocation.PSCommandPath }

        if (-not [string]::IsNullOrWhiteSpace($Pfad) -and (Test-Path -LiteralPath $Pfad)) {
            # UTF-8 mit BOM: ReadAllText erkennt die Kennzeichnung selbst.
            $Text = [System.IO.File]::ReadAllText($Pfad)
            $Treffer = [regex]::Match($Text, '(?m)^[ \t]*Version:[ \t]+(?<Version>[0-9]+(?:\.[0-9]+)+)')
            if ($Treffer.Success) { $Version = $Treffer.Groups['Version'].Value }
        }
    }
    catch { }

    $script:SkriptVersionCache = $Version
    return $Version
}

function Get-DashboardHTML {
    <#
    .SYNOPSIS
        Generiert das vollständige HTML-Dashboard mit eingebettetem JavaScript
        für automatische Live-Updates via AJAX (Fetch-API).
        Die Sortierung priorisiert aktive Jobs oben in der Tabelle.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet("de", "en")]
        [string]$SprachCode = ""
    )

    if ([string]::IsNullOrWhiteSpace($SprachCode)) { $SprachCode = $script:Sprache }
    if (-not $script:Texte.ContainsKey($SprachCode)) { $SprachCode = 'de' }

    # Light-Modus (-Light): die technischen Spalten werden per CSS
    # ausgeblendet, weil sie gar nicht gefuellt sind - es wird keine
    # Statistik abgerufen, darum gibt es keine Prozentwerte, Groessen
    # oder Zeiten zu zeigen.
    $LightCSS = ""
    if ($Light) { $LightCSS = "        .spalte-technisch { display: none; }" }

    # Kennzeichnung in der Fusszeile, damit man den Modus im Browser sieht.
    $LightFussnote = ""
    if ($Light) { $LightFussnote = " " + (T -Key 'ui.lightMode' -SprachCode $SprachCode) }

    # Versionsnummer aus dem .NOTES-Block - Kopfzeile, Seitentitel und
    # Fusszeile zeigen damit immer genau die Version, die hier laeuft.
    $SkriptVersion = Get-SkriptVersion

    # Nur die js.*-Schluessel in die Seite einbetten: das Frontend braucht
    # sie fuer dynamisch erzeugte Texte, der Rest wird serverseitig ersetzt.
    $JsTabelle = @{}
    foreach ($Schluessel in $script:Texte[$SprachCode].Keys) {
        if ($Schluessel.StartsWith('js.')) {
            $JsTabelle[$Schluessel.Substring(3)] = $script:Texte[$SprachCode][$Schluessel]
        }
    }
    $JsJson = $JsTabelle | ConvertTo-Json -Compress

    $SprachTitel = T -Key 'ui.title' -SprachCode $SprachCode
    $SprachUntertitel = T -Key 'ui.subtitle' -SprachCode $SprachCode -Werte @{
        Server  = $ExchangeServer
        Seconds = $AktualisierungsIntervall
    }
    $SprachFusszeile = T -Key 'ui.footer' -SprachCode $SprachCode -Werte @{
        Version = $SkriptVersion
        Seconds = $AktualisierungsIntervall
    }

    $HTML = @"
<!DOCTYPE html>
<html lang="$SprachCode">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{ui.title}} v$SkriptVersion</title>
    <style>
        /* ============ Grundlegendes Layout ============ */
        * { margin: 0; padding: 0; box-sizing: border-box; }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: #f0f2f5;
            color: #333;
            padding: 20px;
        }

        /* ============ Header ============ */
        .header {
            background: linear-gradient(135deg, #0078d4, #005a9e);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 25px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
        }
        .header h1 { font-size: 28px; margin-bottom: 8px; }
        .header p { font-size: 14px; opacity: 0.9; }
        /* Versionsnummer neben der Ueberschrift - kommt aus dem
           .NOTES-Block des Skripts (Get-SkriptVersion) */
        .version-marke {
            display: inline-block;
            background: rgba(255, 255, 255, 0.18);
            border: 1px solid rgba(255, 255, 255, 0.45);
            border-radius: 12px;
            padding: 3px 12px;
            margin-left: 10px;
            font-size: 15px;
            font-weight: 600;
            vertical-align: middle;
            white-space: nowrap;
        }
        /* Update-Badge (v2.15): Orange wie die Statusfarbe "Suspended",
           erscheint nur wenn der Update-Check eine neuere GitLab-Version
           meldet. Klick oeffnet die Release-Seite (target=_blank). */
        .update-badge {
            display: inline-block;
            background: #ffc107;
            color: #212529;
            border: 1px solid rgba(255, 255, 255, 0.45);
            border-radius: 12px;
            padding: 3px 12px;
            margin-left: 10px;
            font-size: 14px;
            font-weight: 600;
            text-decoration: none;
            vertical-align: middle;
            white-space: nowrap;
        }
        .update-badge:hover { background: #ffca2c; }
        #alterAnzeige { font-size: 12px; opacity: 0.8; margin-top: 4px; }
        #alterAnzeige.veraltet { color: #ffd166; font-weight: 600; }

        /* Sprachumschalter (v2.16): DE/EN direkt im Kopf, Auswahl wird
           als Cookie gespeichert und die Seite mit ?lang= neu geladen. */
        .sprach-schalter {
            display: inline-flex;
            align-items: center;
            gap: 0;
            margin-top: 8px;
            border: 1px solid rgba(255,255,255,0.5);
            border-radius: 14px;
            overflow: hidden;
        }
        .sprach-schalter a {
            color: white;
            text-decoration: none;
            padding: 3px 10px;
            font-size: 12px;
            font-weight: 600;
            line-height: 18px;
        }
        .sprach-schalter a:hover { background: rgba(255,255,255,0.18); }
        .sprach-schalter a.aktiv { background: rgba(255,255,255,0.32); }

        /* ============ Live-Indikator ============ */
        .live-indikator {
            display: flex;
            align-items: center;
            gap: 10px;
            background: rgba(255,255,255,0.15);
            padding: 10px 20px;
            border-radius: 25px;
            font-size: 14px;
        }
        .live-punkt {
            width: 12px;
            height: 12px;
            background-color: #28a745;
            border-radius: 50%;
            animation: pulsieren 1.5s infinite;
        }
        @keyframes pulsieren {
            0%   { opacity: 1; box-shadow: 0 0 0 0 rgba(40,167,69,0.7); }
            70%  { opacity: 0.7; box-shadow: 0 0 0 10px rgba(40,167,69,0); }
            100% { opacity: 1; box-shadow: 0 0 0 0 rgba(40,167,69,0); }
        }

        /* ============ Countdown-Anzeige ============ */
        .countdown-bar {
            width: 100%;
            height: 4px;
            background-color: #e0e0e0;
            border-radius: 2px;
            margin-bottom: 25px;
            overflow: hidden;
        }
        .countdown-fortschritt {
            height: 100%;
            background: linear-gradient(90deg, #0078d4, #00bcf2);
            border-radius: 2px;
            transition: width 1s linear;
        }

        /* ============ Status-Kacheln (Übersicht) ============ */
        .kacheln-container {
            display: flex;
            flex-wrap: wrap;
            gap: 15px;
            margin-bottom: 25px;
        }
        .status-kachel {
            background: white;
            border-radius: 8px;
            padding: 20px;
            min-width: 180px;
            flex: 1;
            box-shadow: 0 2px 4px rgba(0,0,0,0.08);
            transition: transform 0.3s, box-shadow 0.3s;
        }
        .status-kachel:hover {
            transform: translateY(-3px);
            box-shadow: 0 4px 12px rgba(0,0,0,0.15);
        }
        .kachel-zahl { font-size: 36px; font-weight: 700; }
        .kachel-status { font-size: 14px; font-weight: 600; color: #555; margin-top: 4px; }
        .kachel-prozent { font-size: 12px; color: #888; margin-top: 2px; }

        /* ============ Gesamtzahl-Box ============ */
        .gesamt-box {
            background: white;
            border-radius: 8px;
            padding: 15px 25px;
            margin-bottom: 25px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.08);
            font-size: 18px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .gesamt-box strong { color: #0078d4; font-size: 24px; }

        /* ============ Sortierinfo-Hinweis ============ */
        .sortier-hinweis {
            padding: 8px 25px;
            color: #0078d4;
            font-size: 12px;
            font-style: italic;
            background: #e8f4fd;
            border-left: 3px solid #0078d4;
            margin: 0 0 0 0;
        }

        /* ============ Detailtabelle ============ */
        .tabellen-container {
            background: white;
            border-radius: 10px;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            margin-bottom: 25px;
        }
        .tabellen-container h2 {
            padding: 20px 25px 10px 25px;
            color: #333;
            font-size: 20px;
        }
        .tabellen-scroll {
            overflow-x: auto;
        }
        table { width: 100%; border-collapse: collapse; }
        th {
            background-color: #0078d4;
            color: white;
            padding: 12px 10px;
            text-align: left;
            font-size: 13px;
            font-weight: 600;
            position: sticky;
            top: 0;
            z-index: 1;
        }
        td {
            padding: 10px;
            border-bottom: 1px solid #eee;
            font-size: 13px;
            vertical-align: middle;
        }
        tr:hover { background-color: #f8f9fa; }
        tr:nth-child(even) { background-color: #fafbfc; }

        /* ============ NEU: Aktive Zeilen visuell hervorheben ============ */
        tr.aktiv-zeile {
            background-color: #e8f4fd !important;
            border-left: 3px solid #0078d4;
        }
        tr.aktiv-zeile:hover {
            background-color: #d0e8f7 !important;
        }

        /* ============ Status-Badge ============ */
        .status-badge {
            display: inline-block;
            padding: 4px 10px;
            border-radius: 12px;
            color: white;
            font-size: 12px;
            font-weight: 600;
            white-space: nowrap;
        }

        /* ============ Fortschrittsbalken ============ */
        .fortschritt-container {
            background-color: #e9ecef;
            border-radius: 10px;
            overflow: hidden;
            height: 22px;
            width: 150px;
            min-width: 150px;
            max-width: 150px;
        }
        .fortschritt-balken {
            height: 100%;
            border-radius: 10px;
            text-align: center;
            line-height: 22px;
            color: white;
            font-size: 11px;
            font-weight: 600;
            max-width: 100%;
            overflow: hidden;
            white-space: nowrap;
            transition: width 0.8s ease;
        }

        /* ============ Fehler-Anzeige ============ */
        .fehler-box {
            background-color: #f8d7da;
            border: 1px solid #f5c6cb;
            color: #721c24;
            padding: 15px 25px;
            border-radius: 8px;
            margin-bottom: 25px;
            display: none;
            white-space: pre-wrap;
        }

        /* ============ Lade-Animation ============ */
        .lade-overlay {
            position: fixed;
            top: 0; left: 0;
            width: 100%; height: 100%;
            background: rgba(255,255,255,0.7);
            display: none;
            justify-content: center;
            align-items: center;
            z-index: 9999;
        }
        .spinner {
            width: 50px; height: 50px;
            border: 5px solid #e0e0e0;
            border-top: 5px solid #0078d4;
            border-radius: 50%;
            animation: drehen 0.8s linear infinite;
        }
        @keyframes drehen { to { transform: rotate(360deg); } }
        .lade-kasten { text-align: center; }
        .lade-text {
            margin-top: 16px;
            font-size: 15px;
            color: #333;
        }
        .lade-zahl {
            margin-top: 8px;
            font-size: 24px;
            font-weight: 700;
            color: #0078d4;
            min-height: 30px;
        }

        /* ============ Suchfeld ============ */
        .suchfeld-container {
            padding: 15px 25px 5px 25px;
        }
        .suchfeld {
            width: 100%;
            padding: 10px 15px;
            border: 2px solid #e0e0e0;
            border-radius: 8px;
            font-size: 14px;
            outline: none;
            transition: border-color 0.3s;
        }
        .suchfeld:focus { border-color: #0078d4; }

        /* ============ Mehrfachauswahl suspendierter Anforderungen (v2.7) ============ */
        .auswahl-leiste {
            display: none;
            align-items: center;
            flex-wrap: wrap;
            gap: 12px;
            padding: 0 25px 6px 25px;
            font-size: 13px;
            color: #555;
        }
        .auswahl-leiste label {
            display: inline-flex;
            align-items: center;
            gap: 5px;
            cursor: pointer;
            user-select: none;
        }
        .auswahl-leiste input[type="checkbox"] {
            width: 15px;
            height: 15px;
            cursor: pointer;
            accent-color: #0078d4;
        }
        /* Kaestchen in der Statuszelle der Tabelle */
        .zeilen-auswahl {
            display: inline-flex;
            align-items: center;
            margin-right: 5px;
            vertical-align: middle;
            cursor: pointer;
        }
        .zeilen-auswahl input {
            width: 15px;
            height: 15px;
            cursor: pointer;
            accent-color: #0078d4;
        }

        /* ============ Verschiebeanforderung (v2.2) ============ */
        .versand-container {
            background: white;
            border-radius: 10px;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
            margin-bottom: 25px;
        }
        .versand-container h2 {
            padding: 20px 25px 5px 25px;
            color: #333;
            font-size: 20px;
        }
        .versand-body { padding: 10px 25px 25px 25px; }
        .versand-zeile {
            display: flex;
            flex-wrap: wrap;
            gap: 15px;
            align-items: flex-end;
        }
        .versand-feld { margin-bottom: 12px; }
        .versand-feld > label {
            display: block;
            font-size: 12px;
            font-weight: 600;
            color: #555;
            margin-bottom: 5px;
        }
        .versand-feld select,
        .versand-suche {
            padding: 9px 12px;
            border: 2px solid #e0e0e0;
            border-radius: 6px;
            font-size: 14px;
            min-width: 280px;
            outline: none;
            background: white;
        }
        .versand-feld select:focus,
        .versand-suche:focus { border-color: #0078d4; }
        .modus-optionen { font-size: 14px; }
        .modus-optionen label {
            display: inline;
            font-size: 14px;
            font-weight: 400;
            color: #333;
            margin: 0 20px 0 0;
            cursor: pointer;
        }
        .modus-hinweis {
            margin-top: 8px;
            font-size: 12px;
            color: #555;
            background: #f4f6f8;
            border-left: 3px solid #0078d4;
            padding: 6px 10px;
            border-radius: 0 4px 4px 0;
        }
        .versand-werkzeuge {
            display: flex;
            gap: 10px;
            align-items: center;
            flex-wrap: wrap;
            margin-bottom: 8px;
        }
        .mini-schalter {
            background: #e9ecef;
            border: 1px solid #ced4da;
            border-radius: 4px;
            padding: 5px 10px;
            font-size: 12px;
            cursor: pointer;
        }
        .mini-schalter:hover { background: #dee2e6; }
        .versand-hinweis-text { font-size: 12px; color: #888; }
        .benutzer-liste {
            border: 1px solid #e0e0e0;
            border-radius: 8px;
            background: #fafbfc;
            max-height: 250px;
            overflow-y: auto;
            padding: 6px;
        }
        .benutzer-eintrag {
            display: flex;
            align-items: center;
            gap: 9px;
            padding: 6px 9px;
            border-radius: 4px;
            font-size: 13px;
            cursor: pointer;
        }
        .benutzer-eintrag:hover { background: #e8f4fd; }
        .benutzer-eintrag.gesperrt { opacity: 0.6; cursor: not-allowed; }
        .benutzer-eintrag.gesperrt:hover { background: transparent; }
        .db-tag {
            margin-left: auto;
            background: #e8f4fd;
            color: #0078d4;
            border: 1px solid #b8daf5;
            border-radius: 10px;
            padding: 2px 9px;
            font-size: 11px;
            font-weight: 600;
            white-space: nowrap;
        }
        /* Postfachart (Arbitration, AuditLog, PublicFolder, Archiv, ...)
           als eigener Marker - der DB-Name bleibt rechts stehen. */
        .typ-tag {
            background: #fff4e5;
            color: #a35b00;
            border: 1px solid #f0d0a0;
            border-radius: 10px;
            padding: 2px 9px;
            font-size: 11px;
            font-weight: 600;
            white-space: nowrap;
        }
        .versand-schalter {
            background: #0078d4;
            color: white;
            border: none;
            border-radius: 6px;
            padding: 12px 24px;
            font-size: 15px;
            font-weight: 600;
            cursor: pointer;
        }
        .versand-schalter:hover { background: #005a9e; }
        .versand-schalter:disabled { background: #9dc3e6; cursor: not-allowed; }
        /* Aktionen auf bestehende MoveRequests: dezentler, bei "loeschen" warm */
        .versand-schalter.aktion-schalter {
            background: #5a6268;
            padding: 9px 16px;
            font-size: 13px;
        }
        .versand-schalter.aktion-schalter:hover { background: #444; }
        .versand-schalter.aktion-schalter.aktion-warn { background: #b8581a; }
        .versand-schalter.aktion-schalter.aktion-warn:hover { background: #944a16; }
        .versand-schalter.aktion-schalter:disabled { background: #b9bfc4; }
        /* Knopfzeile unter einer laufenden Verschiebeanforderung */
        .auftrag-knoepfe {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
            margin-top: 5px;
        }
        .auftrag-knopf { font-size: 11px; padding: 4px 9px; }
        .versand-ergebnis {
            display: none;
            margin-top: 15px;
            padding: 12px 16px;
            border-radius: 6px;
            font-size: 13px;
            line-height: 1.7;
        }

        /* ============ Footer ============ */
        .footer {
            text-align: center;
            color: #888;
            font-size: 12px;
            padding: 15px;
        }

        /* ============ Fade-In Animation für Daten-Updates ============ */
        .fade-update {
            animation: fadeIn 0.5s ease;
        }
        @keyframes fadeIn {
            from { opacity: 0.5; }
            to   { opacity: 1; }
        }

        /* ============ Trennlinie zwischen aktiven und fertigen Jobs ============ */
        tr.trenn-zeile td {
            background-color: #dee2e6;
            padding: 5px 10px;
            font-size: 11px;
            font-weight: 700;
            color: #495057;
            text-transform: uppercase;
            letter-spacing: 1px;
        }

        /* ============ Light-Modus (-Light) ============ */
        /* Technische Spalten ausblenden - sie werden im Light-Modus nicht
           geliefert und trugen sonst nur Bindestriche. */
$LightCSS
    </style>
</head>
<body>

    <!-- Lade-Overlay -->
    <div class="lade-overlay" id="ladeOverlay">
        <div class="lade-kasten">
            <div class="spinner"></div>
            <div class="lade-text" id="ladeText">{{ui.loadingStart}}</div>
            <div class="lade-zahl" id="ladeZahl"></div>
        </div>
    </div>

    <!-- Header -->
    <div class="header">
        <div>
            <h1>&#128230; {{ui.title}} <span class="version-marke" title="{{ui.versionTitle}}">v$SkriptVersion</span><a id="updateBadge" class="update-badge" href="#" target="_blank" rel="noopener" style="display:none;" title="{{ui.updateBadgeTitle}}">{{ui.updateBadge}}</a></h1>
            <p>$SprachUntertitel</p>
            <p id="zeitstempelAnzeige">{{ui.lastUpdateLoading}}</p>
            <p id="alterAnzeige"></p>
            <!-- Sprachumschalter (v2.16): setzt das Cookie DashboardSprache
                 und laedt die Seite mit ?lang= neu. Die Auswahl gilt damit
                 auch fuer alle serverseitig erzeugten Meldungen. -->
            <div class="sprach-schalter" title="{{ui.language}}">
                <a href="/?lang=de" class="$(if ($SprachCode -eq 'de') { 'aktiv' })" onclick="return spracheUmschalten('de')">DE</a>
                <a href="/?lang=en" class="$(if ($SprachCode -eq 'en') { 'aktiv' })" onclick="return spracheUmschalten('en')">EN</a>
            </div>
        </div>
        <div class="live-indikator">
            <div class="live-punkt" id="livePunkt"></div>
            <span id="liveStatusText">{{ui.live}}</span>
        </div>
    </div>

    <!-- Countdown -->
    <div class="countdown-bar">
        <div class="countdown-fortschritt" id="countdownBar" style="width: 100%;"></div>
    </div>

    <!-- Fehler-Anzeige -->
    <div class="fehler-box" id="fehlerBox"></div>

    <!-- Gesamtanzahl -->
    <div class="gesamt-box">
        <span>{{ui.totalMoveRequests}} <strong id="gesamtAnzahl">0</strong></span>
        <span style="font-size: 12px; color: #888;" id="updateZaehler">{{ui.updates}} 0</span>
    </div>

    <!-- Status-Kacheln -->
    <div class="kacheln-container" id="kachelnContainer"></div>

    <!-- Verschiebeanforderung starten -->
    <div class="versand-container">
        <h2>&#128666; {{ui.newMoveRequest}}</h2>
        <div class="versand-body">

            <div class="versand-zeile">
                <div class="versand-feld">
                    <label for="quellDatenbank">{{ui.sourceDb}}</label>
                    <select id="quellDatenbank" onchange="benutzerLaden()">
                        <option value="">{{ui.allDatabases}}</option>
                    </select>
                </div>
                <div class="versand-feld">
                    <label for="zielDatenbank">{{ui.targetDb}}</label>
                    <select id="zielDatenbank">
                        <option value="">{{ui.pleaseChoose}}</option>
                    </select>
                </div>
                <div class="versand-feld">
                    <label for="prioritaet">{{ui.priority}}</label>
                    <select id="prioritaet">
                        <option value="Low">{{ui.priorityLow}}</option>
                        <option value="Normal" selected>{{ui.priorityNormal}}</option>
                        <option value="High">{{ui.priorityHigh}}</option>
                        <option value="Critical">{{ui.priorityCritical}}</option>
                        <option value="Emergency">{{ui.priorityEmergency}}</option>
                    </select>
                </div>
                <div class="versand-feld">
                    <label for="badItemLimit">{{ui.badItems}}</label>
                    <select id="badItemLimit">
                        <option value="0" selected>{{ui.badItemsNone}}</option>
                        <option value="1">1</option>
                        <option value="10">10</option>
                        <option value="20">20</option>
                        <option value="50">50</option>
                        <option value="100">100</option>
                    </select>
                </div>
            </div>

            <div class="versand-feld">
                <label>{{ui.mode}}</label>
                <div class="modus-optionen">
                    <label>
                        <input type="radio" name="versandModus" value="durch" checked onchange="modusGeaendert()">
                        {{ui.modeDirect}}
                    </label>
                    <label>
                        <input type="radio" name="versandModus" value="suspend" onchange="modusGeaendert()">
                        {{ui.modeSuspend}}
                    </label>
                </div>
                <div class="modus-hinweis" id="modusHinweis"></div>
            </div>

            <div class="versand-zeile" style="margin-bottom: 12px;">
                <div class="versand-feld" style="margin-bottom: 0;">
                    <label for="vorabtest">{{ui.pretest}}</label>
                    <select id="vorabtest" onchange="vorabtestGeaendert()">
                        <option value="aus" selected>{{ui.pretestOff}}</option>
                        <option value="pruefen">{{ui.pretestCheckThenMove}}</option>
                        <option value="nur">{{ui.pretestOnly}}</option>
                    </select>
                </div>
            </div>

            <div class="versand-zeile">
                <div class="versand-feld">
                    <label for="postfachTyp">{{ui.mailboxType}}</label>
                    <select id="postfachTyp" onchange="benutzerLaden()"
                            title="{{ui.mailboxTypeTitle}}">
                        <option value="benutzer" selected>{{ui.mailboxTypeUser}}</option>
                        <option value="sonder">{{ui.mailboxTypeSpecial}}</option>
                        <option value="archiv">{{ui.mailboxTypeArchive}}</option>
                        <option value="alle">{{ui.mailboxTypeAll}}</option>
                    </select>
                </div>
                <div class="versand-feld">
                    <label for="benutzerSuche">{{ui.filterMailboxes}}</label>
                    <input type="text" class="versand-suche" id="benutzerSuche"
                           placeholder="&#128269; {{ui.filterMailboxesPlaceholder}}" oninput="benutzerFiltern()">
                </div>
            </div>

            <div class="versand-werkzeuge">
                <button type="button" class="mini-schalter" onclick="alleSichtbarenAuswaehlen()">{{ui.selectAllVisible}}</button>
                <button type="button" class="mini-schalter" onclick="auswahlAufheben()">{{ui.clearSelection}}</button>
                <span class="versand-hinweis-text" id="benutzerHinweis"></span>
            </div>

            <div class="benutzer-liste" id="benutzerListe">
                <div style="color:#888;padding:10px;">{{ui.mailboxesLoading}}</div>
            </div>

            <div class="versand-zeile" style="margin-top: 15px;">
                <button type="button" class="versand-schalter" id="versandSchalter"
                        onclick="verschiebungStarten()">&#9654; {{ui.startMoveRequest}}</button>
                <span class="versand-hinweis-text" id="auswahlZahl">{{ui.selectedCount}}</span>
            </div>

            <div class="versand-zeile" style="margin-top: 8px;">
                <button type="button" class="versand-schalter aktion-schalter"
                        id="alleResumeSchalter"
                        onclick="alleSuspendAbschliessen()">&#8635; {{ui.resumeAllSuspended}}</button>
                <button type="button" class="versand-schalter aktion-schalter aktion-warn"
                        id="alleLoeschenSchalter"
                        onclick="alleAbgeschlossenenLoeschen()">&#10005; {{ui.deleteAllCompleted}}</button>
                <span class="versand-hinweis-text">{{ui.backgroundJobNote}}</span>
            </div>

            <div class="versand-ergebnis" id="versandErgebnis"></div>
        </div>
    </div>

    <!-- Detail-Tabelle -->
    <div class="tabellen-container">
        <h2>&#128203; {{ui.detailsHeading}}</h2>
        <div class="sortier-hinweis" id="sortierHinweis">
            &#9650; {{ui.sortHint}}
        </div>
        <div class="suchfeld-container">
            <input type="text" class="suchfeld" id="suchfeld"
                   placeholder="&#128269; {{ui.searchPlaceholder}}">
        </div>
        <!-- Mehrfachauswahl: suspendierte Anforderungen anklicken und in
             einem Schritt abschliessen (v2.7). Erscheint nur, wenn es
             ueberhaupt auswaehlbare Zeilen gibt. -->
        <div class="auswahl-leiste" id="moveAuswahlLeiste">
            <label title="{{ui.selectAllVisibleSuspendedTitle}}">
                <input type="checkbox" id="moveAlleAuswahl" onchange="moveAlleAuswahlGeaendert(this)">
                {{ui.selectAllVisible}}
            </label>
            <button type="button" class="mini-schalter" id="moveAuswahlSchalter"
                    onclick="moveAuswahlAbschliessen()" disabled
                    title="{{ui.completeSelectionTitle}}">
                &#8635; {{ui.completeSelection}}
            </button>
            <button type="button" class="mini-schalter" id="moveAuswahlAufhebenSchalter"
                    onclick="moveAuswahlAufheben()" disabled>{{ui.clearSelection}}</button>
            <span class="versand-hinweis-text" id="moveAuswahlZahl">{{ui.selectedCountShort}}</span>
        </div>
        <div class="tabellen-scroll">
            <table>
                <thead>
                    <tr>
                        <th>{{ui.colDisplayName}}</th>
                        <th>{{ui.colStatus}}</th>
                        <th class="spalte-technisch">{{ui.colStatusDetail}}</th>
                        <th class="spalte-technisch">{{ui.colProgress}}</th>
                        <th class="spalte-technisch">{{ui.colTransferred}}</th>
                        <th class="spalte-technisch">{{ui.colTotalSize}}</th>
                        <th class="spalte-technisch">{{ui.colItems}}</th>
                        <th class="spalte-technisch">{{ui.colBadItems}}</th>
                        <th>{{ui.colSourceDb}}</th>
                        <th>{{ui.colTargetDb}}</th>
                        <th>{{ui.colBatch}}</th>
                        <th class="spalte-technisch">{{ui.colStart}}</th>
                        <th class="spalte-technisch">{{ui.colCompletion}}</th>
                    </tr>
                </thead>
                <tbody id="tabellenBody"></tbody>
            </table>
        </div>
    </div>

    <!-- Footer -->
    <div class="footer">
        <p>$SprachFusszeile$LightFussnote
           <a href="/api/data" target="_blank" style="color: #0078d4;">{{ui.jsonApi}}</a> |
           <a href="#" onclick="stopServer()" style="color: #dc3545;">{{ui.stopServer}}</a>
        </p>
    </div>

    <!-- ================================================================ -->
    <!-- JavaScript: Live-Update-Logik via Fetch-API (AJAX-Polling)       -->
    <!-- ================================================================ -->
    <script>
        // Konfigurations-Variablen
        const INTERVALL = $AktualisierungsIntervall;
        const FETCH_TIMEOUT_MS = $($AbfrageTimeout * 1000);
        const SPRACHE = '$SprachCode';

        // Lokalisierte Texte (v2.16): vom Server je Sprache eingebettet,
        // alle Zugriffe laufen ueber TXT('key').
        const TEXTE = $JsJson;
        function TXT(key) {
            return (TEXTE && TEXTE[key]) ? TEXTE[key] : '[[' + key + ']]';
        }

        /**
         * Sprachumschalter (v2.16): Cookie setzen und mit ?lang= neu laden.
         */
        function spracheUmschalten(lang) {
            document.cookie = 'DashboardSprache=' + lang + '; path=/; max-age=31536000; SameSite=Strict';
            const ziel = new URL(window.location.href);
            ziel.searchParams.set('lang', lang);
            window.location.href = ziel.toString();
            return false;
        }

        let updateZaehler = 0;
        let countdownTimer = null;
        let pollTimer = null;
        let abrufLaeuft = false;
        let verbleibendeZeit = INTERVALL;
        let overlayAusgeblendet = false;
        let overlayDatenFertig    = false;   // erster /api/data-Abruf beendet
        let overlayBenutzerFertig = false;   // Postfaecher-Lauf beendet

        /**
         * Zaehlt im Lade-Overlay von 0 auf die Zielzahl hoch, damit man
         * sieht, wie viele Postfaecher bereits da sind.
         */
        function zaehleHoch(ziel) {
            const feld   = document.getElementById('ladeZahl');
            const anzahl = Math.max(0, parseInt(ziel, 10) || 0);

            if (anzahl === 0) {
                feld.textContent = TXT('noMailboxes');
                return;
            }

            const dauer   = 600;   // Millisekunden fuer den Durchlauf
            const schritt = 40;    // Millisekunden je Anzeigeschritt
            const stufen  = Math.max(1, Math.round(dauer / schritt));
            let wert = 0;

            const timer = setInterval(function() {
                wert = Math.min(anzahl, wert + Math.max(1, Math.ceil(anzahl / stufen)));
                feld.textContent = TXT('loadedOf').replace('%Done%', wert).replace('%Total%', anzahl);
                if (wert >= anzahl) {
                    clearInterval(timer);
                    feld.textContent = TXT(anzahl === 1 ? 'mailboxesLoadedOne' : 'mailboxesLoadedMany').replace('%Count%', anzahl);
                }
            }, schritt);
        }

        /**
         * Meldet einen fertigen Ladevorgang.
         *
         * Sobald die Dashboard-Daten da sind, wird die Seite freigegeben -
         * die Tabelle ist das Nötigste. Postfächer und Detaildaten laufen
         * unabhängig weiter: die Postfächer füllen ihre Karte, sobald sie
         * eintreffen, die Detaildaten erscheinen im nächsten Poll.
         * Solange NUR die Postfächer fertig sind, zählt ihr Zähler im
         * Overlay weiter mit.
         */
        function overlayTeilFertig(art) {
            if (art === 'daten') { overlayDatenFertig = true; }
            else { overlayBenutzerFertig = true; }

            const text = document.getElementById('ladeText');
            const fehler = (text.dataset.fehler === '1');

            if (!fehler) {
                if (overlayBenutzerFertig && !overlayDatenFertig) {
                    text.textContent = TXT('dashboardDataPending');
                }
                else if (overlayDatenFertig && !overlayBenutzerFertig) {
                    text.textContent = TXT('dashboardDataReady');
                }
            }

            if (overlayDatenFertig && !overlayAusgeblendet) {
                overlayAusgeblendet = true;
                document.getElementById('ladeOverlay').style.display = 'none';
            }
        }

        // ================================================================
        // Status-Prioritäts-Map (muss mit PowerShell übereinstimmen)
        //      Niedrigere Zahl = aktiver Job = weiter oben
        // ================================================================
        const STATUS_PRIORITAET = {
            'InProgress':            1,
            'CompletionInProgress':  2,
            'Queued':                3,
            'AutoSuspended':         4,
            'Suspended':             5,
            'StalledDueToTarget':    6,
            'StalledDueToSource':    7,
            'Failed':                8,
            'CompletedWithWarning':  9,
            'Completed':            10
        };

        // Status-Gruppen: Alles mit Priorität <= 3 gilt als "aktiv"
        const AKTIV_GRENZE = 3;

        /**
         * Gibt die Sortierpriorität für einen Status zurück.
         * Unbekannte Status bekommen 99 (ganz unten).
         */
        function getStatusPrioritaet(status) {
            return STATUS_PRIORITAET[status] || 99;
        }

        /**
         * Prüft, ob ein Status als "aktiv" gilt.
         * Das Backend liefert das Flag bereits mit; der Fallback deckt
         * Cache-Daten aus älteren Snapshots ab.
         */
        function istAktiverStatus(job) {
            if (typeof job.Aktiv === 'boolean') return job.Aktiv;
            return getStatusPrioritaet(job.Status) <= AKTIV_GRENZE;
        }

        // ================================================================
        // Daten vom PowerShell-Backend abrufen
        // ================================================================
        async function datenAbrufen() {
            // Harte Sperre: es kann nie mehr als ein laufender Abruf geben.
            if (abrufLaeuft) return;
            abrufLaeuft = true;

            const steuerung = new AbortController();
            const zeitgeber = setTimeout(function() { steuerung.abort(); }, FETCH_TIMEOUT_MS);

            try {
                const response = await fetch('/api/data', {
                    signal: steuerung.signal,
                    cache: 'no-store'
                });
                if (!response.ok) throw new Error('HTTP ' + response.status);

                const daten = await response.json();
                updateZaehler++;
                dashboardAktualisieren(daten);

                document.getElementById('fehlerBox').style.display = 'none';
                liveAnzeigen('#28a745', TXT('live'));

            } catch (fehler) {
                const zeitUeber = fehler.name === 'AbortError';
                // In der Browser-Konsole sichtbar (inkl. Stack) - beim Debuggen hilfreich
                console.error('Dashboard: /api/data fehlgeschlagen -', fehler);
                const box = document.getElementById('fehlerBox');
                box.textContent = zeitUeber
                    ? TXT('timeout').replace('%Seconds%', (FETCH_TIMEOUT_MS / 1000))
                    : TXT('connectionLost').replace('%Message%', fehler.message);
                box.style.display = 'block';
                liveAnzeigen('#dc3545', zeitUeber ? TXT('timeoutStatus') : TXT('offline'));
            } finally {
                clearTimeout(zeitgeber);
                abrufLaeuft = false;
                // Overlay nach dem ersten Abruf IMMER abschliessen - auch bei
                // Fehler. Sonst dreht sich endlos ein Spinner. Sobald die
                // Tabelle da ist, gibt overlayTeilFertig() die Seite frei;
                // die Postfaecher laufen dann unabhaengig im Hintergrund.
                overlayTeilFertig('daten');
            }
        }

        /**
         * Live-Indikator setzen.
         */
        function liveAnzeigen(farbe, text) {
            document.getElementById('livePunkt').style.backgroundColor = farbe;
            document.getElementById('liveStatusText').textContent = text;
        }

        // ================================================================
        // Dashboard-UI aktualisieren
        // ================================================================
        function dashboardAktualisieren(daten) {
            document.getElementById('zeitstempelAnzeige').textContent =
                TXT('lastUpdate').replace('%Zeit%', daten.Zeitstempel);

            // Diagnosezeile: Datenalter und Dauer der letzten Sammlung
            const alter = daten.AlterSekunden || 0;
            const dauer = daten.DauerSekunden || 0;
            const fehler = daten.FehlerAnzahl || 0;
            const offen  = daten.DetailOffen || 0;
            const alterEl = document.getElementById('alterAnzeige');
            alterEl.textContent =
                TXT('dataAge').replace('%Alter%', alter).replace('%Dauer%', dauer) +
                (offen > 0 ? TXT('detailPending').replace('%Count%', offen) : '') +
                (fehler > 0 ? TXT('failedCount').replace('%Count%', fehler) : '');
            alterEl.classList.toggle('veraltet', alter > 60);

            // Serverseitiger Hinweis (z.B. Teilausfall einzelner Jobs) separat
            // vom Verbindungsfehler anzeigen
            if (daten.Fehler && daten.Details && daten.Details.length > 0) {
                const box = document.getElementById('fehlerBox');
                box.textContent = daten.Fehler;
                box.style.display = 'block';
            }

            const gesamtEl = document.getElementById('gesamtAnzahl');
            gesamtEl.textContent = daten.Gesamt;
            gesamtEl.classList.remove('fade-update');
            void gesamtEl.offsetWidth;
            gesamtEl.classList.add('fade-update');

            document.getElementById('updateZaehler').textContent =
                TXT('updates') + ' ' + updateZaehler;

            // Update-Badge (v2.15): einblenden, sobald der serverseitige
            // Check eine neuere GitLab-Version meldet; Klick oeffnet die
            // Release-Seite. Bei -KeinUpdateCheck bleiben die Felder leer
            // und das Badge dauerhaft ausgeblendet.
            const updBadge = document.getElementById('updateBadge');
            if (updBadge) {
                if (daten.UpdateVerfuegbar && daten.UpdateUrl) {
                    updBadge.textContent = TXT('updateAvailable').replace('%Tag%', (daten.UpdateTag || ''));
                    updBadge.href = daten.UpdateUrl;
                    updBadge.style.display = '';
                } else {
                    updBadge.style.display = 'none';
                }
            }

            kachelnAktualisieren(daten.StatusGruppen);
            tabelleAktualisieren(daten.Details);
        }

        // ================================================================
        // Status-Kacheln dynamisch erzeugen (bereits nach Priorität sortiert)
        // ================================================================
        function kachelnAktualisieren(gruppen) {
            const container = document.getElementById('kachelnContainer');
            container.innerHTML = '';

            if (!gruppen || gruppen.length === 0) {
                container.innerHTML = '<div style="color:#888;padding:20px;">' + TXT('noData') + '</div>';
                return;
            }

            gruppen.forEach(function(g) {
                const aktiv = getStatusPrioritaet(g.Name) <= AKTIV_GRENZE;
                const kachel = document.createElement('div');
                kachel.className = 'status-kachel fade-update';
                kachel.style.borderLeft = '5px solid ' + g.Farbe;

                if (aktiv) {
                    kachel.style.backgroundColor = '#f0f8ff';
                }

                kachel.innerHTML =
                    '<div class="kachel-zahl" style="color:' + escapeHtml(g.Farbe) + ';">' + escapeHtml(g.Anzahl) + '</div>' +
                    '<div class="kachel-status">' + escapeHtml(g.Name) +
                    (aktiv ? ' &#9654;' : '') +  // Pfeil-Symbol bei aktiven
                    '</div>' +
                    '<div class="kachel-prozent">' + escapeHtml(g.Prozent) + ' %</div>';
                container.appendChild(kachel);
            });
        }

        // ================================================================
        // NEU: Detail-Tabelle mit Prioritätssortierung + Trennlinie
        // ================================================================
        // ================================================================
        // Mehrfachauswahl suspendierter Anforderungen (v2.7)
        // ================================================================
        // Die Tabelle wird bei JEDEM Poll komplett neu gebaut - die Auswahl
        // muss den Render ueberleben. Deshalb ein Set der Identities und
        // separat die Anzeigenamen fuer die Bestaetigungs-Abfrage.
        const moveAuswahl      = new Set();
        const moveAuswahlNamen = new Map();

        function tabelleAktualisieren(details) {
            const tbody = document.getElementById('tabellenBody');
            tbody.innerHTML = '';

            if (!details || details.length === 0) {
                tbody.innerHTML = '<tr><td colspan="13" style="text-align:center;color:#888;padding:30px;">' +
                    TXT('noMoveRequests') + '</td></tr>';
                // Sortierhinweis ausblenden
                document.getElementById('sortierHinweis').style.display = 'none';
                // Auswaehlbare Zeilen gibt es keine mehr -> Auswahl leeren
                moveAuswahlPrunen([]);
                moveAuswahlAktualisieren();
                return;
            }

            // Sortierhinweis einblenden
            document.getElementById('sortierHinweis').style.display = 'block';

            // ============================================================
            // NEU: Sortierung nach StatusPrioritaet (vom Backend mitgeliefert),
            //      dann nach DisplayName als Fallback
            // ============================================================
            details.sort(function(a, b) {
                // Primär: Nach Priorität sortieren (niedrig = oben)
                const prioA = a.StatusPrioritaet || getStatusPrioritaet(a.Status);
                const prioB = b.StatusPrioritaet || getStatusPrioritaet(b.Status);

                if (prioA !== prioB) return prioA - prioB;

                // Sekundär: Bei gleicher Priorität nach Name sortieren
                if (a.DisplayName < b.DisplayName) return -1;
                if (a.DisplayName > b.DisplayName) return 1;
                return 0;
            });

            // ============================================================
            // NEU: Trennlinie zwischen aktiven und nicht-aktiven Jobs
            // ============================================================
            let trennlinieEingefuegt = false;
            const hatAktiveJobs   = details.some(function(d) { return istAktiverStatus(d); });
            const hatInaktiveJobs = details.some(function(d) { return !istAktiverStatus(d); });
            const trennlinieNoetig = hatAktiveJobs && hatInaktiveJobs;

            details.forEach(function(d) {
                // Prüfen, ob wir die Trennlinie einfügen müssen
                if (trennlinieNoetig && !trennlinieEingefuegt && !istAktiverStatus(d)) {
                    const trennZeile = document.createElement('tr');
                    trennZeile.className = 'trenn-zeile';
                    trennZeile.innerHTML =
                        '<td colspan="13">&#9660; ' + TXT('completedInactiveJobs') + '</td>';
                    tbody.appendChild(trennZeile);
                    trennlinieEingefuegt = true;
                }

                const tr = document.createElement('tr');
                tr.className = 'fade-update';

                // NEU: Aktive Zeilen visuell hervorheben
                if (istAktiverStatus(d)) {
                    tr.classList.add('aktiv-zeile');
                }

                tr.setAttribute('data-suchtext',
                    (d.DisplayName + ' ' + d.Status + ' ' + d.StatusDetail + ' ' +
                     d.QuellDatenbank + ' ' + d.ZielDatenbank + ' ' + d.BatchName).toLowerCase());

                // Zeile, deren Statistik nicht abrufbar war: Tooltip mit der
                // Ursache und ein Warnzeichen, damit sie nicht wie eine
                // fertige Zeile mit 0 % aussieht.
                if (d.StatistikFehler) {
                    tr.setAttribute('title', TXT('statsUnavailable').replace('%Cause%', (d.Nachricht || TXT('unknownCause'))));
                    tr.style.backgroundColor = '#fff8e1';
                }
                else if (d.DetailOffen) {
                    // Grunddaten-Lauf: die Statistik kommt im naechsten Poll.
                    // Absichtlich KEIN Warnzeichen und KEIN Gelb - das ist
                    // kein Fehler, nur ein noch offener Detailabruf.
                    tr.setAttribute('title', TXT('detailsLoading'));
                }

                // Warnzeichen nur anhaengen, wenn es wirklich ein Fehler ist
                var nameZelle = '<strong>' + escapeHtml(d.DisplayName) + '</strong>';
                if (d.StatistikFehler) {
                    nameZelle += ' <span title="' + escapeHtml(d.Nachricht || TXT('unknownCause')) +
                        '" style="color:#b8860b;font-weight:bold;">&#9888;</span>';
                }

                // Fortschritt: bei offenen Detaildaten "..." statt einer
                // scheinbaren 0 %. Der Balken ist hellgrau = wird geladen.
                var fortschrittZelle =
                    '<div class="fortschritt-container">' +
                        '<div class="fortschritt-balken" style="width:' + escapeHtml(d.ProzentAbgeschlossen) +
                            '%;background-color:' + escapeHtml(d.BalkenFarbe) + ';">' +
                            escapeHtml(d.ProzentAbgeschlossen) + '%' +
                        '</div>' +
                    '</div>';

                if (d.DetailOffen) {
                    fortschrittZelle =
                        '<div class="fortschritt-container">' +
                            '<div class="fortschritt-balken" style="width:100%;background-color:#e9ecef;color:#868e96;"' +
                                ' title="' + TXT('detailsLoadingTitle') + '">…</div>' +
                        '</div>';
                }

                // Statuszelle: Badge und - bei suspendierten Anforderungen -
                // dahinter der Button, der GENAU diese Anforderung
                // abschliesst (v2.4). Zutreffend sind 'Suspended'
                // (-SuspendWhenReadyToComplete) und 'AutoSuspended'
                // (automatisches Anhalten). Der Button verschwindet
                // automatisch, sobald der Status sich geaendert hat.
                const suspendiert = /Suspend/i.test(String(d.Status || ''));
                let statusZelle =
                    '<span class="status-badge" style="background-color:' + escapeHtml(d.StatusFarbe) + ';">' +
                        escapeHtml(d.Status) + '</span>';

                if (suspendiert && d.Identity) {
                    // Kaestchen fuer die Mehrfachauswahl (v2.7): links vom
                    // Badge, der Einzel-Button bleibt daneben stehen.
                    statusZelle =
                        '<label class="zeilen-auswahl" title="' + TXT('selectToComplete') + '">' +
                            '<input type="checkbox" data-identity="' + escapeHtml(d.Identity) + '"' +
                                ' data-name="' + escapeHtml(d.DisplayName) + '"' +
                                (moveAuswahl.has(d.Identity) ? ' checked' : '') +
                                ' onchange="moveAuswahlKastenGeaendert(this)">' +
                        '</label>' + statusZelle;

                    statusZelle +=
                        ' <button type="button" class="mini-schalter auftrag-knopf" ' +
                            'data-identity="' + escapeHtml(d.Identity) + '" ' +
                            'data-name="' + escapeHtml(d.DisplayName) + '" ' +
                            'title="' + TXT('completeTitle') + '" ' +
                            'onclick="anforderungAbschliessen(this.dataset.identity, this.dataset.name)">' +
                            '&#8635; ' + TXT('complete') + '</button>';
                }

                tr.innerHTML =
                    '<td>' + nameZelle + '</td>' +
                    '<td>' + statusZelle + '</td>' +
                    '<td>' + escapeHtml(d.StatusDetail) + '</td>' +
                    '<td>' + fortschrittZelle + '</td>' +
                    '<td>' + escapeHtml(d.BytesUebertragen) + '</td>' +
                    '<td>' + escapeHtml(d.GesamtGroesse) + '</td>' +
                    '<td>' + escapeHtml(d.ItemsUebertragen) + '</td>' +
                    '<td>' + escapeHtml(d.BadItemsGefunden) + '</td>' +
                    '<td>' + escapeHtml(d.QuellDatenbank) + '</td>' +
                    '<td>' + escapeHtml(d.ZielDatenbank) + '</td>' +
                    '<td>' + escapeHtml(d.BatchName) + '</td>' +
                    '<td>' + escapeHtml(d.StartZeit) + '</td>' +
                    '<td>' + escapeHtml(d.AbschlussZeit) + '</td>';

                tbody.appendChild(tr);
            });

            // Suchfilter erneut anwenden
            suchfilterAnwenden();

            // Auswahl nachziehen: Identities, die nicht mehr (suspendiert)
            // in der Tabelle stehen, rauswerfen und die Leiste aktualisieren.
            moveAuswahlPrunen(details);
            moveAuswahlAktualisieren();
        }

        // ================================================================
        // HTML-Sonderzeichen escapen (XSS-Schutz)
        // ================================================================
        function escapeHtml(text) {
            if (text === null || text === undefined) return '';
            return String(text)
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;');
        }

        // ================================================================
        // Suchfilter für die Tabelle
        // ================================================================
        function suchfilterAnwenden() {
            const suchbegriff = document.getElementById('suchfeld').value.toLowerCase();
            const zeilen = document.querySelectorAll('#tabellenBody tr');

            zeilen.forEach(function(zeile) {
                // Trennzeilen immer anzeigen wenn passende Ergebnisse da sind
                if (zeile.classList.contains('trenn-zeile')) {
                    // Trennzeile nur zeigen wenn mind. eine Zeile danach sichtbar ist
                    zeile.style.display = suchbegriff === '' ? '' : 'none';
                    return;
                }
                const suchtext = zeile.getAttribute('data-suchtext') || '';
                zeile.style.display = suchtext.includes(suchbegriff) ? '' : 'none';
            });

            // Trennzeile intelligent ein/ausblenden bei aktiver Suche
            if (suchbegriff !== '') {
                const alleZeilen = document.querySelectorAll('#tabellenBody tr:not(.trenn-zeile)');
                let sichtbareInaktive = false;
                let sichtbareAktive = false;

                alleZeilen.forEach(function(z) {
                    if (z.style.display !== 'none') {
                        if (z.classList.contains('aktiv-zeile')) {
                            sichtbareAktive = true;
                        } else {
                            sichtbareInaktive = true;
                        }
                    }
                });

                const trennZeilen = document.querySelectorAll('#tabellenBody tr.trenn-zeile');
                trennZeilen.forEach(function(tz) {
                    tz.style.display = (sichtbareAktive && sichtbareInaktive) ? '' : 'none';
                });
            }
        }

        // Nach einer Suche neu bewerten, ob "Alle sichtbaren" gesetzt sein
        // muss (die Sichtbarkeit aendert sich, die Auswahl selbst nicht).
        document.getElementById('suchfeld').addEventListener('input', function() {
            suchfilterAnwenden();
            moveAuswahlAktualisieren();
        });

        // ================================================================
        // Verschiebeanforderung starten (v2.2)
        // ================================================================
        let benutzerDaten   = [];
        let auswahl         = new Set();
        let versandLaueuft  = false;
        let statusZeitgeber = null;
        let statusFehler    = 0;

        /**
         * Laedt alle Postfachdatenbanken und fuellt Quell- und Zielauswahl.
         */
        async function datenbankenLaden() {
            const quellFeld = document.getElementById('quellDatenbank');
            const zielFeld  = document.getElementById('zielDatenbank');

            try {
                const response = await fetch('/api/databases', { cache: 'no-store' });
                if (!response.ok) throw new Error('HTTP ' + response.status);

                const daten       = await response.json();
                const datenbanken = daten.Datenbanken || [];

                quellFeld.innerHTML = '<option value="">-- bitte wählen --</option>';
                zielFeld.innerHTML  = '<option value="">-- bitte wählen --</option>';

                datenbanken.forEach(function(db) {
                    const text = db.Name + ' (' + db.Server + ')';

                    const optionQuelle = document.createElement('option');
                    optionQuelle.value = db.Name;
                    optionQuelle.textContent = text;
                    quellFeld.appendChild(optionQuelle);

                    const optionZiel = document.createElement('option');
                    optionZiel.value = db.Name;
                    optionZiel.textContent = text;
                    zielFeld.appendChild(optionZiel);
                });
            } catch (fehler) {
                document.getElementById('benutzerListe').innerHTML =
                    '<div style="color:#dc3545;padding:10px;">' +
                    TXT('databasesLoadError').replace('%Message%', escapeHtml(fehler.message)) + '</div>';
            }
        }

        /**
         * Baut die Adresse fuer /api/benutzer inklusive Quell-Datenbank
         * und Postfachart (benutzer | sonder | alle | archiv). Als eigene
         * Funktion, damit sich die Parameterkette testen laesst.
         */
        function benutzerApiAdresse(quelle, typ) {
            const parameter = [];

            if (quelle) { parameter.push('quelle=' + encodeURIComponent(quelle)); }
            parameter.push('typ=' + encodeURIComponent(typ || 'benutzer'));

            return '/api/benutzer?' + parameter.join('&');
        }

        /**
         * Auswahl-Schluessel eines Postfachs. Zunaechst die SMTP-Adresse;
         * Sonderpostfaecher (Arbitration, AuditLog, AuxAuditLog,
         * PublicFolder, Archiv) haben oft keine eigene - ohne Rueckfaellung
         * laege der Wert leer da und alle solchen Postfaecher gehoerten zu
         * EINEM Kaestchen. Darum Alias bzw. Anzeigename als Ersatz.
         */
        function benutzerSchluessel(b) {
            if (!b) { return ''; }
            return b.Schluessel || b.Adresse || '';
        }

        /**
         * Anzeigetext fuer eine Listenzeile: Anzeigename und Adresse,
         * wobei ein leeres oder identisches Kuerzel weggelassen wird.
         */
        function benutzerAnzeige(b) {
            const name    = b.AnzeigeName || benutzerSchluessel(b) || '(ohne Namen)';
            const adresse = b.Adresse || b.Alias || '';

            return name + (adresse && adresse !== name ? ' – ' + adresse : '');
        }

        /**
         * Laedt die Postfaecher. Ohne Quelldatenbank werden alle
         * Postfaecher aller Datenbanken angezeigt. Die Postfachart
         * (benutzer | sonder | alle | archiv) kommt aus dem Auswahlfeld.
         */
        async function benutzerLaden() {
            const quelle = document.getElementById('quellDatenbank').value;
            const liste  = document.getElementById('benutzerListe');

            const textFeld = document.getElementById('ladeText');
            const zahlFeld = document.getElementById('ladeZahl');

            textFeld.textContent = TXT('mailboxesLoading');
            textFeld.style.color = '';
            textFeld.dataset.fehler = '';
            if (!overlayAusgeblendet) { zahlFeld.textContent = ''; }

            // Die Auswahl wird bewusst NICHT hier geleert: ein Neuladen
            // (Quellenwechsel, Abschluss eines Auftrags) darf die bereits
            // markierten Postfaecher nicht wegwerfen. Die Bereinigung
            // gegen den frischen Stand uebernimmt benutzerZeichnen().
            liste.innerHTML = '<div style="color:#888;padding:10px;">' + TXT('mailboxesLoading') + '</div>';

            try {
                const adresse = benutzerApiAdresse(
                    quelle,
                    document.getElementById('postfachTyp').value);

                const response = await fetch(adresse, { cache: 'no-store' });
                if (!response.ok) {
                    const fehlerDaten = await response.json().catch(function() { return {}; });
                    throw new Error(fehlerDaten.Fehler || ('HTTP ' + response.status));
                }

                const daten = await response.json();
                benutzerDaten = daten.Benutzer || [];

                // Zaehler im Overlay hochlaufen lassen, dann die Liste zeichnen
                if (!overlayAusgeblendet) {
                    textFeld.textContent = TXT('mailboxesQueried');
                    zaehleHoch(benutzerDaten.length);
                }

                benutzerZeichnen();
            } catch (fehler) {
                benutzerDaten = [];
                auswahl       = new Set();
                liste.innerHTML = '<div style="color:#dc3545;padding:10px;">' +
                    TXT('mailboxesLoadError').replace('%Message%', escapeHtml(fehler.message)) + '</div>';

                if (!overlayAusgeblendet) {
                    textFeld.textContent = TXT('mailboxesLoadError').replace('%Message%', fehler.message);
                    textFeld.style.color = '#dc3545';
                    textFeld.dataset.fehler = '1';
                }

                auswahlAktualisieren();
            } finally {
                overlayTeilFertig('benutzer');
            }
        }

        /**
         * Liefert die dem Filter entsprechenden Postfaecher.
         * Mitgefiltert wird auch die Datenbankzugehoerigkeit.
         */
        function sichtbareBenutzer() {
            const filter = (document.getElementById('benutzerSuche').value || '').toLowerCase();

            return benutzerDaten.filter(function(b) {
                if (!filter) return true;
                const text = ((b.AnzeigeName || '') + ' ' + (b.Adresse || '') + ' ' +
                              (b.Alias || '') + ' ' + (b.Typ || '') + ' ' +
                              (b.Datenbank || '') + ' ' +
                              (b.Archiv ? 'archiv' : '')).toLowerCase();
                return text.indexOf(filter) !== -1;
            });
        }

        /**
         * Zeichnet die Postfaecherliste neu (inkl. Auswahl).
         */
        function benutzerZeichnen() {
            const liste = document.getElementById('benutzerListe');
            liste.innerHTML = '';

            // Auswahl gegen den aktuellen Stand bereinigen: was nicht (mehr)
            // waehlbar ist, fliegt raus - sonst startet man versehentlich
            // eine zweite Verschiebung fuer dasselbe Postfach.
            const aktuell = new Set();
            benutzerDaten.forEach(function(b) {
                const schluessel = benutzerSchluessel(b);
                if (!b.Bewegt && auswahl.has(schluessel)) aktuell.add(schluessel);
            });
            auswahl = aktuell;

            const sichtbar = sichtbareBenutzer();

            if (sichtbar.length === 0) {
                liste.innerHTML = '<div style="color:#888;padding:10px;">' + TXT('noMatchingMailboxes') + '</div>';
                document.getElementById('benutzerHinweis').textContent = hinweisText(0);
                auswahlAktualisieren();
                return;
            }

            sichtbar.forEach(function(b) {
                const zeile = document.createElement('label');
                zeile.className = 'benutzer-eintrag' + (b.Bewegt ? ' gesperrt' : '');

                const kasten = document.createElement('input');
                kasten.type  = 'checkbox';
                kasten.value = benutzerSchluessel(b);
                kasten.checked = auswahl.has(kasten.value);
                if (b.Bewegt) kasten.disabled = true;

                kasten.addEventListener('change', function() {
                    if (kasten.checked) auswahl.add(kasten.value);
                    else auswahl.delete(kasten.value);
                    auswahlAktualisieren();
                });

                const text = document.createElement('span');
                text.textContent = benutzerAnzeige(b) +
                    (b.Bewegt ? ' (' + TXT('alreadyMoving').replace('%Status%', b.Status) + ')' : '');

                // Postfachart (Arbitration, AuditLog, AuxAuditLog,
                // PublicFolder, Archiv, ...) - nur bei Sonderpostfaechern
                // markiert, damit die Liste auch ohne Erklaerung lesbar ist.
                if (b.Typ && b.Typ !== 'Benutzer') {
                    const marke = document.createElement('span');
                    marke.className = 'typ-tag';
                    marke.textContent = b.Typ;
                    zeile.appendChild(marke);
                }

                // Postfach mit aktiviertem Archiv: erklaert in der Ansicht
                // "Postfaecher mit Archiv", warum ein sonst normales
                // Benutzerpostfach hier steht - sonst bliebe die Zeile
                // ohne sichtbaren Grund in der Liste.
                if (b.Archiv && b.Typ !== 'Archiv') {
                    const marke = document.createElement('span');
                    marke.className = 'typ-tag';
                    marke.textContent = 'Archiv';
                    zeile.appendChild(marke);
                }

                // Datenbankzugehoerigkeit rechts - besonders wichtig, wenn
                // ohne Quell-Datenbank alle Postfaecher angezeigt werden.
                const datenbank = document.createElement('span');
                datenbank.className = 'db-tag';
                datenbank.textContent = b.Datenbank || 'unbekannt';

                zeile.appendChild(kasten);
                zeile.appendChild(text);
                zeile.appendChild(datenbank);
                liste.appendChild(zeile);
            });

            document.getElementById('benutzerHinweis').textContent = hinweisText(sichtbar.length);
            auswahlAktualisieren();
        }

        /**
         * Hinweiszeile ueber die aktuelle Anzahl und die Quelle.
         */
        function hinweisText(sichtbar) {
            const quelle  = document.getElementById('quellDatenbank').value;
            const typFeld = document.getElementById('postfachTyp');
            const typ     = typFeld ? (typFeld.value || 'benutzer') : 'benutzer';

            const artText = {
                benutzer: TXT('mailboxTypeUser'),
                sonder:   TXT('mailboxTypeSpecial'),
                archiv:   TXT('mailboxTypeArchive'),
                alle:     TXT('mailboxTypeAll')
            }[typ] || TXT('mailboxes');

            return TXT('visibleOf')
                .replace('%Visible%', sichtbar)
                .replace('%Total%', benutzerDaten.length)
                .replace('%Type%', artText)
                + (quelle ? TXT('source').replace('%Source%', quelle) : TXT('allDatabases'));
        }

        function benutzerFiltern() {
            benutzerZeichnen();
        }

        function alleSichtbarenAuswaehlen() {
            const kasten = document.querySelectorAll('#benutzerListe input[type="checkbox"]:not(:disabled)');
            kasten.forEach(function(k) { auswahl.add(k.value); });
            benutzerZeichnen();
        }

        function auswahlAufheben() {
            auswahl = new Set();
            benutzerZeichnen();
        }

        function auswahlAktualisieren() {
            document.getElementById('auswahlZahl').textContent =
                TXT('selected').replace('%Count%', auswahl.size);
        }

        /**
         * Hinweistext zum gewaehlten Modus anpassen.
         */
        function modusGeaendert() {
            const suspend = document.querySelector('input[name="versandModus"]:checked').value === 'suspend';
            const hinweis = document.getElementById('modusHinweis');

            hinweis.textContent = suspend ? TXT('modeSuspendHint') : TXT('modeDirectHint');
        }

        /**
         * Startbutton an den gewaehlten Vorabtest (-WhatIf) anpassen.
         */
        function vorabtestGeaendert() {
            const wert  = document.getElementById('vorabtest').value;
            const knopf = document.getElementById('versandSchalter');

            if (wert === 'nur') {
                knopf.innerHTML = '&#128269; ' + TXT('checkOnly');
            }
            else if (wert === 'pruefen') {
                knopf.innerHTML = '&#9654; ' + TXT('checkAndMove');
            }
            else {
                knopf.innerHTML = '&#9654; ' + TXT('startMove');
            }
        }

        /**
         * Anzeigetext fuer den gewaehlten Vorabtest.
         */
        function vorabtestText(wert) {
            if (wert === 'nur')   { return TXT('pretestOnly'); }
            if (wert === 'pruefen') { return TXT('pretestCheckThenMove'); }
            return TXT('pretestOff');
        }

        /**
         * Ergebnisbox fuellen.
         */
        function zeigeVersandMeldung(html, fehler) {
            const box = document.getElementById('versandErgebnis');
            box.innerHTML = html;
            box.style.backgroundColor = fehler ? '#f8d7da' : '#d4edda';
            box.style.color           = fehler ? '#721c24' : '#155724';
            box.style.border          = fehler ? '1px solid #f5c6cb' : '1px solid #c3e6cb';
            box.style.display         = 'block';
        }

        /**
         * Verschiebeanforderung an das Backend uebergeben.
         * Die MoveRequests werden asynchron erstellt - die Antwort kommt
         * sofort zurueck, der Fortschritt laeuft ueber /api/move-status.
         */
        async function verschiebungStarten() {
            if (versandLaueuft) return;

            const quelle   = document.getElementById('quellDatenbank').value;
            const ziel     = document.getElementById('zielDatenbank').value;
            const prioritaet = document.getElementById('prioritaet').value;
            const badItems   = document.getElementById('badItemLimit').value;
            const vorabtest  = document.getElementById('vorabtest').value;
            const benutzer = Array.from(auswahl);

            // Quelle darf leer sein - dann werden alle ausgewaehlten
            // Postfaecher (Liste zeigt ohnehin alle) verschoben.
            if (!ziel)   { zeigeVersandMeldung(TXT('selectTarget'), true); return; }
            if (quelle === ziel) { zeigeVersandMeldung(TXT('sameDb'), true); return; }
            if (benutzer.length === 0) { zeigeVersandMeldung(TXT('selectMailbox'), true); return; }

            const suspend = (document.querySelector('input[name="versandModus"]:checked').value === 'suspend');
            const nurPruefen = (vorabtest === 'nur');

            const frage = TXT(nurPruefen ? 'confirmCheckOnly' : 'confirmMove').replace('%Count%', benutzer.length).replace('%Target%', ziel)
                + TXT('confirmMoveDetails')
                    .replace('%Source%', quelle || TXT('allDatabases'))
                    .replace('%Priority%', prioritaet)
                    .replace('%BadItems%', badItems)
                    .replace('%Pretest%', vorabtestText(vorabtest))
                + (nurPruefen ? '' : TXT('confirmMode').replace('%Mode%', suspend ? TXT('modeSuspendShort') : TXT('modeDirectShort')));

            if (!confirm(frage)) return;

            versandLaueuft = true;
            const schalter = document.getElementById('versandSchalter');
            schalter.disabled = true;
            zeigeVersandMeldung(nurPruefen
                ? TXT('whatIfStarted')
                : TXT('jobStarted'), false);

            try {
                const response = await fetch('/api/move', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        Quelle:       quelle,
                        Ziel:         ziel,
                        Benutzer:     benutzer,
                        Suspend:      suspend,
                        Prioritaet:   prioritaet,
                        BadItemLimit: parseInt(badItems, 10),
                        Vorabtest:    vorabtest
                    })
                });

                const daten = await response.json().catch(function() { return {}; });

                if (!response.ok || daten.Fehler) {
                    zeigeVersandMeldung(TXT('errorPrefix').replace('%Message%', escapeHtml(daten.Fehler || ('HTTP ' + response.status))), true);
                    return;
                }

                zeigeVersandMeldung(
                    '<strong>' + TXT('jobStartedStrong').replace('%Id%', escapeHtml(daten.AuftragId)) + '</strong><br>' +
                    escapeHtml(daten.Meldung), false);
                statusAbfragenStarten();
            } catch (fehler) {
                zeigeVersandMeldung(TXT('errorPrefix').replace('%Message%', escapeHtml(fehler.message)), true);
            } finally {
                versandLaueuft = false;
                schalter.disabled = false;
            }
        }

        /**
         * Suspendierte fortssetzen / abgeschlossene entfernen (v2.2).
         * Laeuft ueber dieselbe Kette wie die Verschiebung selbst:
         * der Server antwortet sofort mit einer Auftrag-Id, der Fortschritt
         * kommt danach ueber /api/move-status.
         *
         * Zielwahl (v2.4): batchName + alle fuer Batch bzw. alles,
         * identity fuer EINE einzelne Anforderung aus der Tabelle.
         * Mehrfachauswahl (v2.7): identities als Array - daraus baut der
         * Server EINEN Auftrag, der die Anforderungen der Reihe nach
         * fortsetzt (ein Fortschrittsbalken statt N Requests).
         *
         * Gibt die Server-Antwort zurueck (bzw. null bei Fehler oder
         * abgebrochener Bestaetigung).
         */
        async function moveAktionStarten(aktion, batchName, alle, frage, identities) {
            if (versandLaueuft) {
                zeigeVersandMeldung('Es läuft bereits ein Vorgang - bitte kurz warten.', true);
                return null;
            }
            if (!confirm(frage)) return null;

            // Einzel-Identity (v2.4) und Mehrfachauswahl (v2.7) laufen
            // ueber denselben Aufruf.
            const ziele = Array.isArray(identities)
                ? identities
                : (identities ? [identities] : []);

            versandLaueuft = true;
            const knoepfe = ['alleResumeSchalter', 'alleLoeschenSchalter',
                             'moveAuswahlSchalter', 'moveAuswahlAufhebenSchalter'];
            knoepfe.forEach(function(id) {
                const k = document.getElementById(id);
                if (k) k.disabled = true;
            });
            zeigeVersandMeldung('Aktion wird gestartet ...', false);

            try {
                const response = await fetch('/api/move-aktion', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        Aktion:     aktion,
                        BatchName:  batchName || '',
                        Alle:       !!alle,
                        Identity:   ziele.length === 1 ? ziele[0] : '',
                        Identities: ziele
                    })
                });

                const daten = await response.json().catch(function() { return {}; });

                if (!response.ok || daten.Fehler) {
                    zeigeVersandMeldung('Fehler: ' + escapeHtml(daten.Fehler || ('HTTP ' + response.status)), true);
                    return null;
                }

                zeigeVersandMeldung(
                    '<strong>Auftrag #' + escapeHtml(daten.AuftragId) + ' gestartet.</strong><br>' +
                    escapeHtml(daten.Meldung), false);
                statusAbfragenStarten();

                // Der Auftrag laeuft - die Auswahl ist verbraucht. Bei
                // Fehlern bleibt sie stehen, damit erneut gestartet werden
                // kann.
                if (ziele.length > 0) moveAuswahlAufheben();

                return daten;
            } catch (fehler) {
                zeigeVersandMeldung('Fehler: ' + escapeHtml(fehler.message), true);
                return null;
            } finally {
                versandLaueuft = false;
                knoepfe.forEach(function(id) {
                    const k = document.getElementById(id);
                    if (k) k.disabled = false;
                });
                // Zustand neu bewerten: bei 0 ausgewaehlt wieder gesperrt.
                moveAuswahlAktualisieren();
            }
        }

        /** Suspendierte Anforderungen EINES Batches fortsetzen. */
        function resumeAbschliessen(batch) {
            moveAktionStarten('Resume', batch, false,
                'Suspendierte Anforderungen im Batch "' + batch + '" fortsetzen?\n\n' +
                'Resume-MoveRequest: die Verschiebung läuft danach bis zum Abschluss weiter.');
        }

        /**
         * EINE suspendierte Anforderung aus der Tabelle abschliessen (v2.4).
         * Der Button steht hinter jeder Zeile mit *Suspend*-Status - also
         * auch hinter auto-suspendierten Anforderungen. Es wird genau die
         * eine Identity weitergeschickt, nicht der ganze Batch.
         */
        function anforderungAbschliessen(identity, name) {
            moveAktionStarten('Resume', '', false,
                TXT('confirmResumeOne').replace('%Name%', name),
                identity);
        }

        /** ALLE suspendierten Anforderungen fortsetzen. */
        function alleSuspendAbschliessen() {
            moveAktionStarten('Resume', '', true,
                TXT('confirmResumeAll'));
        }

        // ================================================================
        // Mehrfachauswahl suspendierter Anforderungen (v2.7)
        // ================================================================

        /**
         * Ein Kaestchen in der Tabelle umschalten.
         */
        function moveAuswahlKastenGeaendert(kasten) {
            const id = kasten.dataset.identity;
            if (kasten.checked) {
                moveAuswahl.add(id);
                moveAuswahlNamen.set(id, kasten.dataset.name || id);
            } else {
                moveAuswahl.delete(id);
                moveAuswahlNamen.delete(id);
            }
            moveAuswahlAktualisieren();
        }

        /**
         * "Alle sichtbaren auswaehlen" - nur Zeilen, die der Suchfilter
         * gerade zeigt. Beim Abwaehlen wird die gesamte Auswahl geleert,
         * auch die hinter der Suche versteckten Treffer (anders wuerde der
         * Zaehler weiterlaufen, waehrend nichts mehr sichtbar ist).
         */
        function moveAlleAuswahlGeaendert(kasten) {
            const kisten = document.querySelectorAll('#tabellenBody input[data-identity]');

            if (kasten.checked) {
                kisten.forEach(function(k) {
                    if (k.closest('tr').style.display === 'none') return;
                    moveAuswahl.add(k.dataset.identity);
                    moveAuswahlNamen.set(k.dataset.identity, k.dataset.name || k.dataset.identity);
                });
            } else {
                moveAuswahl.clear();
                moveAuswahlNamen.clear();
            }

            // Der Suchfilter kann nach dem Setzen geaendert haben, welche
            // Zeile sichtbar ist - die Kaestchen folgen der Auswahl, nicht
            // umgekehrt.
            kisten.forEach(function(k) { k.checked = moveAuswahl.has(k.dataset.identity); });
            moveAuswahlAktualisieren();
        }

        /** Ausgewaehlte Kaestchen leeren. */
        function moveAuswahlAufheben() {
            moveAuswahl.clear();
            moveAuswahlNamen.clear();

            document.querySelectorAll('#tabellenBody input[data-identity]').forEach(function(k) {
                k.checked = false;
            });
            const alle = document.getElementById('moveAlleAuswahl');
            if (alle) alle.checked = false;

            moveAuswahlAktualisieren();
        }

        /**
         * ALLE ausgewaehlten Anforderungen in EINEM Schritt abschliessen.
         * Ein einziger /api/move-aktion-Aufruf mit allen Identities - der
         * Server faedelt daraus genau einen Hintergrund-Auftrag mit
         * Fortschrittsanzeige, statt N Requests zu schicken.
         */
        function moveAuswahlAbschliessen() {
            const ids = Array.from(moveAuswahl);
            if (ids.length === 0) return;

            const namen = ids.map(function(id) { return moveAuswahlNamen.get(id) || id; });
            const liste = namen.slice(0, 10).map(function(n) { return '  • ' + n; }).join('\n');
            const rest  = namen.length > 10 ? TXT('andMore').replace('%Count%', namen.length - 10) : '';

            const frage =
                TXT(namen.length === 1 ? 'confirmCompleteSelectedOne' : 'confirmCompleteSelectedMany').replace('%Count%', namen.length) +
                TXT('confirmCompleteSelectedDetails').replace('%List%', liste).replace('%Rest%', rest);

            moveAktionStarten('Resume', '', false, frage, ids);
        }

        /**
         * Auswahl aufraeumen: alles, was inzwischen nicht mehr (suspendiert)
         * in der Tabelle steht, fliegt raus - sonst bliebe ein Geisterhaufen
         * ausgewaehlt, den niemand mehr sieht. Die Namen werden hier neu
         * aufgebaut, damit sie immer zum aktuellen Stand passen.
         */
        function moveAuswahlPrunen(details) {
            const jetzt = new Map();
            (details || []).forEach(function(d) {
                if (d.Identity && /Suspend/i.test(String(d.Status || ''))) {
                    jetzt.set(d.Identity, d.DisplayName || d.Identity);
                }
            });

            moveAuswahl.forEach(function(id) {
                if (!jetzt.has(id)) moveAuswahl.delete(id);
            });

            moveAuswahlNamen.clear();
            moveAuswahl.forEach(function(id) { moveAuswahlNamen.set(id, jetzt.get(id)); });
        }

        /**
         * Leiste, Zaehler und Schalter neu bewerten.
         */
        function moveAuswahlAktualisieren() {
            const leiste   = document.getElementById('moveAuswahlLeiste');
            const schalter = document.getElementById('moveAuswahlSchalter');
            const aufheben = document.getElementById('moveAuswahlAufhebenSchalter');
            const zahl     = document.getElementById('moveAuswahlZahl');
            const alleKast = document.getElementById('moveAlleAuswahl');
            const kisten   = document.querySelectorAll('#tabellenBody input[data-identity]');

            if (!leiste || !schalter || !aufheben || !zahl || !alleKast) return;

            // Ohne auswaehlbare Zeilen ist die Leiste nur Googeld.
            leiste.style.display = kisten.length > 0 ? 'flex' : 'none';

            const anzahl = moveAuswahl.size;
            schalter.disabled = (anzahl === 0) || versandLaueuft;
            aufheben.disabled = (anzahl === 0) || versandLaueuft;
            zahl.textContent   = anzahl + ' ausgewählt';

            // "Alle sichtbaren" nur haekchen, wenn tatsaechlich alle
            // sichtbaren ausgewaehlt sind.
            let sichtbar     = 0;
            let sichtbarDrin = 0;
            kisten.forEach(function(k) {
                if (k.closest('tr').style.display === 'none') return;
                sichtbar++;
                if (moveAuswahl.has(k.dataset.identity)) sichtbarDrin++;
            });
            alleKast.checked = (sichtbar > 0 && sichtbarDrin === sichtbar);
        }

        /** Abgeschlossene Anforderungen EINES Batches entfernen. */
        function loescheAbgeschlossene(batch) {
            moveAktionStarten('Entfernen', batch, false,
                TXT('confirmDeleteBatch').replace('%Batch%', batch));
        }

        /** ALLE abgeschlossenen Anforderungen entfernen. */
        function alleAbgeschlossenenLoeschen() {
            moveAktionStarten('Entfernen', '', true,
                TXT('confirmDeleteAll'));
        }

        /**
         * Status der Verschiebeauftraege abrufen (Selbstkorrigierende Kette).
         */
        async function statusAbfragen() {
            try {
                const response = await fetch('/api/move-status', { cache: 'no-store' });
                if (!response.ok) throw new Error('HTTP ' + response.status);

                const daten      = await response.json();
                const auftraege  = daten.Auftraege || [];

                statusFehler = 0;
                if (auftraege.length > 0) statusZeichnen(auftraege);

                const laeuft = auftraege.some(function(a) { return a.Status === 'Running'; });

                if (laeuft) {
                    statusZeitgeber = setTimeout(statusAbfragen, 3000);
                } else {
                    statusZeitgeber = null;
                    // Nur bei echten Auftraegen neu laden - sonst wuerde ein
                    // leerer Statusabruf beim Seitenstart die Postfachliste
                    // zuruecksetzen.
                    if (auftraege.length > 0) benutzerLaden();
                }
            } catch (fehler) {
                statusFehler++;
                if (statusFehler <= 20) {
                    statusZeitgeber = setTimeout(statusAbfragen, 8000);
                } else {
                    statusZeitgeber = null;
                    zeigeVersandMeldung(TXT('statusQueryFailed').replace('%Message%', escapeHtml(fehler.message)), true);
                }
            }
        }

        function statusAbfragenStarten() {
            if (statusZeitgeber) clearTimeout(statusZeitgeber);
            statusFehler = 0;
            statusZeitgeber = setTimeout(statusAbfragen, 1500);
        }

        /**
         * Auftragsstand darstellen: Kopfzeile pro Auftrag, Fehler im Detail.
         */
        function statusZeichnen(auftraege) {
            let fehlerhaft = false;
            auftraege.forEach(function(a) {
                if (a.Status === 'Failed' || a.Fehler > 0) fehlerhaft = true;
            });

            let html = '';

            auftraege.slice(0, 10).forEach(function(a) {
                const laeuft    = (a.Status === 'Running');
                const kopfFarbe = laeuft ? '#0078d4' : (a.Status === 'Completed' && a.Fehler === 0 ? '#28a745' : '#dc3545');
                // Ohne Art liegt ein Auftrag aus alter Version vor - dann
                // gilt wie bisher 'Verschiebung'.
                const art       = a.Art || 'Verschiebung';
                const aktion    = (art === 'Resume' || art === 'Entfernen');

                // Kopfzeile: Verschiebung zeigt Quelle/Ziel/Modus/Prioritaet,
                // Aktionen nur, was sie tun (fortsetzen bzw. entfernen).
                let kopfText;
                if (aktion) {
                    kopfText = ' – ' + escapeHtml(a.Erstellt) + '/' + escapeHtml(a.Gesamt) +
                        (art === 'Resume'
                            ? ' ' + TXT('resumeDone')
                            : ' ' + TXT('removeDone')) +
                        ', ' + escapeHtml(a.Fehler) + ' ' + TXT('errors');
                } else {
                    kopfText = ' – ' + escapeHtml(a.Erstellt) + '/' + escapeHtml(a.Gesamt) + ' ' + TXT('moveRequestsCreated') +
                        ', ' + escapeHtml(a.Fehler) + ' ' + TXT('errors') +
                        ' | ' + escapeHtml(a.Quelle) + ' &#8594; ' + escapeHtml(a.Ziel) +
                        (a.Suspend ? ' | ' + TXT('suspendBeforeComplete') : ' | ' + TXT('migrateThrough')) +
                        (a.Prioritaet ? ' | ' + TXT('priorityLabel').replace('%Value%', escapeHtml(a.Prioritaet)) : '') +
                        (a.BadItemLimit ? ' | ' + TXT('badItemsLabel').replace('%Value%', escapeHtml(a.BadItemLimit)) : '') +
                        (a.Vorabtest && a.Vorabtest !== 'aus'
                            ? ' | WhatIf: ' + (a.Vorabtest === 'nur' ? TXT('whatIfOnly') : TXT('whatIfCheckMove'))
                            : '');
                }

                const statusAnzeige = a.Status === 'Running' ? TXT('statusRunning')
                                  : (a.Status === 'Completed' ? TXT('statusCompleted')
                                  : (a.Status === 'Failed' ? TXT('statusFailed')
                                  : a.Status));

                html += '<div style="margin-top:6px;">' +
                    '<strong style="color:' + kopfFarbe + ';">#' + escapeHtml(a.Id) + ' ' +
                        escapeHtml(statusAnzeige) + '</strong>' +
                    kopfText +
                    (a.BatchName ? ' | ' + TXT('batchLabel').replace('%Value%', escapeHtml(a.BatchName)) : '') +
                    ' | ' + TXT('startLabel').replace('%Value%', escapeHtml(a.Start)) +
                    '</div>';

                if (a.Meldung) {
                    html += '<div>' + escapeHtml(a.Meldung) + '</div>';
                }

                (a.Ergebnis || []).forEach(function(e) {
                    if (e.Ok) return;
                    html += '<div style="color:#a71d2a;">&#10007; ' +
                        escapeHtml(e.Benutzer) + ': ' + escapeHtml(e.Meldung) + '</div>';
                });

                // Nachziehen: pro Verschiebeanforderung suspendierte
                // fortsetzen (nur im Suspend-Modus) und abgeschlossene
                // entfernen. Die Batch-Id steckt im data-Attribut - so
                // muss der Name nicht in den onclick-Text escapt werden.
                if (art === 'Verschiebung') {
                    let knoepfe = '';
                    if (a.Suspend) {
                        knoepfe += '<button type="button" class="mini-schalter auftrag-knopf" ' +
                            'data-batch="' + escapeHtml(a.BatchName) + '" ' +
                            'onclick="resumeAbschliessen(this.dataset.batch)">' +
                            '&#8635; ' + TXT('resumeSuspended') + '</button>';
                    }
                    knoepfe += '<button type="button" class="mini-schalter auftrag-knopf" ' +
                        'data-batch="' + escapeHtml(a.BatchName) + '" ' +
                        'onclick="loescheAbgeschlossene(this.dataset.batch)">' +
                        '&#10005; ' + TXT('deleteCompleted') + '</button>';
                    html += '<div class="auftrag-knoepfe">' + knoepfe + '</div>';
                }
            });

            zeigeVersandMeldung(html, fehlerhaft);
        }

        // ================================================================
        // Countdown-Balken animieren
        // ================================================================
        function countdownStarten() {
            verbleibendeZeit = INTERVALL;
            const bar = document.getElementById('countdownBar');

            if (countdownTimer) clearInterval(countdownTimer);

            countdownTimer = setInterval(function() {
                verbleibendeZeit -= 1;
                const prozent = Math.max(0, (verbleibendeZeit / INTERVALL) * 100);
                bar.style.width = prozent + '%';
                if (verbleibendeZeit <= 0) clearInterval(countdownTimer);
            }, 1000);
        }

        // ================================================================
        // NEU: Selbstkorrigierendes Polling
        // ================================================================
        // setInterval feuert nach einer festen Zeit, egal ob der vorherige
        // Abruf fertig war. Bei langsamen Antworten stapelten sich dadurch
        // Requests ohne Limit (das war einer der Auslöser für den Totalausfall).
        // Diese Kette plant den nächsten Abruf erst NACH Ende des aktuellen.
        async function planenNaechstenAbruf() {
            await datenAbrufen();
            countdownStarten();
            pollTimer = setTimeout(planenNaechstenAbruf, INTERVALL * 1000);
        }

        // ================================================================
        // Server stoppen
        // ================================================================
        async function stopServer() {
            if (confirm(TXT('confirmStop'))) {
                if (pollTimer) clearTimeout(pollTimer);
                try {
                    await fetch('/api/stop');
                    liveAnzeigen('#dc3545', TXT('stopped'));
                    alert(TXT('serverStopped'));
                } catch (e) {
                    alert(TXT('serverStoppedDisconnected'));
                }
            }
        }

        // ================================================================
        // Initialisierung
        // ================================================================
        (function() {
            document.getElementById('ladeOverlay').style.display = 'flex';
            document.getElementById('ladeText').textContent = TXT('loadingStart');
            document.getElementById('ladeZahl').textContent = '';
            liveAnzeigen('#6c757d', TXT('start'));
            // Verschiebeanforderung vorbereiten: Datenbanken, Postfaecher
            // (ohne Quell-DB = alle) und Hinweistext
            modusGeaendert();
            datenbankenLaden();
            benutzerLaden();
            // Laufende Verschiebeauftraege nach einem Reload wieder anzeigen
            statusAbfragenStarten();
            // Erster Abruf über die Kette, nicht über setInterval
            pollTimer = setTimeout(planenNaechstenAbruf, 0);
        })();
    </script>

</body>
</html>
"@

    # Alle {{key}}-Platzhalter durch die lokalisierten Texte ersetzen
    return Resolve-SprachPlatzhalter -Text $HTML -SprachCode $SprachCode
}

# ============================================================================
# Region: Update-Check (GitLab Releases) - v2.15
# ============================================================================
# Fragt die GitLab-Releases-API nach der neuesten Version. Der Check laeuft
# asynchron in einem eigenen Runspace (wie bei der Hyper-V-Documentation):
# die Webserver-Startphase und das Polling werden nie blockiert. Offline,
# Proxy-Sperren und TLS-Probleme bleiben folgenlos - ein Dashboard muss
# auch ohne Internet laufen. Abschaltbar mit -KeinUpdateCheck.

$script:GitLabProjectId = '87363090'
$script:UpdateCheckUrl  = "https://gitlab.com/api/v4/projects/$($script:GitLabProjectId)/releases?per_page=1&order_by=released_at&sort=desc"

# Laufender Runspace-Task und dessen Auswertung (wird vom /api/data-Handler
# bei jedem Poll nicht-blockierend abgeholt).
$script:UpdateCheckTask = $null
$script:UpdateStatus    = [PSCustomObject]@{
    LatestTag       = $null
    Url             = $null
    UpdateAvailable = $false
    Geprueft        = $false
}

function Start-UpdateCheckAsync {
    <#
    .SYNOPSIS>
        Startet den Update-Check in einem eigenen Runspace, damit weder
        Serverstart noch das Frontend-Polling auf das Netzwerk warten.
    .NOTES>
        Das Skriptblock-Laeufwerk kennt die Hilfsfunktionen nicht - alles
        wird per Argument uebergeben und das Ergebnis per EndInvoke geholt
        (Update-UpdateCheckStatus pollt nicht-blockierend).
    .OUTPUTS>
        PSCustomObject: Handle (IAsyncResult), PowerShell (Instanz zum Aufraeumen)
    #>
    $aktuelleVersion = "v$(Get-SkriptVersion)"
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($url, $currentTag)
        $out = [PSCustomObject]@{ LatestTag = $null; Url = $null; UpdateAvailable = $false }
        try {
            # Windows PowerShell 5.1 waere sonst nur mit TLS 1.0/1.1 dabei
            [Net.ServicePointManager]::SecurityProtocol =
                [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            # Bis zu 3 Versuche mit kurzer Pause: GitLab liefert gelegentlich
            # 503/Timeout zurueck - das Resultat landet im eigenen Runspace,
            # der Server wartet nicht darauf
            $latest = $null
            for ($attempt = 1; $attempt -le 3 -and -not $latest; $attempt++) {
                if ($attempt -gt 1) { Start-Sleep -Milliseconds 750 }
                try { $latest = Invoke-RestMethod -Uri $url -TimeoutSec 3 -ErrorAction Stop | Select-Object -First 1 } catch { }
            }
            if ($latest) {
                $out.LatestTag = [string]$latest.tag_name
                if ($latest._links -and $latest._links.self) { $out.Url = [string]$latest._links.self }
                # Nur die Ziffern vergleichen: [version]'v2.1' wirft eine
                # Ausnahme - sonst bliebe UpdateAvailable immer $false
                $newVer = if ($out.LatestTag -match '(?<ver>\d+(?:\.\d+)*)') { [version]$matches['ver'] } else { $null }
                $curVer = if ($currentTag -match '(?<ver>\d+(?:\.\d+)*)') { [version]$matches['ver'] } else { $null }
                if ($newVer -and $curVer -and $newVer -gt $curVer) { $out.UpdateAvailable = $true }
            }
        } catch { }
        return $out
    }).AddArgument($script:UpdateCheckUrl).AddArgument($aktuelleVersion)
    return [PSCustomObject]@{ Handle = $ps.BeginInvoke(); PowerShell = $ps }
}

function Update-UpdateCheckStatus {
    <#
    .SYNOPSIS>
        Holt das Ergebnis des Update-Check-Runs nicht-blockierend ab und
        schreibt bei gefundener neuerer Version einen Log-Hinweis.
    .NOTES>
        Wird bei jedem /api/data-Aufruf aufgerufen. Erst wenn das Ergebnis
        vorliegt (Geprueft), geschieht nichts mehr - der Log-Eintrag entsteht
        also genau einmal.
    #>
    if ($null -eq $script:UpdateCheckTask -or $script:UpdateStatus.Geprueft) { return }

    $task = $script:UpdateCheckTask
    if (-not $task.Handle.IsCompleted) { return }

    try {
        $info = @($task.PowerShell.EndInvoke($task.Handle)) | Select-Object -First 1
        if ($info) {
            $script:UpdateStatus.LatestTag       = $info.LatestTag
            $script:UpdateStatus.Url             = $info.Url
            $script:UpdateStatus.UpdateAvailable = [bool]$info.UpdateAvailable
        }
    }
    catch { }
    finally {
        try { $task.PowerShell.Dispose() } catch { }
        $script:UpdateCheckTask = $null
        $script:UpdateStatus.Geprueft = $true
    }

    if ($script:UpdateStatus.UpdateAvailable) {
        Write-Log -Nachricht (TM 'log.updateAvailable' @{
            Tag     = $script:UpdateStatus.LatestTag
            Version = (Get-SkriptVersion)
            Url     = $script:UpdateStatus.Url
        }) -Typ "INFO"
    }
    else {
        Write-Log -Nachricht (TM 'log.updateNone' @{ Version = (Get-SkriptVersion) }) -Typ "INFO"
    }
}

# ============================================================================
# Region: Hauptskript – HTTP-Server starten
# ============================================================================

try {
    # --- Log-Verzeichnis erstellen und Log-Stream öffnen -------------------
    if (-not (Test-Path -Path $LogVerzeichnis)) {
        New-Item -ItemType Directory -Path $LogVerzeichnis -Force | Out-Null
        Write-Log -Nachricht (TM 'log.logDirCreated' @{ Path = $LogVerzeichnis }) -Typ "INFO"
    }
    Open-Log

    Write-Log -Nachricht (TM 'log.startBanner') -Typ "INFO"
    Write-Log -Nachricht (TM 'log.intervals' @{
        Interval = $AktualisierungsIntervall
        Cache    = $CacheIntervall
        Timeout  = $AbfrageTimeout
        Idle     = $LeerlaufIntervall
    }) -Typ "INFO"
    if ($BatchName) { Write-Log -Nachricht (TM 'log.batchFilter' @{ Batch = $BatchName }) -Typ "INFO" }
    if ($Light) {
        Write-Log -Nachricht (TM 'log.lightMode') -Typ "INFO"
    }

    # --- Erhoehte Rechte? Selber mit RunAs neu starten (v2.14) --------------
    # System- und Arbitration-Postfaecher brauchen das erhoehte Token: ohne
    # UAC bleiben privilegierte Gruppen im Token auf "deny-only", und der
    # Mailbox Replication Service antwortet auf jeden Versuch mit "Der
    # Zugriff wurde verweigert". Deshalb startet das Skript sich ohne
    # Admin-Rechte einmal mit UAC elevated neu - alle uebergebenen Parameter
    # gehen mit. Lehnt der Nutzer die UAC-Frage ab, laeuft es ohne
    # Erhoehung weiter: Warnung im Log plus Hinweisdialog.
    if (-not (Test-IstAdministrator)) {
        if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
            Write-Log -Nachricht (TM 'log.noAdminNoPath') -Typ "WARNUNG"
        }
        else {
            $ElevationsArgumente = New-ElevationsArgumente -SkriptPfad $PSCommandPath -GebundeneParameter $PSBoundParameters
            try {
                Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                              -Verb RunAs `
                              -ArgumentList $ElevationsArgumente `
                              -ErrorAction Stop
                Write-Log -Nachricht (TM 'log.elevationRequested') -Typ "INFO"
                exit 0
            }
            catch {
                $Abbruch = $false
                if ($_.Exception -is [System.ComponentModel.Win32Exception] -and $_.Exception.NativeErrorCode -eq 1223) {
                    $Abbruch = $true
                }
                elseif ($_.Exception.InnerException -is [System.ComponentModel.Win32Exception] -and $_.Exception.InnerException.NativeErrorCode -eq 1223) {
                    $Abbruch = $true
                }
                if ($Abbruch) {
                    Write-Log -Nachricht (TM 'log.elevationDenied') -Typ "WARNUNG"
                    Show-ElevationsHinweis
                }
                else {
                    Write-Log -Nachricht (TM 'log.elevationFailed' @{ Error = $_.Exception.Message }) -Typ "WARNUNG"
                }
            }
        }
    }

    # --- Laeuft schon eine Instanz auf diesem Port? -------------------------
    # Nur ein HttpListener kann das URL-Praefix belegen. Deshalb wird zuerst
    # per HTTP gefragt, ob dort schon jemand antwortet - das ist der einzige
    # Weg, auch eine in einer offenen Konsole gestartete Instanz zu finden
    # (deren powershell.exe traegt den Skriptnamen nicht in der Kommandozeile).
    # Gefunden wird sauber ueber /api/stop beendet, bevor Zeit in Snap-In und
    # erste Sammlung investiert wird.
    $PruefURL    = "http://localhost:$Port/"
    $PortZustand = Resolve-DashboardPortKonflikt -Port $Port -BasisUrl $PruefURL `
                                                 -Phase "Startpruefung" `
                                                 -KeinAutoStopp:$KeinAutoStopp `
                                                 -MeldeFreieProzesse

    if ($PortZustand -eq "Belegt") {
        Write-Log -Nachricht (TM 'log.otherInstanceKeeps' @{ Url = $PruefURL }) -Typ "FEHLER"
        Write-Log -Nachricht (TM 'log.manualSearch') -Typ "INFO"
        Write-Log -Nachricht (TM 'log.startOtherPort') -Typ "INFO"
        throw "Port $Port ist durch eine andere Dashboard-Instanz belegt."
    }

    if ($PortZustand -eq "OhneStopp") {
        Write-Log -Nachricht (TM 'log.expectedError32') -Typ "WARNUNG"
    }

    # --- Ausfuehrungskontext ins Log (v2.13) ------------------------------
    # Bei Fehlern wie "Der Zugriff wurde verweigert" aus dem Verschiebe-Job
    # muss nachvollziehbar sein, in welchem Konto das Dashboard laeuft:
    # Start-Job startet einen Kindprozess mit demselben Token, der Job
    # laeuft also IMMER in diesem Kontext. Ein Unterschied zur manuellen
    # EMS war ohne diese Angabe nicht sichtbar.
    try {
        $KontextIdent   = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $KontextAdmin   = (New-Object System.Security.Principal.WindowsPrincipal($KontextIdent)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $KontextBitness = if ([Environment]::Is64BitProcess) { '64-Bit' } else { '32-Bit' }
        Write-Log -Nachricht (TM 'log.context' @{
            Name    = $KontextIdent.Name
            Admin   = $KontextAdmin
            Version = $PSVersionTable.PSVersion
            Bitness = $KontextBitness
        }) -Typ "INFO"
    }
    catch { }

    # --- Update-Check starten (v2.15, asynchron) --------------------------
    # Laeuft parallel zur ersten Sammlung und meldet sich erst beim
    # naechsten /api/data-Poll zurück - der Start wird nie blockiert.
    if ($KeinUpdateCheck) {
        Write-Log -Nachricht (TM 'log.updateDisabled') -Typ "INFO"
    }
    else {
        try {
            $script:UpdateCheckTask = Start-UpdateCheckAsync
            Write-Log -Nachricht (TM 'log.updateStarted' @{ Id = $script:GitLabProjectId }) -Typ "INFO"
        }
        catch {
            Write-Log -Nachricht (TM 'log.updateStartFailed' @{ Error = $_.Exception.Message }) -Typ "WARNUNG"
        }
    }

    # --- Exchange PowerShell Snap-in laden (2019 und SE) ---
    # Der Snap-In-Name Microsoft.Exchange.Management.PowerShell.SnapIn ist
    # fuer Exchange Server 2019 und Exchange SE (Subscription Edition)
    # identisch.
    try {
        if (-not (Get-PSSnapin -Name Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction SilentlyContinue)) {
            Write-Log -Nachricht (TM 'log.snapinLoading') -Typ "INFO"
            Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
            Write-Log -Nachricht (TM 'log.snapinLoaded') -Typ "INFO"
        }
        else {
            Write-Log -Nachricht (TM 'log.snapinAlreadyLoaded') -Typ "INFO"
        }
    }
    catch {
        Write-Log -Nachricht (TM 'msg.snapinLoadFailed' @{ Error = $_.Exception.Message }) -Typ "FEHLER"
        throw "Exchange Snap-In konnte nicht geladen werden."
    }

    # --- Erste Datensammlung vor dem Serverstart ---------------------------
    # Dann ist der erste /api/data-Aufruf schnell und der Browser sieht
    # sofort Daten statt eines endlosen Spinners.
    Write-Log -Nachricht (TM 'log.firstCollection') -Typ "INFO"
    $Erststand = Get-MoveRequestDaten
    if ($Erststand -and $Erststand.Gesamt -gt 0) {
        Write-Log -Nachricht (TM 'log.firstCollectionDone' @{
            Count   = $Erststand.Gesamt
            Details = $Erststand.Details.Count
            Seconds = $Erststand.DauerSekunden
        }) -Typ "INFO"
        if ($Erststand.DetailOffen -gt 0) {
            Write-Log -Nachricht (TM 'log.detailsLater' @{ Count = $Erststand.DetailOffen }) -Typ "INFO"
        }
    }

    # --- HTTP-Listener erstellen und starten -------------------------------
    # ZWISCHEN der Startpruefung weiter oben und hier liegen Snap-In und die
    # erste Sammlung (im Praxistest 11 s). Reicht genau diese Zeit, um das
    # URL-Praefix zu verlieren? Genau so ist Fehler 32 entstanden: um
    # 12:00:22 war der Port noch frei, um 12:00:33 hielt eine zweite Instanz
    # das Praefix. Deshalb wird VOR jedem Versuch erneut geprueft und ggf.
    # beendet, und nach einem Fehler 32 einmal nachgelegt. Hoechstens
    # $MaxStartVersuche Versuche - mehr braucht es nicht, und ein
    # Ping-Pong zwischen zwei Instanzen kann so nicht entstehen.
    $MaxStartVersuche = 3
    $StartVersuch     = 0
    $StartFehler      = $null

    while ($true) {
        $StartVersuch++

        # Erneute Pruefung - auch beim ersten Versuch, denn die
        # Startpruefung weiter oben ist inzwischen her.
        $ZustandJetzt = Resolve-DashboardPortKonflikt -Port $Port -BasisUrl $PruefURL `
                                                      -Phase "Startversuch $StartVersuch" `
                                                      -KeinAutoStopp:$KeinAutoStopp
        if ($ZustandJetzt -eq "Belegt") {
            Write-Log -Nachricht (TM 'log.prefixHeld' @{ Url = $BaseURL }) -Typ "WARNUNG"
        }

        try {
            $Listener = New-Object System.Net.HttpListener
            $Listener.Prefixes.Add($BaseURL)

            # Verhindert, dass ein abgebrochener Browser-Request eine Exception
            # in der Schreibpipeline ausloest. Zusammen mit dem finally-Block
            # unten verhindert das die Verbindungslecks.
            $Listener.IgnoreWriteExceptions = $true

            $Listener.Start()
            $StartFehler = $null
            break
        }
        catch {
            $StartFehler = $_.Exception.Message
            $IstPraefixKonflikt = ($StartFehler -match 'anderen Prozess|zugreifen|sharing violation|Access is denied|Zugriff verweigert')

            # Nur bei einem Praefix-Konflikt nachlegen - und nur, wenn
            # ueberhaupt gestoppt werden darf. Ohne Auto-Stopp muesste sich
            # die andere Instanz im Kreis selbst beenden (Ping-Pong).
            if ($IstPraefixKonflikt -and -not $KeinAutoStopp -and $StartVersuch -lt $MaxStartVersuche) {
                Write-Log -Nachricht (TM 'log.serverStartFailed' @{ Error = $StartFehler }) -Typ "FEHLER"
                Write-Log -Nachricht (TM 'log.prefixBusy' @{ Url = $BaseURL; Attempt = $StartVersuch; Max = $MaxStartVersuche }) -Typ "WARNUNG"
                try { $Listener.Close() } catch { }
                continue
            }

            break
        }
    }

    if ($null -eq $StartFehler) {
        Write-Log -Nachricht (TM 'log.serverStarted' @{ Url = $BaseURL }) -Typ "INFO"
        Write-Log -Nachricht (TM 'log.openBrowser' @{ Url = $BaseURL }) -Typ "INFO"
        Write-Log -Nachricht (TM 'log.stopHint') -Typ "INFO"
    }
    else {
        Write-Log -Nachricht (TM 'log.serverStartFailed' @{ Error = $StartFehler }) -Typ "FEHLER"

        # Win32 Fehler 32 = das URL-Praefix ist bereits registriert.
        # DER MOMENT IST ENTSCHEIDEND: ein Port-Check danach findet nichts
        # mehr, denn die gescheiterte Registrierung war sofort wieder frei.
        # Deshalb hier sofort festhalten, was gerade zu sehen war.
        if ($StartFehler -match 'anderen Prozess|zugreifen|sharing violation|Access is denied|Zugriff verweigert') {
            Write-Log -Nachricht (TM 'log.causePrefix' @{ Url = $BaseURL }) -Typ "FEHLER"

            foreach ($Instanz in @(Get-LaufendeDashboardInstanzen)) {
                Write-Log -Nachricht (TM 'log.runningInstanceOnly' @{ Instance = $Instanz }) -Typ "INFO"
            }
            foreach ($Diagnose in @(Get-PortDiagnose -Port $Port)) {
                Write-Log -Nachricht (TM 'log.diagnose' @{ Text = $Diagnose }) -Typ "INFO"
            }

            Write-Log -Nachricht (TM 'log.help1') -Typ "INFO"
            Write-Log -Nachricht (TM 'log.help2') -Typ "INFO"
            Write-Log -Nachricht (TM 'log.help3' @{ Port = $Port }) -Typ "INFO"
        }

        Write-Log -Nachricht (TM 'log.tip') -Typ "INFO"
        Write-Log -Nachricht (TM 'log.netshAcl' @{ Url = $BaseURL; User = "$env:USERDOMAIN\$env:USERNAME" }) -Typ "INFO"
        throw $StartFehler
    }

    # --- Browser automatisch öffnen ---
    if (-not $KeinBrowser) {
        try {
            Start-Process $BaseURL
            Write-Log -Nachricht (TM 'log.browserOpened') -Typ "INFO"
        }
        catch {
            Write-Log -Nachricht (TM 'log.browserFailed') -Typ "WARNUNG"
        }
    }

    # --- Anfragen verarbeiten (Endlos-Schleife) ---
    while ($script:ServerLaeuft) {
        $Antwort = $null

        try {
            $Kontext  = $Listener.GetContext()
            $Anfrage  = $Kontext.Request
            $Antwort  = $Kontext.Response

            $AngefragterPfad = $Anfrage.Url.AbsolutePath

            switch ($AngefragterPfad) {

                "/" {
                    $SprachCode = Get-AnfrageSprache -Anfrage $Anfrage
                    Sende-Antwort -Antwort $Antwort `
                                  -Inhalt (Get-DashboardHTML -SprachCode $SprachCode) `
                                  -ContentType "text/html; charset=utf-8" `
                                  -StatusCode 200
                }

                "/api/data" {
                    # Update-Check-Ergebnis abholen (nicht-blockierend) und
                    # fuer das Frontend-Badge mit ausliefern (v2.15)
                    if (-not $KeinUpdateCheck) { Update-UpdateCheckStatus }

                    $Daten      = Get-MoveRequestDaten
                    $Daten['UpdateVerfuegbar'] = [bool]$script:UpdateStatus.UpdateAvailable
                    $Daten['UpdateTag']        = [string]$script:UpdateStatus.LatestTag
                    $Daten['UpdateUrl']        = [string]$script:UpdateStatus.Url
                    $Daten['UpdateGeprueft']   = [bool]$script:UpdateStatus.Geprueft
                    $JsonInhalt = $Daten | ConvertTo-Json -Depth 5 -Compress
                    Sende-Antwort -Antwort $Antwort `
                                  -Inhalt $JsonInhalt `
                                  -ContentType "application/json; charset=utf-8" `
                                  -StatusCode 200
                }

                "/api/databases" {
                    try {
                        $Datenbanken = Get-DatenbankListe
                        $JsonInhalt  = [pscustomobject]@{ Datenbanken = $Datenbanken } |
                                       ConvertTo-Json -Depth 4 -Compress
                        Sende-Antwort -Antwort $Antwort `
                                      -Inhalt $JsonInhalt `
                                      -ContentType "application/json; charset=utf-8" `
                                      -StatusCode 200
                    }
                    catch {
                        $JsonInhalt = [pscustomobject]@{ Fehler = (TM 'msg.databasesLoadFailed' @{ Error = $_.Exception.Message }) } |
                                       ConvertTo-Json -Compress
                        Sende-Antwort -Antwort $Antwort `
                                      -Inhalt $JsonInhalt `
                                      -ContentType "application/json; charset=utf-8" `
                                      -StatusCode 500
                    }
                }

                "/api/benutzer" {
                    $QuellDatenbank = ""
                    try { $QuellDatenbank = [string]$Anfrage.QueryString["quelle"] } catch { }

                    # Postfachart: benutzer (Standard) | sonder | alle |
                    # archiv. Ein unbekannter Wert faellt bewusst auf
                    # "benutzer" zurueck, damit die Seite auch mit altem
                    # JavaScript noch normal laeuft.
                    $Typ = "benutzer"
                    try {
                        $TypRoh = [string]$Anfrage.QueryString["typ"]
                        if ($TypRoh -in @("benutzer", "sonder", "alle", "archiv")) { $Typ = $TypRoh }
                    }
                    catch { }

                    # Ohne ?quelle= werden ALLE passenden Postfaecher aller
                    # Datenbanken geliefert.
                    try {
                        $Benutzer  = Get-BenutzerListe -QuellDatenbank $QuellDatenbank -Typ $Typ
                        $JsonInhalt = [pscustomobject]@{
                            Quelle          = $QuellDatenbank
                            Typ             = $Typ
                            AlleDatenbanken = [string]::IsNullOrWhiteSpace($QuellDatenbank)
                            Anzahl          = @($Benutzer).Count
                            Benutzer        = $Benutzer
                        } | ConvertTo-Json -Depth 4 -Compress

                        Sende-Antwort -Antwort $Antwort `
                                      -Inhalt $JsonInhalt `
                                      -ContentType "application/json; charset=utf-8" `
                                      -StatusCode 200
                    }
                    catch {
                        $JsonInhalt = [pscustomobject]@{ Fehler = (TM 'msg.mailboxesLoadFailed' @{ Error = $_.Exception.Message }) } |
                                       ConvertTo-Json -Compress
                        Sende-Antwort -Antwort $Antwort `
                                      -Inhalt $JsonInhalt `
                                      -ContentType "application/json; charset=utf-8" `
                                      -StatusCode 500
                    }
                }

                "/api/move" {
                    $Rueckgabe  = @{ Fehler = (TM 'msg.incompleteRequest') }
                    $StatusCode = 400

                    try {
                        if (-not $Anfrage.HasEntityBody) {
                            throw (TM 'msg.noRequestBody')
                        }

                        $Leser   = New-Object System.IO.StreamReader($Anfrage.InputStream, [System.Text.Encoding]::UTF8)
                        $RohText = $Leser.ReadToEnd()
                        $Leser.Close()

                        $Nutzen = $RohText | ConvertFrom-Json

                        $QuelleDB   = [string]$Nutzen.Quelle
                        $ZielDB     = [string]$Nutzen.Ziel
                        $MitSuspend = $false
                        $Adressen   = @()
                        $Prioritaet = "Normal"
                        $Vorabtest  = "aus"
                        $BadItems   = 0

                        if ($Nutzen.PSObject.Properties['Suspend']) { $MitSuspend = [bool]$Nutzen.Suspend }
                        if ($Nutzen.Benutzer) { $Adressen = @($Nutzen.Benutzer | ForEach-Object { [string]$_ }) }

                        # BadItemLimit: Zahl, sonst bleibt 0 (Exchange-Standard)
                        if ($Nutzen.PSObject.Properties['BadItemLimit']) {
                            try { $BadItems = [int]$Nutzen.BadItemLimit } catch { $BadItems = 0 }
                        }

                        # Prioritaet: lateinische Schreibweise bevorzugt,
                        # "Priority" (englisch) ebenfalls toleriert.
                        if ($Nutzen.PSObject.Properties['Prioritaet'] -and -not [string]::IsNullOrWhiteSpace([string]$Nutzen.Prioritaet)) {
                            $Prioritaet = [string]$Nutzen.Prioritaet
                        }
                        elseif ($Nutzen.PSObject.Properties['Priority'] -and -not [string]::IsNullOrWhiteSpace([string]$Nutzen.Priority)) {
                            $Prioritaet = [string]$Nutzen.Priority
                        }

                        # Vorabtest mit -WhatIf: aus / pruefen / nur
                        if ($Nutzen.PSObject.Properties['Vorabtest'] -and -not [string]::IsNullOrWhiteSpace([string]$Nutzen.Vorabtest)) {
                            $Vorabtest = [string]$Nutzen.Vorabtest
                        }

                        $Rueckgabe = Start-Verschiebeauftrag -Quelle $QuelleDB `
                                                              -Ziel $ZielDB `
                                                              -Benutzer $Adressen `
                                                              -MitSuspend $MitSuspend `
                                                              -Prioritaet $Prioritaet `
                                                              -Vorabtest $Vorabtest `
                                                              -BadItemLimit $BadItems |
                                      Select-Object -Last 1

                        # Nur eine Hashtable wird akzeptiert - so bleibt die
                        # Antwort auch dann gueltig, wenn eine Nebenausgabe
                        # (z.B. aus dem Logging) in der Pipeline landet.
                        if ($Rueckgabe -isnot [hashtable]) {
                            $Rueckgabe = @{ Fehler = (TM 'msg.unexpectedShippingResponse') }
                        }

                        if ($Rueckgabe.ContainsKey('Fehler')) { $StatusCode = 400 }
                        else { $StatusCode = 200 }
                    }
                    catch {
                        $Rueckgabe  = @{ Fehler = $_.Exception.Message }
                        $StatusCode = 400
                    }

                    $JsonInhalt = $Rueckgabe | ConvertTo-Json -Depth 5 -Compress
                    Sende-Antwort -Antwort $Antwort `
                                  -Inhalt $JsonInhalt `
                                  -ContentType "application/json; charset=utf-8" `
                                  -StatusCode $StatusCode
                }

                "/api/move-aktion" {
                    $Rueckgabe  = @{ Fehler = (TM 'msg.incompleteRequest') }
                    $StatusCode = 400

                    try {
                        if (-not $Anfrage.HasEntityBody) {
                            throw (TM 'msg.noRequestBody')
                        }

                        $Leser   = New-Object System.IO.StreamReader($Anfrage.InputStream, [System.Text.Encoding]::UTF8)
                        $RohText = $Leser.ReadToEnd()
                        $Leser.Close()

                        $Nutzen = $RohText | ConvertFrom-Json

                        $Aktion = ""
                        $Batch  = ""
                        $Alle   = $false

                        if ($Nutzen.PSObject.Properties['Aktion'])    { $Aktion = [string]$Nutzen.Aktion }
                        if ($Nutzen.PSObject.Properties['BatchName']) { $Batch  = [string]$Nutzen.BatchName }
                        if ($Nutzen.PSObject.Properties['Alle'])      { $Alle   = [bool]$Nutzen.Alle }

                        # Zielwahl: Identities (Array) aus der Mehrfachauswahl
                        # hat Vorrang, sonst die einzelne Identity (v2.4).
                        $IdentListe = @()

                        if ($Nutzen.PSObject.Properties['Identities']) {
                            $IdentListe = @($Nutzen.Identities |
                                ForEach-Object { [string]$_ } |
                                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                        }

                        if ($IdentListe.Count -eq 0 -and $Nutzen.PSObject.Properties['Identity']) {
                            $Einzeln = [string]$Nutzen.Identity
                            if (-not [string]::IsNullOrWhiteSpace($Einzeln)) {
                                $IdentListe = @($Einzeln)
                            }
                        }

                        if ([string]::IsNullOrWhiteSpace($Aktion)) {
                            throw "Keine Aktion angegeben (Resume oder Entfernen)."
                        }

                        $Rueckgabe = Start-MoveAktion -Aktion $Aktion `
                                                      -BatchName $Batch `
                                                      -Alle $Alle `
                                                      -Identity $IdentListe |
                                     Select-Object -Last 1

                        # Nur eine Hashtable wird akzeptiert - so bleibt die
                        # Antwort auch dann gueltig, wenn eine Nebenausgabe
                        # (z.B. aus dem Logging) in der Pipeline landet.
                        if ($Rueckgabe -isnot [hashtable]) {
                            $Rueckgabe = @{ Fehler = (TM 'msg.unexpectedActionResponse') }
                        }

                        if ($Rueckgabe.ContainsKey('Fehler')) { $StatusCode = 400 }
                        else { $StatusCode = 200 }
                    }
                    catch {
                        $Rueckgabe  = @{ Fehler = $_.Exception.Message }
                        $StatusCode = 400
                    }

                    $JsonInhalt = $Rueckgabe | ConvertTo-Json -Depth 5 -Compress
                    Sende-Antwort -Antwort $Antwort `
                                  -Inhalt $JsonInhalt `
                                  -ContentType "application/json; charset=utf-8" `
                                  -StatusCode $StatusCode
                }

                "/api/move-status" {
                    try {
                        $Auftraege  = Get-VersandStatus
                        $JsonInhalt = [pscustomobject]@{ Auftraege = @($Auftraege) } |
                                       ConvertTo-Json -Depth 6 -Compress
                        Sende-Antwort -Antwort $Antwort `
                                      -Inhalt $JsonInhalt `
                                      -ContentType "application/json; charset=utf-8" `
                                      -StatusCode 200
                    }
                    catch {
                        $JsonInhalt = [pscustomobject]@{ Fehler = (TM 'msg.statusLoadFailed' @{ Error = $_.Exception.Message }) } |
                                       ConvertTo-Json -Compress
                        Sende-Antwort -Antwort $Antwort `
                                      -Inhalt $JsonInhalt `
                                      -ContentType "application/json; charset=utf-8" `
                                      -StatusCode 500
                    }
                }

                "/api/stop" {
                    Sende-Antwort -Antwort $Antwort `
                                  -Inhalt '{"status":"Server wird gestoppt..."}' `
                                  -ContentType "application/json; charset=utf-8" `
                                  -StatusCode 200
                    Write-Log -Nachricht (TM 'log.serverStopRequested') -Typ "WARNUNG"
                    $script:ServerLaeuft = $false
                }

                default {
                    Sende-Antwort -Antwort $Antwort `
                                  -Inhalt '{"fehler":"Route nicht gefunden"}' `
                                  -ContentType "application/json; charset=utf-8" `
                                  -StatusCode 404
                }
            }
        }
        catch [System.Net.HttpListenerException] {
            if (-not $script:ServerLaeuft) { break }

            if (Test-BrowserVerbindungsabbruch -Exception $_.Exception) {
                # Der Browser hat die Verbindung zuerst zugeklemmt: Stoppen
                # ueber die Seite, Tab geschlossen oder laufender Poll
                # abgebrochen. Das ist kein Fehler - der Server faehrt hier
                # ohnehin sauber runter, darum gehoert das nicht als WARNUNG
                # ins Log (frueher kam hier "Der angegebene Netzwerkname ist
                # nicht mehr verfuegbar").
                Write-Log -Nachricht (TM 'log.connectionClosed') -Typ "STILL"
            }
            else {
                Write-Log -Nachricht (TM 'log.listenerError' @{ Error = $_.Exception.Message }) -Typ "WARNUNG"
            }
        }
        catch {
            # Abbruch durch den Browser ist normal (Timeout, Tab geschlossen)
            # und darf nicht das Log fluten.
            Write-Log -Nachricht (TM 'log.requestError' @{ Error = $_.Exception.Message }) -Typ "STILL"
        }
        finally {
            # ================================================================
            # Kernaussage: das Close() MUSS hier stehen.
            # Im alten Skript stand es ausserhalb von try/catch. Jeder
            # fehlgeschlagene Request liess die Verbindung offen, und nach
            # etwa zehn Minuten war der Port dicht - das war die Ursache
            # fuer "es kommen keine Daten mehr".
            # ================================================================
            if ($Antwort) {
                try { $Antwort.OutputStream.Close() } catch { }
            }
        }
    }
}
catch {
    Write-Log -Nachricht (TM 'log.critical' @{ Error = $_.Exception.Message }) -Typ "FEHLER"
    Write-Log -Nachricht (TM 'log.stack' @{ Trace = $_.ScriptStackTrace }) -Typ "FEHLER"
    Write-Error (TM 'log.scriptFailed' @{ Path = $LogDateiPfad })
}
finally {
    try {
        if ($Listener -and $Listener.IsListening) {
            $Listener.Stop()
            $Listener.Close()
            Write-Log -Nachricht (TM 'log.serverStopped') -Typ "INFO"
        }
    }
    catch {
        Write-Log -Nachricht (TM 'log.stopFailed' @{ Error = $_.Exception.Message }) -Typ "WARNUNG"
    }

    # Update-Check-Runspace freigeben, falls das Ergebnis noch offen ist.
    if ($script:UpdateCheckTask) {
        try { $script:UpdateCheckTask.PowerShell.Dispose() } catch { }
        $script:UpdateCheckTask = $null
    }

    # Hintergrund-Jobs der Verschiebeanforderungen beenden. Bereits erstellte
    # MoveRequests bleiben in Exchange erhalten - nur die Erstellung
    # noch ausstehender Postfaecher faellt aus.
    try {
        $VersandJobs = Get-Job -Name "WebGUI_Verschiebung", "WebGUI_MoveAktion" -ErrorAction SilentlyContinue
        if ($VersandJobs) {
            $VersandJobs | Remove-Job -Force -ErrorAction SilentlyContinue
            Write-Log -Nachricht (TM 'log.jobsStopped') -Typ "INFO"
        }
    }
    catch {
        Write-Log -Nachricht (TM 'log.jobsStopFailed' @{ Error = $_.Exception.Message }) -Typ "WARNUNG"
    }

    $Laufzeit = [math]::Round(((Get-Date) - $script:StartZeit).TotalMinutes, 1)
    Write-Log -Nachricht (TM 'log.runtime' @{
        Minutes    = $Laufzeit
        Collections = $script:Sammlungen
        Queries     = $script:ExchangeAbfragen
        CacheHits   = $script:CacheTreffer
    }) -Typ "STILL"
    Write-Log -Nachricht (TM 'log.endBanner') -Typ "INFO"

    Close-Log
}
