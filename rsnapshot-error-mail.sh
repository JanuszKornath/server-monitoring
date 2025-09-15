#!/bin/bash

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

Letzte 20 Zeilen aus dem Log:
$(tail -n 20 "$LOG_FILE")"

    echo "$EMAIL_BODY" | mail -s "rsnapshot Backup-Fehler ($LEVEL) auf $HOSTNAME" mail@tld.de
fi
