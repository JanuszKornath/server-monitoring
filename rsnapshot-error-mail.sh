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

# Zustand des letzten Laufs: bis zu welcher Zeile geprüft wurde, und eine
# Prüfsumme genau dieser Zeile.
#
# Früher stand hier ein Zeitstempel und es galt "melde Fehler, deren Log-Zeit
# nach dem letzten Lauf liegt". Fiel ein Fehler auf dieselbe Sekunde wie der
# Prüflauf, war er weder davor noch danach und wurde nie gemeldet — bei einem
# Fehlermelder für Backups der denkbar schlechteste Ausgang. Die Position im
# Log kennt diesen Grenzfall nicht: jede Zeile wird genau einmal geprüft.
LASTLINE=0
LASTSIG=""
if [ -f "$STATEFILE" ]; then
    read -r LASTLINE LASTSIG < "$STATEFILE"
    case "$LASTLINE" in ''|*[!0-9]*) LASTLINE=0 ;; esac
fi

TOTAL=$(wc -l < "$LOG_FILE")

# Prüfsumme einer einzelnen Logzeile, leer wenn es die Zeile nicht gibt.
line_signature() {
    [ "$1" -gt 0 ] || return 0
    sed -n "${1}p" "$LOG_FILE" | md5sum | cut -d' ' -f1
}

# Ist es überhaupt noch dasselbe Log? Nach einer Rotation steht an der zuletzt
# geprüften Position etwas anderes. Die reine Zeilenzahl reicht dafür nicht:
# wird das Log geleert und wieder auf dieselbe Länge gefüllt, bliebe die
# Rotation unbemerkt und die Fehler darin würden übersprungen. Die Prüfsumme
# fängt das ab — ebenso den ersten Lauf nach dieser Änderung, weil in der alten
# Zustandsdatei ein Unix-Zeitstempel ohne Prüfsumme steht. Ein solcher Lauf
# meldet die Fehler des aktuellen Logs einmalig erneut: lieber eine Mail zu
# viel als eine zu wenig.
if [ "$LASTLINE" -gt 0 ]; then
    if [ "$TOTAL" -lt "$LASTLINE" ] || [ "$(line_signature "$LASTLINE")" != "$LASTSIG" ]; then
        LASTLINE=0
    fi
fi

# Backup-Level aus dem Log ziehen (letzte "started"-Zeile). Das Feld trägt im
# Log einen Doppelpunkt ("beta:"), der für den Betreff weg muss.
LEVEL=$(tac "$LOG_FILE" | grep -m1 "started" | awk '{print $4}' | tr -d ':' | tr '[:lower:]' '[:upper:]')

# Falls nichts gefunden, Standardwert setzen
if [ -z "$LEVEL" ]; then
    LEVEL="UNKNOWN"
fi

# Nur den seit dem letzten Lauf hinzugekommenen Abschnitt durchsuchen. Die
# Obergrenze ist bewusst $TOTAL und nicht das Dateiende: schreibt rsnapshot
# währenddessen weiter, gehören die neuen Zeilen zum nächsten Lauf.
NEW_ERRORS=$(sed -n "$((LASTLINE + 1)),${TOTAL}p" "$LOG_FILE" | grep "ERROR")

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

# Stand merken: geprüfte Zeilen und Prüfsumme der letzten davon
echo "$TOTAL $(line_signature "$TOTAL")" > "$STATEFILE"
