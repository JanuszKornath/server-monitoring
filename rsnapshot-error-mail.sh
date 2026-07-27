#!/bin/bash

# ==============================================================================
# Script: rsnapshot-error-mail.sh
# Description: Meldet neue rsnapshot-Fehler per Mail. Gemeldet wird nur, was
#              seit dem letzten Lauf hinzugekommen ist, damit ein einmaliger
#              Fehler nicht bei jedem Lauf erneut verschickt wird.
# ==============================================================================

LOG_FILE="/var/log/rsnapshot.log"
STATEFILE="/var/tmp/rsnapshot_check.state"
# Empfänger. "root" nutzt die Weiterleitung aus /etc/aliases.
EMAIL="root"

HOSTNAME=$(hostname)
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Ohne Log gibt es nichts zu prüfen. Ohne diese Abfrage würde awk bei jedem
# Lauf eine Fehlermeldung an Cron schicken.
[ -f "$LOG_FILE" ] || exit 0

# Letzten Check-Zeitpunkt laden
LASTRUN=$(cat "$STATEFILE" 2>/dev/null || echo 0)
NOW=$(date +%s)

# Backup-Level aus dem Log ziehen (letzte "started"-Zeile). Das Feld trägt im
# Log einen Doppelpunkt ("beta:"), der für den Betreff weg muss.
LEVEL=$(tac "$LOG_FILE" | grep -m1 "started" | awk '{print $4}' | tr -d ':' | tr '[:lower:]' '[:upper:]')

# Falls nichts gefunden, Standardwert setzen
if [ -z "$LEVEL" ]; then
    LEVEL="UNKNOWN"
fi

# Neue Fehler seit letztem Lauf extrahieren
NEW_ERRORS=$(awk -v last="$LASTRUN" -F'[][]' '
    /ERROR/ {
        # Zeitstempel im Log steht zwischen [ ]
        cmd="date -d \"" $2 "\" +%s"
        cmd | getline t
        close(cmd)
        if (t > last) print
    }
' "$LOG_FILE")

# Wenn neue Fehler gefunden → Mail verschicken
if [ -n "$NEW_ERRORS" ]; then
    EMAIL_BODY="Fehler bei rsnapshot Backup auf $HOSTNAME am $TIMESTAMP.

Backup-Level: $LEVEL

Neue Fehlermeldungen seit letztem Lauf:
$NEW_ERRORS

Letzte 20 Zeilen aus dem Log:
$(tail -n 20 "$LOG_FILE")"

    echo "$EMAIL_BODY" | mail -s "rsnapshot Backup-Fehler ($LEVEL) auf $HOSTNAME" "$EMAIL"
fi

# Zeitpunkt merken
echo "$NOW" > "$STATEFILE"
