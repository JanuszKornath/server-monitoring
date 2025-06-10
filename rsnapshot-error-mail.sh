#!/bin/bash

# Konfigurationsdatei und Log-Datei definieren
CONFIG_FILE="/etc/rsnapshot.conf"
LOG_FILE="/var/log/rsnapshot.log"
ERROR_LOG="/var/log/rsnapshot_error.log"

# Backup starten und Standard- sowie Fehlerausgabe in Log-Dateien schreiben
/usr/bin/rsnapshot -c "$CONFIG_FILE" "$1" > "$LOG_FILE" 2> "$ERROR_LOG"
EXIT_CODE=$?

# Wenn rsnapshot einen Fehler hat, sende eine E-Mail mit Details
if [ $EXIT_CODE -ne 0 ]; then
    HOSTNAME=$(hostname)
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

    # E-Mail-Text vorbereiten
    EMAIL_BODY="Fehler bei rsnapshot Backup auf $HOSTNAME am $TIMESTAMP.

Exit-Code: $EXIT_CODE

Fehlermeldungen:
$(cat "$ERROR_LOG")

Letzte 20 Zeilen aus dem Log:
$(tail -n 20 "$LOG_FILE")

Überprüfe die rsnapshot-Konfiguration in: $CONFIG_FILE"

    # E-Mail versenden
    echo "$EMAIL_BODY" | mail -s "rsnapshot Backup-Fehler auf $HOSTNAME" name@host.tld
fi
