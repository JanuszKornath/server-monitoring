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
BLACKLIST=("/snap" "/run" "/tmp" "/etc/pve" "/sys/firmware/efi/efivars")    # wird nie überwacht

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

# Ermittelt die physischen Datenträger, auf denen ein Gerät liegt.
# LVM-/dm-Ebenen werden dabei aufgelöst: /dev/mapper/pbs-root -> /dev/sda.
# Liefert nichts, wenn lsblk fehlt oder das Gerät kein Blockgerät ist
# (z. B. bei ZFS, NFS oder FUSE-Mounts).
get_physical_disks() {
    local device="$1"
    command -v lsblk >/dev/null 2>&1 || return 0
    [ -b "$device" ] || return 0
    lsblk -nsro NAME,TYPE "$device" 2>/dev/null \
        | awk '$2 == "disk" { print "/dev/" $1 }' \
        | sort -u | paste -sd ", " -
}

# Bereits gemeldete Mountpoints, um Dubletten zu vermeiden
SEEN_MOUNTS=()

# --- Hauptschleife ---
for MOUNT in "${DISKS[@]}"; do
    # Informationen zum Mountpoint abrufen (eine Zeile, POSIX-Format mit Typ)
    DISK_INFO=$(df -hPT "$MOUNT" | tail -n 1)

    # Spalten: Filesystem Type Size Used Avail Use% Mounted-on
    DEVICE=$(echo "$DISK_INFO" | awk '{ print $1 }')
    FSTYPE=$(echo "$DISK_INFO" | awk '{ print $2 }')
    TOTAL_SPACE=$(echo "$DISK_INFO" | awk '{ print $3 }')
    USED_SPACE=$(echo "$DISK_INFO" | awk '{ print $4 }')
    FREE_SPACE=$(echo "$DISK_INFO" | awk '{ print $5 }')
    USAGE=$(echo "$DISK_INFO" | awk '{ print $6 }' | sed 's/%//g')
    # Mountpoints dürfen Leerzeichen enthalten, daher alle Restfelder anhängen
    MOUNT_POINT=$(echo "$DISK_INFO" | awk '{ for (i=7; i<=NF; i++) printf "%s%s", $i, (i<NF ? " " : "") }')

    # Sicherstellen, dass die Variablen nicht leer sind
    if [ -z "$USAGE" ] || [ -z "$MOUNT_POINT" ] || [ -z "$DEVICE" ] || [ -z "$USED_SPACE" ] || [ -z "$TOTAL_SPACE" ]; then
        echo "$(date): Fehler beim Abrufen der Informationen für $MOUNT. Überprüfen Sie den Eintrag." >> "$LOGFILE"
        continue
    fi

    # Whitelist-Einträge, die kein eigener Mountpoint sind (z. B. /var auf /),
    # lösen über df auf denselben Mountpoint auf - jeden nur einmal melden
    if [[ " ${SEEN_MOUNTS[*]} " == *" ${MOUNT_POINT} "* ]]; then
        continue
    fi
    SEEN_MOUNTS+=("$MOUNT_POINT")

    # Physische Datenträger hinter dem Gerät ermitteln
    PHYSICAL_DISKS=$(get_physical_disks "$DEVICE")

    # Prüfen, ob die Belegung über dem Schwellenwert liegt
    if [ "$USAGE" -gt "$THRESHOLD" ]; then
        # Nachricht erstellen
        SUBJECT="WARNUNG: $MOUNT_POINT ($DEVICE) auf $HOSTNAME zu $USAGE% belegt"
        BODY="WARNUNG vom Server '${HOSTNAME}':\n\n"
        BODY+="Der Mountpoint ${MOUNT_POINT} ist zu ${USAGE}% belegt.\n"
        BODY+="Schwellwert: ${THRESHOLD}%\n\n"
        BODY+="Details:\n"
        BODY+="Gerät:             ${DEVICE}\n"
        if [ -n "$PHYSICAL_DISKS" ] && [ "$PHYSICAL_DISKS" != "$DEVICE" ]; then
            BODY+="Datenträger:       ${PHYSICAL_DISKS}\n"
        fi
        BODY+="Dateisystem:       ${FSTYPE}\n"
        BODY+="Belegter Speicher: ${USED_SPACE}\n"
        BODY+="Freier Speicher:   ${FREE_SPACE}\n"
        BODY+="Gesamtspeicher:    ${TOTAL_SPACE}\n\n"
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
                echo "$(date): E-Mail erfolgreich gesendet. $MOUNT_POINT ($DEVICE) ist zu ${USAGE}% belegt." >> "$LOGFILE"
                break
            else
                echo "$(date): Fehler beim Senden der E-Mail. Versuch $i von $MAX_RETRIES." >> "$LOGFILE"
                if [ "$i" -lt "$MAX_RETRIES" ]; then
                    sleep "$RETRY_INTERVAL"
                fi
            fi
        done
    else
        echo "$(date): $MOUNT_POINT ($DEVICE) ist zu ${USAGE}% belegt - keine E-Mail gesendet." >> "$LOGFILE"
    fi
done
