#!/bin/bash

HOSTNAME=$(hostname)
# PFAD ZU DOCKER-PROJEKTEN (bitte anpassen!)
DOCKER_DIR="/srv/docker" 

# === APT-Updates prüfen ===
SIM_LOG=$(mktemp)
apt-get -s dist-upgrade > "$SIM_LOG" 2>&1
APT_PENDING=$(grep -c '^Inst ' "$SIM_LOG")
rm -f "$SIM_LOG"

# === Snap-Updates prüfen ===
SNAP_PENDING=0
if command -v snap >/dev/null 2>&1; then
    SNAP_PENDING=$(snap refresh --list | tail -n +2 | wc -l)
fi

# === Docker-Updates prüfen & ausführen ===
DOCKER_UPDATED=0
if command -v docker-compose >/dev/null 2>&1 || docker compose version >/dev/null 2>&1; then
    # Prüfen, ob wir das alte 'docker-compose' oder das neue 'docker compose' nutzen
    DOCKER_CMD="docker compose"
    ! docker compose version >/dev/null 2>&1 && DOCKER_CMD="docker-compose"

    # Gehe durch alle Unterverzeichnisse mit einer docker-compose.yml
    for dir in $(find "$DOCKER_DIR" -maxdepth 2 -name "docker-compose.yml" -exec dirname {} +); do
        cd "$dir" || continue
        
        # Pull neue Images
        PULL_OUTPUT=$($DOCKER_CMD pull -q 2>/dev/null)
        
        # Wenn der Pull Content geliefert hat, gibt es Updates
        if [ -n "$PULL_OUTPUT" ]; then
            # Zähle wie viele Container neu gestartet werden
            UPDATED_IN_THIS_PROJECT=$($DOCKER_CMD up -d | grep -cE 'Started|Recreated|Updated')
            DOCKER_UPDATED=$((DOCKER_UPDATED + UPDATED_IN_THIS_PROJECT))
        fi
    done
fi

# === APT & Snap Updates ausführen ===
APT_INSTALLED=0
SNAP_INSTALLED=0

if [ "$APT_PENDING" -gt 0 ]; then
    apt update -qq
    apt -y dist-upgrade -qq > /dev/null 2>&1
    apt -y autoremove -qq > /dev/null 2>&1
    APT_INSTALLED=$APT_PENDING
fi

if [ "$SNAP_PENDING" -gt 0 ]; then
    snap refresh > /dev/null 2>&1
    SNAP_INSTALLED=$SNAP_PENDING
fi

# === Mail-Logik ===
if [ -f /var/run/reboot-required ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich (Updates installiert)"
    REBOOT_MSG="Ein System-Neustart ist erforderlich."
    UPDATE_DETAILS="APT: $APT_INSTALLED, Snap: $SNAP_INSTALLED, Docker: $DOCKER_UPDATED"

elif [ "$APT_INSTALLED" -gt 0 ] || [ "$SNAP_INSTALLED" -gt 0 ] || [ "$DOCKER_UPDATED" -gt 0 ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
    REBOOT_MSG="Kein Neustart erforderlich."
    UPDATE_DETAILS="Installierte Updates:
- APT Pakete: $APT_INSTALLED
- Snap Pakete: $SNAP_INSTALLED
- Docker Container: $DOCKER_UPDATED"

else
    # Nichts zu tun
    exit 0
fi

# === Mail versenden ===
MAIL_BODY="Hallo,

auf dem Server ${HOSTNAME} wurden Updates durchgeführt.

$REBOOT_MSG

$UPDATE_DETAILS

Viele Grüße
Dein automatisches Update-Skript"

echo -e "$MAIL_BODY" | mail -a "Content-Type: text/plain; charset=UTF-8" -s "$MAIL_SUBJECT" root
