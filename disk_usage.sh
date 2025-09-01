#!/bin/bash

# Schwellenwert für die Festplattenbelegung in Prozent
THRESHOLD=90

# E-Mail-Adresse für die Benachrichtigung
EMAIL="root"

# Log-Datei
LOGFILE="/var/log/disk_usage.log"

# Maximale Anzahl von Sendeversuchen
MAX_RETRIES=3
# Zeit zwischen den Sendeversuchen (in Sekunden)
RETRY_INTERVAL=60

# Pfade setzen, da Crontab oft keine vollständige PATH-Variable hat
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Sicherstellen, dass Sonderzeichen korrekt gehandhabt werden
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Hostname des Servers
HOSTNAME=$(hostname -f)

# Optional: Whitelist & Blacklist
WHITELIST=("/" "/boot" "/var")       # wird immer überwacht, wenn vorhanden
BLACKLIST=("/snap" "/run" "/tmp")    # wird nie überwacht

# Alle relevanten Mountpoints automatisch ermitteln
ALL_MOUNTS=($(df -hP | awk 'NR>1 && $1 !~ /^tmpfs|^udev|^overlay|^loop/ {print $6}'))

# Mountpoints zusammenführen: ALL_MOUNTS + WHITELIST - BLACKLIST
DISKS=()
for MNT in "${ALL_MOUNTS[@]}" "${WHITELIST[@]}"; do
    skip=false
    for BL in "${BLACKLIST[@]}"; do
        if [[ "$MNT" == "$BL" ]]; then
            skip=true
            break
        fi
    done
    if [ "$skip" = false ] && [[ ! " ${DISKS[*]} " =~ " ${MNT} " ]]; then
        DISKS+=("$MNT")
    fi
done

# --- Hauptschleife ---
for DISK in "${DISKS[@]}"; do
    # Festplatteninformationen abrufen (eine Zeile, POSIX-Format)
    DISK_INFO=$(df -hP "$DISK" | tail -n 1)

    # Festplattenstatus ermitteln (in Prozent)
    USAGE=$(echo "$DISK_INFO" | awk '{ print $5 }' | sed 's/%//g')

    # Belegter und Gesamtspeicherplatz
    USED_SPACE=$(echo "$DISK_INFO" | awk '{ print $3 }')
    TOTAL_SPACE=$(echo "$DISK_INFO" | awk '{ print $2 }')

    # Den Mount-Punkt der Festplatte ermitteln
    MOUNT_POINT=$(echo "$DISK_INFO" | awk '{ print $6 }')

    # Sicherstellen, dass die Variablen nicht leer sind
    if [ -z "$USAGE" ] || [ -z "$MOUNT_POINT" ] || [ -z "$USED_SPACE" ] || [ -z "$TOTAL_SPACE" ]; then
        echo "$(date): Fehler beim Abrufen der Informationen für $DISK. Überprüfen Sie den Eintrag." >> "$LOGFILE"
        continue
    fi

    # Prüfen, ob die Festplattenbelegung über dem Schwellenwert liegt
    if [ "$USAGE" -gt "$THRESHOLD" ]; then
        # Nachricht erstellen
        SUBJECT="WARNUNG: Festplattennutzung auf $DISK ($MOUNT_POINT) bei $USAGE%"
        BODY="WARNUNG vom Server '${HOSTNAME}':\n\n"
        BODY+="Die Partition $DISK (gemountet auf $MOUNT_POINT) ist zu ${USAGE}% belegt.\n"
        BODY+="Schwellwert: ${THRESHOLD}%\n\n"
        BODY+="Details:\n"
        BODY+="Belegter Speicher: ${USED_SPACE}\n"
        BODY+="Gesamtspeicher: ${TOTAL_SPACE}\n\n"
        BODY+="Bitte überprüfen Sie den Speicherplatz auf dem Server ${HOSTNAME}.\n"

        # Retry-Mechanismus für das Senden der E-Mail
        for ((i=1; i<=MAX_RETRIES; i++)); do
            # Mail an root senden, Postfix leitet über /etc/aliases weiter
            (
            echo "To: $EMAIL"
            echo "From: root@$HOSTNAME"
            echo "Subject: $SUBJECT"
            echo "Content-Type: text/plain; charset=UTF-8"
            echo
            echo -e "$BODY"
            ) | sendmail -t

            if [ $? -eq 0 ]; then
                echo "$(date): E-Mail erfolgreich gesendet. Partition $DISK ($MOUNT_POINT) ist zu ${USAGE}% belegt." >> "$LOGFILE"
                break
            else
                echo "$(date): Fehler beim Senden der E-Mail. Versuch $i von $MAX_RETRIES." >> "$LOGFILE"
                if [ "$i" -lt "$MAX_RETRIES" ]; then
                    sleep "$RETRY_INTERVAL"
                fi
            fi
        done
    else
        echo "$(date): Festplattennutzung auf $DISK ($MOUNT_POINT) bei ${USAGE}% - keine E-Mail gesendet." >> "$LOGFILE"
    fi
done
