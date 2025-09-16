#!/bin/bash

<<<<<<< HEAD
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
=======
# Konfigurationsdateien und Logs
LOG_FILE="/var/log/rsnapshot.log"
ERROR_LOG="/var/log/rsnapshot_error.log"
HOSTNAME=$(hostname)
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Backup-Level automatisch aus dem Log ziehen
LEVEL=$(tac "$LOG_FILE" | grep -m1 "started" | awk '{print $4}' | tr '[:lower:]' '[:upper:]')

# Falls nichts gefunden, Standardwert setzen
if [ -z "$LEVEL" ]; then
    LEVEL="UNKNOWN"
fi

# Wenn Fehler im Error-Log stehen → Mail verschicken
if [ -s "$ERROR_LOG" ]; then
    EMAIL_BODY="Fehler bei rsnapshot Backup auf $HOSTNAME am $TIMESTAMP.

Backup-Level: $LEVEL

Fehlermeldungen:
$(cat "$ERROR_LOG")
>>>>>>> 81cb2d40df425c8f0920e8167b690c9130ba0fe1

Letzte 20 Zeilen aus dem Log:
$(tail -n 20 "$LOG_FILE")"

<<<<<<< HEAD
    echo "$EMAIL_BODY" | mail -s "rsnapshot Backup-Fehler auf $HOSTNAME" name@host.tld
=======
    echo "$EMAIL_BODY" | mail -s "rsnapshot Backup-Fehler ($LEVEL) auf $HOSTNAME" mail@tld.de
>>>>>>> 81cb2d40df425c8f0920e8167b690c9130ba0fe1
fi

# Zeitpunkt merken
echo "$NOW" > "$STATEFILE"