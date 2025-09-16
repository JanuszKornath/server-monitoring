#!/bin/bash

LOG_FILE="/var/log/rsnapshot.log"
STATEFILE="/var/tmp/rsnapshot_check.state"
HOSTNAME=$(hostname)
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Letzten Check-Zeitpunkt laden
LASTRUN=$(cat "$STATEFILE" 2>/dev/null || echo 0)
NOW=$(date +%s)

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

Neue Fehlermeldungen seit letztem Lauf:
$NEW_ERRORS

Letzte 20 Zeilen aus dem Log:
$(tail -n 20 "$LOG_FILE")"

    echo "$EMAIL_BODY" | mail -s "rsnapshot Backup-Fehler auf $HOSTNAME" name@host.tld
fi

# Zeitpunkt merken
echo "$NOW" > "$STATEFILE"