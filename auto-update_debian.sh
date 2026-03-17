#!/bin/bash

# ==============================================================================
# Script: auto_update.sh
# Description: Automatisches Update-Skript für APT, Snap und Docker.
# ==============================================================================

HOSTNAME=$(hostname)
# Pfad zu Docker-Ordner bitte anpassen!
DOCKER_DIR="/srv/docker"

# === 1. APT-Index aktualisieren (WICHTIG!) ===
apt-get update -qq

# === 2. APT-Updates prüfen ===
SIM_LOG=$(mktemp)
apt-get -s dist-upgrade > "$SIM_LOG" 2>&1
APT_PENDING=$(grep -c '^Inst ' "$SIM_LOG")
rm -f "$SIM_LOG"

# === 3. Snap-Updates prüfen ===
SNAP_PENDING=0
if command -v snap >/dev/null 2>&1; then
    # snap refresh --list gibt bei keinen Updates einen leeren Header oder Fehler aus
    SNAP_PENDING=$(snap refresh --list 2>/dev/null | tail -n +2 | wc -l)
fi

# === 4. Docker-Updates prüfen & ausführen ===
DOCKER_UPDATED=0
if command -v docker >/dev/null 2>&1; then
    DOCKER_CMD=""
    if docker compose version >/dev/null 2>&1; then
        DOCKER_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DOCKER_CMD="docker-compose"
    fi

    if [ -n "$DOCKER_CMD" ]; then        
        for dir in $(find "$DOCKER_DIR" -maxdepth 3 -name "docker-compose.yml" -exec dirname {} +); do
            (
                cd "$dir" || exit                
                $DOCKER_CMD pull > /dev/null 2>&1
                
                # up -d fängt nur Änderungen ab. 
                # Wir loggen die Ausgabe, um zu sehen, ob wirklich was "recreated" wurde.
                UPDATED_INFO=$($DOCKER_CMD up -d 2>&1)
                
                # Prüfen, ob in der Ausgabe 'Recreated' oder 'Started' (bei neuen Images) steht
                if echo "$UPDATED_INFO" | grep -qE 'Recreated|Updated'; then
                    echo "1" > /tmp/docker_changed_flag
                fi
            )
            if [ -f /tmp/docker_changed_flag ]; then
                DOCKER_UPDATED=$((DOCKER_UPDATED + 1))
                rm -f /tmp/docker_changed_flag
            fi
        done
    fi
fi

# === 5. APT & Snap Updates ausführen ===
APT_INSTALLED=0
SNAP_INSTALLED=0

if [ "$APT_PENDING" -gt 0 ]; then
    # Installation der Pakete
    apt-get -y dist-upgrade -qq > /dev/null 2>&1
    apt-get -y autoremove -qq > /dev/null 2>&1
    APT_INSTALLED=$APT_PENDING
fi

if [ "$SNAP_PENDING" -gt 0 ]; then
    snap refresh > /dev/null 2>&1
    SNAP_INSTALLED=$SNAP_PENDING
fi

# === 6. Mail-Logik ===
REBOOT_REQUIRED=0
if [ -f /var/run/reboot-required ]; then
    REBOOT_REQUIRED=1
fi

# Nur Mail senden, wenn etwas passiert ist oder ein Reboot ansteht
if [ "$REBOOT_REQUIRED" -eq 1 ] || [ "$APT_INSTALLED" -gt 0 ] || [ "$SNAP_INSTALLED" -gt 0 ] || [ "$DOCKER_UPDATED" -gt 0 ]; then

    if [ "$REBOOT_REQUIRED" -eq 1 ]; then
        MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich (Updates installiert)"
        REBOOT_MSG="Ein System-Neustart ist erforderlich."
    else
        MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
        REBOOT_MSG="Kein Neustart erforderlich."
    fi

    UPDATE_DETAILS="Installierte Updates:
- APT Pakete: $APT_INSTALLED
- Snap Pakete: $SNAP_INSTALLED
- Docker Container: $DOCKER_UPDATED"

    MAIL_BODY="Hallo,

auf dem Server ${HOSTNAME} wurden Updates durchgeführt.

$REBOOT_MSG

$UPDATE_DETAILS

Viele Grüße
Dein automatisches Update-Skript"

    echo -e "$MAIL_BODY" | mail -a "Content-Type: text/plain; charset=UTF-8" -s "$MAIL_SUBJECT" root
fi

exit 0
