#!/bin/bash

# === Hostname für den Betreff ===
HOSTNAME=$(hostname)

# === Prüfen, ob Updates verfügbar sind ===
apt update -qq
UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v Listing | wc -l)
PACKAGE_LIST=$(apt list --upgradable 2>/dev/null | grep -v Listing)

# === Snap-Updates prüfen ===
SNAP_LIST=$(snap refresh --list 2>/dev/null | tail -n +2)
SNAP_UPGRADABLE=$(echo "$SNAP_LIST" | wc -l)

if [ "$UPGRADABLE" -eq 0 ] && [ "$SNAP_UPGRADABLE" -eq 0 ]; then
    MAIL_SUBJECT="[${HOSTNAME}] Keine Updates verfügbar"
    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} waren keine Updates verfügbar.\n\nViele Grüße\nDein automatisches Update-Skript"
else
    # Anzahl der Sicherheits- und Kernel-Updates vor Upgrade
    SECURITY_UPGRADES=$(echo "$PACKAGE_LIST" | grep -i security | wc -l)
    KERNEL_UPGRADES=$(echo "$PACKAGE_LIST" | grep -E 'linux-image|linux-headers' | wc -l)

    # === Update & Upgrade ===
    apt -y dist-upgrade > /tmp/apt-upgrade.log 2>&1
    apt -y autoremove > /tmp/apt-autoremove.log 2>&1

    # Paketnamen aus den Logs extrahieren
    UPGRADE_PKGS=$(grep -E "^Setting up|^Preparing to unpack|^Unpacking|^Installing" /tmp/apt-upgrade.log \
        | awk '{print $3}' | sort -u)
    AUTOREMOVE_PKGS=$(grep -E "^Removing" /tmp/apt-autoremove.log | awk '{print $2}' | sort -u)

    # === Snap-Pakete aktualisieren ===
    if [ "$SNAP_UPGRADABLE" -gt 0 ]; then
        SNAP_UPGRADE_LOG=$(snap refresh 2>&1)
    else
        SNAP_UPGRADE_LOG="Keine Snap-Updates installiert."
    fi

    # === Prüfen, ob ein Reboot nötig ist ===
    if [ -f /var/run/reboot-required ]; then
        MAIL_SUBJECT="[${HOSTNAME}] Reboot erforderlich nach Updates"
        REBOOT_MSG="Ein Neustart ist erforderlich, damit alle Änderungen wirksam werden."
    else
        MAIL_SUBJECT="[${HOSTNAME}] Updates installiert"
        REBOOT_MSG="Kein Neustart erforderlich."
    fi

    MAIL_BODY="Hallo,\n\nauf dem Server ${HOSTNAME} wurden Updates durchgeführt.\n\n$REBOOT_MSG\n\nUpdate-Übersicht:\n- Gesamtanzahl APT-Upgrades: $UPGRADABLE\n- Sicherheitsupdates: $SECURITY_UPGRADES\n- Kernel-Updates: $KERNEL_UPGRADES\n- Snap-Updates: $SNAP_UPGRADABLE\n\n=== APT: Verfügbare Updates ===\n$PACKAGE_LIST\n\n=== APT: Installierte / aktualisierte Pakete ===\n$UPGRADE_PKGS\n\n=== APT: Entfernte Pakete (autoremove) ===\n$AUTOREMOVE_PKGS\n\n=== Snap: Aktualisierte Pakete ===\n$SNAP_UPGRADE_LOG\n\n=== Pakete, die Reboot erfordern ===\n$(cat /var/run/reboot-required.pkgs 2>/dev/null)\n\nViele Grüße\nDein automatisches Update-Skript"
fi

# === Mail verschicken ===
echo -e "$MAIL_BODY" \
    | mail -a "Content-Type: text/plain; charset=UTF-8" \
           -a "Content-Transfer-Encoding: 8bit" \
           -s "$MAIL_SUBJECT" root
