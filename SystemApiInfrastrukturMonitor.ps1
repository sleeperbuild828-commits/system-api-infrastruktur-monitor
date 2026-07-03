<#
==================================================================================
 Skriptname   : SystemApiInfrastrukturMonitor.ps1
 Projekt      : LB3 - Automatisierter System- & API-Infrastruktur-Monitor
 Beschreibung : Ueberwacht automatisiert (ohne Benutzerinteraktion):
                  1. API-Endpunkte      (HTTP-Statuscode + Antwortzeit)
                  2. Windows-Dienste    (laufen die konfigurierten Dienste?)
                  3. Festplattenplatz   (freier Speicher unter Schwellwert?)
                Jede Pruefung wird als OK / NotOK ins Log-File geschrieben.
                Bei Fehlern wird der Benutzer automatisch per Discord-Webhook
                informiert.
 Konfiguration: monitor_config.json (externes Config-File)
 Start        : Automatisiert via Windows-Aufgabenplaner oder cron (Linux/pwsh)
==================================================================================
#>

# ---------------------------------------------------------------------------
# GLOBALE PFADE
# $PSScriptRoot = Ordner, in dem dieses Skript liegt. Dadurch funktioniert
# das Skript auch, wenn der Aufgabenplaner es aus einem anderen
# Arbeitsverzeichnis startet.
# ---------------------------------------------------------------------------
$konfigDateiPfad = Join-Path $PSScriptRoot "monitor_config.json"
$logOrdnerPfad   = Join-Path $PSScriptRoot "logs"

# ---------------------------------------------------------------------------
# FUNKTION: Write-MonitorLog
# Schreibt eine Zeile ins Tages-Logfile UND auf die Konsole.
# Format: [2026-07-02 14:30:01] [OK]    Nachricht...
# ---------------------------------------------------------------------------
function Write-MonitorLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("OK", "NOTOK", "INFO", "FEHLER")]  # nur erlaubte Status
        [string]$status,

        [Parameter(Mandatory = $true)]
        [string]$nachricht
    )

    # Log-Ordner anlegen, falls er noch nicht existiert
    if (-not (Test-Path $logOrdnerPfad)) {
        New-Item -ItemType Directory -Path $logOrdnerPfad | Out-Null
    }

    # Zeitstempel und Dateiname zusammenbauen (ein Logfile pro Tag)
    $zeitstempel  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logDateiName = "monitor_" + (Get-Date -Format "yyyy-MM-dd") + ".log"
    $logDateiPfad = Join-Path $logOrdnerPfad $logDateiName

    # Status auf feste Breite bringen, damit das Log ausgerichtet ist
    $logZeile = "[$zeitstempel] [$($status.PadRight(6))] $nachricht"

    # -Append haengt die Zeile ans Ende der Datei an
    Add-Content -Path $logDateiPfad -Value $logZeile -Encoding UTF8

    # Farbige Konsolen-Ausgabe (praktisch beim Testen)
    switch ($status) {
        "OK"     { Write-Host $logZeile -ForegroundColor Green }
        "NOTOK"  { Write-Host $logZeile -ForegroundColor Red }
        "FEHLER" { Write-Host $logZeile -ForegroundColor Red }
        default  { Write-Host $logZeile -ForegroundColor Gray }
    }
}

# ---------------------------------------------------------------------------
# FUNKTION: Read-MonitorKonfiguration
# Liest das externe JSON-Config-File ein und gibt es als Objekt zurueck.
# ---------------------------------------------------------------------------
function Read-MonitorKonfiguration {
    if (-not (Test-Path $konfigDateiPfad)) {
        Write-MonitorLog -status "FEHLER" -nachricht "Config-File nicht gefunden: $konfigDateiPfad"
        exit 1   # Exit-Code 1 = Config-Fehler
    }

    try {
        # -Raw = ganze Datei als einen String lesen, dann JSON -> Objekt
        $konfiguration = Get-Content -Path $konfigDateiPfad -Raw | ConvertFrom-Json
        return $konfiguration
    }
    catch {
        Write-MonitorLog -status "FEHLER" -nachricht "Config-File ist kein gueltiges JSON: $($_.Exception.Message)"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# FUNKTION: Test-ApiEndpunkt
# Prueft EINEN API-Endpunkt: erreichbar? Statuscode korrekt? Antwortzeit?
# Gibt ein Resultat-Objekt zurueck, das im Ergebnis-Array gesammelt wird.
# ---------------------------------------------------------------------------
function Test-ApiEndpunkt {
    param(
        [Parameter(Mandatory = $true)] $apiEndpunkt   # ein Eintrag aus der Config
    )

    # Stoppuhr fuer die Antwortzeit-Messung
    $stoppuhr = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # -TimeoutSec verhindert, dass das Skript bei totem Server haengt
        $antwort = Invoke-WebRequest -Uri $apiEndpunkt.url `
                                     -Method Get `
                                     -TimeoutSec $apiEndpunkt.timeoutSekunden `
                                     -UseBasicParsing
        $stoppuhr.Stop()

        $antwortZeitMs = $stoppuhr.ElapsedMilliseconds
        $istStatusOk   = ($antwort.StatusCode -eq $apiEndpunkt.erwarteterStatus)

        if ($istStatusOk) {
            Write-MonitorLog -status "OK" -nachricht "API '$($apiEndpunkt.name)' -> Status $($antwort.StatusCode), Antwortzeit ${antwortZeitMs}ms"
        }
        else {
            Write-MonitorLog -status "NOTOK" -nachricht "API '$($apiEndpunkt.name)' -> Status $($antwort.StatusCode) statt $($apiEndpunkt.erwarteterStatus)"
        }

        return [PSCustomObject]@{
            pruefungsTyp = "API"
            name         = $apiEndpunkt.name
            istOk        = $istStatusOk
            detail       = "Status $($antwort.StatusCode), ${antwortZeitMs}ms"
        }
    }
    catch {
        # Timeout, DNS-Fehler, Verbindung verweigert, 4xx/5xx usw.
        $stoppuhr.Stop()
        Write-MonitorLog -status "NOTOK" -nachricht "API '$($apiEndpunkt.name)' NICHT erreichbar: $($_.Exception.Message)"

        return [PSCustomObject]@{
            pruefungsTyp = "API"
            name         = $apiEndpunkt.name
            istOk        = $false
            detail       = "Nicht erreichbar: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# FUNKTION: Test-SystemDienst
# Prueft, ob ein Windows-Dienst existiert und laeuft ("Running").
# Unter Linux (pwsh) wird die Pruefung uebersprungen.
# ---------------------------------------------------------------------------
function Test-SystemDienst {
    param(
        [Parameter(Mandatory = $true)] [string]$dienstName
    )

    # $IsWindows gibt es nur in PowerShell Core; in Windows PowerShell 5.1
    # ist sie $null -> dann sind wir sicher auf Windows.
    if (($null -ne $IsWindows) -and (-not $IsWindows)) {
        Write-MonitorLog -status "INFO" -nachricht "Dienst-Pruefung '$dienstName' uebersprungen (kein Windows-System)"
        return $null
    }

    try {
        $dienst = Get-Service -Name $dienstName -ErrorAction Stop
        $laeuft = ($dienst.Status -eq "Running")

        if ($laeuft) {
            Write-MonitorLog -status "OK" -nachricht "Dienst '$dienstName' laeuft"
        }
        else {
            Write-MonitorLog -status "NOTOK" -nachricht "Dienst '$dienstName' hat Status '$($dienst.Status)' statt 'Running'"
        }

        return [PSCustomObject]@{
            pruefungsTyp = "Dienst"
            name         = $dienstName
            istOk        = $laeuft
            detail       = "Status: $($dienst.Status)"
        }
    }
    catch {
        Write-MonitorLog -status "NOTOK" -nachricht "Dienst '$dienstName' nicht gefunden"
        return [PSCustomObject]@{
            pruefungsTyp = "Dienst"
            name         = $dienstName
            istOk        = $false
            detail       = "Dienst existiert nicht"
        }
    }
}

# ---------------------------------------------------------------------------
# FUNKTION: Test-Festplattenplatz
# Prueft fuer jedes Laufwerk, ob der freie Platz (%) ueber dem Limit liegt.
# ---------------------------------------------------------------------------
function Test-Festplattenplatz {
    param(
        [Parameter(Mandatory = $true)] [int]$minimalFreiProzent
    )

    # Ergebnis-Array fuer alle Laufwerke
    $laufwerkErgebnisse = @()

    # Nur echte Datentraeger (Used > 0) beruecksichtigen
    $alleLaufwerke = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Used -gt 0 }

    foreach ($laufwerk in $alleLaufwerke) {
        $gesamtBytes = $laufwerk.Used + $laufwerk.Free
        $freiProzent = [math]::Round(($laufwerk.Free / $gesamtBytes) * 100, 1)
        $freiGb      = [math]::Round($laufwerk.Free / 1GB, 1)

        $istGenugPlatz = ($freiProzent -ge $minimalFreiProzent)

        if ($istGenugPlatz) {
            Write-MonitorLog -status "OK" -nachricht "Laufwerk '$($laufwerk.Name)' -> $freiProzent% frei (${freiGb} GB)"
        }
        else {
            Write-MonitorLog -status "NOTOK" -nachricht "Laufwerk '$($laufwerk.Name)' -> nur noch $freiProzent% frei (Limit: $minimalFreiProzent%)"
        }

        # += haengt das neue Resultat-Objekt ans Array an
        $laufwerkErgebnisse += [PSCustomObject]@{
            pruefungsTyp = "Disk"
            name         = "Laufwerk $($laufwerk.Name)"
            istOk        = $istGenugPlatz
            detail       = "$freiProzent% frei (${freiGb} GB)"
        }
    }

    return $laufwerkErgebnisse
}

# ---------------------------------------------------------------------------
# FUNKTION: Send-DiscordBenachrichtigung
# Schickt eine Nachricht an einen Discord-Kanal via Webhook.
# Die Webhook-URL steht NUR im Config-File, nie im Skript!
# ---------------------------------------------------------------------------
function Send-DiscordBenachrichtigung {
    param(
        [Parameter(Mandatory = $true)] [string]$webhookUrl,
        [Parameter(Mandatory = $true)] [string]$nachrichtenText
    )

    # Discord erwartet JSON mit dem Feld "content"
    $anfrageKoerper = @{ content = $nachrichtenText } | ConvertTo-Json

    try {
        # WICHTIG: Body explizit als UTF-8-Bytes senden, sonst lehnt Discord
        # Nachrichten mit Umlauten unter Windows PowerShell 5.1 mit
        # Fehler 400 ab (falsche Standard-Kodierung).
        Invoke-RestMethod -Uri $webhookUrl `
                          -Method Post `
                          -ContentType "application/json" `
                          -Body ([System.Text.Encoding]::UTF8.GetBytes($anfrageKoerper)) | Out-Null
        Write-MonitorLog -status "INFO" -nachricht "Discord-Benachrichtigung erfolgreich versendet"
    }
    catch {
        # Monitor soll trotzdem sauber weiterlaufen -> nur loggen
        Write-MonitorLog -status "FEHLER" -nachricht "Discord-Versand fehlgeschlagen: $($_.Exception.Message)"
    }
}

# ===========================================================================
# HAUPTPROGRAMM
# Ablauf: Config lesen -> alle Pruefungen -> Resultate sammeln
#         -> Zusammenfassung loggen -> bei Fehlern Discord informieren
# ===========================================================================

Write-MonitorLog -status "INFO" -nachricht "===== Monitor-Durchlauf gestartet ====="

# 1) Externes Config-File einlesen
$konfiguration = Read-MonitorKonfiguration

# 2) Ergebnis-Array: hier landen ALLE Pruefresultate
$allePruefErgebnisse = @()

# 2a) Schleife ueber alle API-Endpunkte aus der Config
foreach ($apiEndpunkt in $konfiguration.apiEndpunkte) {
    $allePruefErgebnisse += Test-ApiEndpunkt -apiEndpunkt $apiEndpunkt
}

# 2b) Schleife ueber alle konfigurierten Dienste
foreach ($dienstName in $konfiguration.zuPruefendeDienste) {
    $dienstErgebnis = Test-SystemDienst -dienstName $dienstName
    if ($null -ne $dienstErgebnis) {
        $allePruefErgebnisse += $dienstErgebnis
    }
}

# 2c) Festplattenplatz pruefen (gibt selbst ein Array zurueck)
$allePruefErgebnisse += Test-Festplattenplatz -minimalFreiProzent $konfiguration.minimalFreierPlatzProzent

# 3) Auswertung: fehlgeschlagene Pruefungen herausfiltern
$fehlgeschlagenePruefungen = $allePruefErgebnisse | Where-Object { $_.istOk -eq $false }
$anzahlGesamt              = $allePruefErgebnisse.Count
$anzahlFehler              = @($fehlgeschlagenePruefungen).Count
$anzahlOk                  = $anzahlGesamt - $anzahlFehler

Write-MonitorLog -status "INFO" -nachricht "Zusammenfassung: $anzahlOk von $anzahlGesamt Pruefungen OK, $anzahlFehler NotOK"

# 4) Benachrichtigung nur, wenn mindestens eine Pruefung NotOK ist
if ($anzahlFehler -gt 0) {

    # Discord-Nachricht Zeile fuer Zeile aufbauen
    $nachrichtenZeilen = @()
    $nachrichtenZeilen += ":rotating_light: **Infrastruktur-Monitor: $anzahlFehler Problem(e) gefunden!**"
    $nachrichtenZeilen += "Host: $env:COMPUTERNAME | Zeit: $(Get-Date -Format 'dd.MM.yyyy HH:mm')"

    foreach ($fehlerEintrag in $fehlgeschlagenePruefungen) {
        $nachrichtenZeilen += ":x: [$($fehlerEintrag.pruefungsTyp)] $($fehlerEintrag.name): $($fehlerEintrag.detail)"
    }

    # Array mit Zeilenumbruechen zu einem Text zusammenfuegen
    $discordNachricht = $nachrichtenZeilen -join "`n"

    Send-DiscordBenachrichtigung -webhookUrl $konfiguration.discordWebhookUrl `
                                 -nachrichtenText $discordNachricht

    Write-MonitorLog -status "INFO" -nachricht "===== Monitor-Durchlauf beendet (mit Fehlern) ====="
    exit 2   # Exit-Code 2 = Pruefungen fehlgeschlagen
}
else {
    Write-MonitorLog -status "INFO" -nachricht "===== Monitor-Durchlauf beendet (alles OK) ====="
    exit 0   # Exit-Code 0 = alles in Ordnung
}