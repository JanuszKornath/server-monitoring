#!/bin/bash

# === Hostname für den Betreff ===
HOSTNAME=$(hostname)

# Verzeichnisse
DATA_DIR="/var/lib/smart-summary"
LOG_FILE="/var/log/smart-check.log"
mkdir -p "$DATA_DIR"

MAIL_BODY=$(mktemp)
WARN_BODY=$(mktemp)

# Nur physische Festplatten (ohne Partitions- oder Pseudo-Geräte)
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

# HTML-Header
{
echo "<html><body style='font-family: Arial, sans-serif;'>"
echo "<h2>SMART Summary für $HOSTNAME – $(date)</h2>"
} > "$MAIL_BODY"

CRITICAL_FOUND=0

for DISK in $DISKS; do
    DEVICE="/dev/$DISK"
    OLD_FILE="$DATA_DIR/$DISK.old"
    NEW_FILE="$DATA_DIR/$DISK.new"
    HISTORY_FILE="$DATA_DIR/$DISK.history"

    smartctl -A "$DEVICE" > "$NEW_FILE"

    MANUFACTURER=$(smartctl -i "$DEVICE" | awk -F': +' '/Model Family/ {print $2}')
    MODEL=$(smartctl -i "$DEVICE" | awk -F': +' '/Device Model/ {print $2}')
    POWER_ON_HOURS=$(awk '/Power_On_Hours/ {print $10}' "$NEW_FILE")

    MANUFACTURER=${MANUFACTURER:-"Unbekannt"}
    MODEL=${MODEL:-"Unbekannt"}
    POWER_ON_HOURS=${POWER_ON_HOURS:-0}

    REALLOC=$(awk '/Reallocated_Sector_Ct/ {print $10}' "$NEW_FILE")
    PENDING=$(awk '/Current_Pending_Sector/ {print $10}' "$NEW_FILE")
    OFFLINE=$(awk '/Offline_Uncorrectable/ {print $10}' "$NEW_FILE")
    CRC=$(awk '/UDMA_CRC_Error_Count/ {print $10}' "$NEW_FILE")

    REALLOC=${REALLOC:-0}
    PENDING=${PENDING:-0}
    OFFLINE=${OFFLINE:-0}
    CRC=${CRC:-0}

    echo "<h3>Disk: $DEVICE</h3>" >> "$MAIL_BODY"
    echo "<p><b>Hersteller:</b> $MANUFACTURER<br>" >> "$MAIL_BODY"
    echo "<b>Modell:</b> $MODEL<br>" >> "$MAIL_BODY"
    echo "<b>Laufzeit (Stunden):</b> $POWER_ON_HOURS</p>" >> "$MAIL_BODY"

    echo "<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse;'>" >> "$MAIL_BODY"
    echo "<tr><th>Attribut</th><th>Wert</th><th>Bewertung</th></tr>" >> "$MAIL_BODY"

    IS_CRITICAL=0
    for VAL in REALLOC PENDING OFFLINE CRC; do
        VALUE=${!VAL}
        if [ "$VAL" == "REALLOC" ]; then NAME="Reallocated_Sector_Ct"; THRESHOLD=50
        elif [ "$VAL" == "PENDING" ]; then NAME="Current_Pending_Sector"; THRESHOLD=0
        elif [ "$VAL" == "OFFLINE" ]; then NAME="Offline_Uncorrectable"; THRESHOLD=0
        else NAME="UDMA_CRC_Error_Count"; THRESHOLD=100
        fi

        if [ "$VALUE" -eq 0 ]; then MSG="gut"; COLOR="green"
        elif [ "$VAL" == "REALLOC" ] && [ "$VALUE" -lt 50 ]; then MSG="beobachten"; COLOR="orange"
        elif [ "$VAL" == "CRC" ] && [ "$VALUE" -lt 100 ]; then MSG="beobachten"; COLOR="orange"
        else MSG="kritisch"; COLOR="red"; IS_CRITICAL=1
        fi

        echo "<tr><td>$NAME</td><td>$VALUE</td><td style='color:$COLOR;font-weight:bold;'>$MSG</td></tr>" >> "$MAIL_BODY"
    done

    echo "</table>" >> "$MAIL_BODY"

    if [ "$IS_CRITICAL" -eq 1 ]; then
        CRITICAL_FOUND=1
        echo "<p style='color:red;font-weight:bold;'>!!! WARNUNG: Festplatte $DEVICE zeigt kritische Werte !!!</p>" >> "$MAIL_BODY"

        # Gleiche Infos auch in Warn-Mail (HTML)
        {
        echo "<h3 style='color:red;'>Kritische SMART-Warnung: $DEVICE</h3>"
        echo "<p><b>Hersteller:</b> $MANUFACTURER<br>"
        echo "<b>Modell:</b> $MODEL<br>"
        echo "<b>Laufzeit (Stunden):</b> $POWER_ON_HOURS</p>"
        echo "<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse;'>"
        echo "<tr><th>Attribut</th><th>Wert</th></tr>"
        echo "<tr><td>Reallocated_Sector_Ct</td><td>$REALLOC</td></tr>"
        echo "<tr><td>Current_Pending_Sector</td><td>$PENDING</td></tr>"
        echo "<tr><td>Offline_Uncorrectable</td><td>$OFFLINE</td></tr>"
        echo "<tr><td>UDMA_CRC_Error_Count</td><td>$CRC</td></tr>"
        echo "</table>"
        echo "<p style='color:red;font-weight:bold;'>!!! Sofort prüfen !!!</p><hr>"
        } >> "$WARN_BODY"
    else
        echo "<p style='color:green;'>Status: Alles in Ordnung.</p>" >> "$MAIL_BODY"
    fi

    # Verlauf abspeichern
    echo "$(date +%F) $REALLOC $PENDING $OFFLINE" >> "$HISTORY_FILE"
    tail -n 7 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

    echo "<pre style='background:#f4f4f4; padding:6px;'>" >> "$MAIL_BODY"
    echo "Historie & Trend (letzte 7 Läufe):" >> "$MAIL_BODY"
    awk '{printf "%s  R:%s  P:%s  O:%s\n",$1,$2,$3,$4}' "$HISTORY_FILE" >> "$MAIL_BODY"
    echo "</pre><hr>" >> "$MAIL_BODY"

    mv "$NEW_FILE" "$OLD_FILE"
done

# HTML-Footer
echo "</body></html>" >> "$MAIL_BODY"
echo "</body></html>" >> "$WARN_BODY"

# Zusammenfassung-Mail (immer)
mail -a "Content-Type: text/html; charset=UTF-8" \
     -s "[$HOSTNAME] SMART-Report" root < "$MAIL_BODY"

# Warn-Mail bei kritischen Werten (jetzt auch HTML)
if [ "$CRITICAL_FOUND" -eq 1 ]; then
    mail -a "Content-Type: text/html; charset=UTF-8" \
         -s "[$HOSTNAME] !!! KRITISCHE SMART WARNUNG !!!" root < "$WARN_BODY"
fi

rm "$MAIL_BODY" "$WARN_BODY"
