#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

HOSTNAME=$(hostname)
DATA_DIR="/var/lib/smart-summary"
mkdir -p "$DATA_DIR"

MAIL_BODY=$(mktemp)
DISK_SECTIONS=$(mktemp)
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

# Gesamtstatus über alle Platten hinweg: OK < WARNUNG < KRITISCH
OVERALL_STATUS="OK"
CRITICAL_DISKS=""
WARNING_DISKS=""
PROBLEM_DETAILS=""

# Nicht-numerische Rohwerte (z. B. "1,234" oder "0/0" bei NVMe) würden den
# Zahlenvergleich abbrechen lassen, daher vorher normalisieren.
to_number() {
    local value="${1//,/}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

for DISK in $DISKS; do
    DEVICE="/dev/$DISK"
    HISTORY_FILE="$DATA_DIR/$DISK.history"

    # Daten auslesen
    SMART_INFO=$(smartctl -i "$DEVICE")
    SMART_ATTRS=$(smartctl -A "$DEVICE")
    SMART_HEALTH=$(smartctl -H "$DEVICE")

    # Extraktion (SATA & NVMe Support)
    MANUFACTURER=$(echo "$SMART_INFO" | grep -Ei "Model Family|Vendor" | awk -F': +' '{print $2}')
    MODEL=$(echo "$SMART_INFO" | grep -Ei "Device Model|Product|Model Number" | awk -F': +' '{print $2}' | head -n1)
    POWER_ON_HOURS=$(echo "$SMART_ATTRS" | grep -Ei "Power_On_Hours|Power On Hours" | awk '{print $NF}')

    get_val() {
        echo "$SMART_ATTRS" | grep -i "$1" | awk '{print $NF}' | head -n1
    }

    REALLOC=$(get_val "Reallocated_Sector_Ct")
    PENDING=$(get_val "Current_Pending_Sector")
    OFFLINE=$(get_val "Offline_Uncorrectable")
    CRC=$(get_val "UDMA_CRC_Error_Count")

    # Defaults
    REALLOC=${REALLOC:-0}; PENDING=${PENDING:-0}; OFFLINE=${OFFLINE:-0}; CRC=${CRC:-0}
    MANUFACTURER=${MANUFACTURER:-"Unbekannt"}; MODEL=${MODEL:-"Unbekannt"}

    # --- SMART-Gesamturteil der Platte ---
    # "SMART overall-health self-assessment test result: FAILED!" bzw.
    # "SMART Health Status: FAILURE" ist der deutlichste Hinweis auf einen Defekt.
    DISK_STATUS="OK"
    DISK_ISSUES=""
    HEALTH_LINE=$(echo "$SMART_HEALTH" | grep -Ei "overall-health|SMART Health Status" | head -n1)
    if echo "$HEALTH_LINE" | grep -qEi "FAILED|FAILURE"; then
        DISK_STATUS="KRITISCH"
        DISK_ISSUES="${DISK_ISSUES}<li>SMART-Gesamturteil: <b>FAILED</b></li>"
    fi

    # --- Historie aktualisieren ---
    echo "$(date +%F) $REALLOC $PENDING $OFFLINE" >> "$HISTORY_FILE"
    # Nur die letzten 7 Einträge behalten
    tail -n 7 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

    # HTML Output
    echo "<div style='margin-bottom: 30px; border: 1px solid #ccc; padding: 15px; border-radius: 5px;'>" >> "$DISK_SECTIONS"
    echo "<h3 style='margin-top:0; color:#2980b9;'>Disk: $DEVICE</h3>" >> "$DISK_SECTIONS"
    echo "<p><b>Modell:</b> $MANUFACTURER $MODEL<br><b>Laufzeit:</b> $POWER_ON_HOURS Stunden</p>" >> "$DISK_SECTIONS"

    echo "<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse; width:100%; margin-bottom:15px;'>" >> "$DISK_SECTIONS"
    echo "<tr style='background:#eee;'><th>Attribut</th><th>Wert</th><th>Status</th></tr>" >> "$DISK_SECTIONS"

    for ITEM in "Reallocated_Sectors:$REALLOC:50" "Pending_Sectors:$PENDING:0" "Offline_Uncorrectable:$OFFLINE:0" "UDMA_CRC_Errors:$CRC:100"; do
        IFS=":" read -r NAME VALUE THRESH <<< "$ITEM"
        NUM=$(to_number "$VALUE")
        COLOR="green"; MSG="OK"
        if [ "$NUM" -gt "$THRESH" ]; then COLOR="red"; MSG="KRITISCH"
            DISK_STATUS="KRITISCH"
            DISK_ISSUES="${DISK_ISSUES}<li>$NAME: <b>$VALUE</b> (Schwelle: $THRESH)</li>"
        elif [ "$NUM" -gt 0 ]; then COLOR="orange"; MSG="WARNUNG"
            if [ "$DISK_STATUS" = "OK" ]; then DISK_STATUS="WARNUNG"; fi
            DISK_ISSUES="${DISK_ISSUES}<li>$NAME: $VALUE</li>"
        fi
        echo "<tr><td>$NAME</td><td>$VALUE</td><td style='color:$COLOR; font-weight:bold;'>$MSG</td></tr>" >> "$DISK_SECTIONS"
    done
    echo "</table>" >> "$DISK_SECTIONS"

    # --- Historie-Tabelle ---
    echo "<p><b>Historie (Letzte 7 Läufe):</b></p>" >> "$DISK_SECTIONS"
    echo "<pre style='background:#f8f9fa; padding:10px; border-left:4px solid #3498db; font-family: monospace;'>" >> "$DISK_SECTIONS"
    echo "Datum      | Realloc | Pending | Offline" >> "$DISK_SECTIONS"
    echo "-----------|---------|---------|---------" >> "$DISK_SECTIONS"
    awk '{printf "%s | %7s | %7s | %7s\n", $1, $2, $3, $4}' "$HISTORY_FILE" >> "$DISK_SECTIONS"
    echo "</pre></div>" >> "$DISK_SECTIONS"

    # --- Gesamtstatus fortschreiben ---
    if [ "$DISK_STATUS" = "KRITISCH" ]; then
        OVERALL_STATUS="KRITISCH"
        CRITICAL_DISKS="$CRITICAL_DISKS $DEVICE"
        PROBLEM_DETAILS="${PROBLEM_DETAILS}<div style='margin:5px 0;'><b>$DEVICE</b><ul style='margin:5px 0;'>${DISK_ISSUES}</ul></div>"
    elif [ "$DISK_STATUS" = "WARNUNG" ]; then
        if [ "$OVERALL_STATUS" = "OK" ]; then OVERALL_STATUS="WARNUNG"; fi
        WARNING_DISKS="$WARNING_DISKS $DEVICE"
        PROBLEM_DETAILS="${PROBLEM_DETAILS}<div style='margin:5px 0;'><b>$DEVICE</b><ul style='margin:5px 0;'>${DISK_ISSUES}</ul></div>"
    fi
done

# === Betreff & Kopfzeilen abhängig vom Gesamtstatus ===
case "$OVERALL_STATUS" in
    KRITISCH)
        MAIL_SUBJECT="[$HOSTNAME] SMART KRITISCH:${CRITICAL_DISKS}"
        BANNER_COLOR="#c0392b"; BANNER_BG="#fdecea"
        BANNER_TEXT="KRITISCH – auf folgenden Datenträgern wurden schwerwiegende Fehler erkannt:${CRITICAL_DISKS}"
        ;;
    WARNUNG)
        MAIL_SUBJECT="[$HOSTNAME] SMART Warnung:${WARNING_DISKS}"
        BANNER_COLOR="#b9770e"; BANNER_BG="#fef5e7"
        BANNER_TEXT="WARNUNG – auffällige Werte auf folgenden Datenträgern:${WARNING_DISKS}"
        ;;
    *)
        MAIL_SUBJECT="[$HOSTNAME] SMART-Report"
        BANNER_COLOR="#1e8449"; BANNER_BG="#eafaf1"
        BANNER_TEXT="Alle Datenträger unauffällig."
        ;;
esac

# Header für HTML-Mail
echo "<html><body style='font-family: Arial, sans-serif;'>" > "$MAIL_BODY"
echo "<h2 style='color:#2c3e50;'>SMART Summary für $HOSTNAME – $(date)</h2>" >> "$MAIL_BODY"
echo "<div style='background:$BANNER_BG; border-left:6px solid $BANNER_COLOR; padding:12px; margin-bottom:20px;'>" >> "$MAIL_BODY"
echo "<p style='margin:0; color:$BANNER_COLOR; font-weight:bold; font-size:15px;'>$BANNER_TEXT</p>" >> "$MAIL_BODY"
if [ -n "$PROBLEM_DETAILS" ]; then
    echo "$PROBLEM_DETAILS" >> "$MAIL_BODY"
fi
echo "</div>" >> "$MAIL_BODY"

cat "$DISK_SECTIONS" >> "$MAIL_BODY"
echo "</body></html>" >> "$MAIL_BODY"

# Bei kritischem Befund die Mail zusätzlich als dringend kennzeichnen
MAIL_ARGS=(-a "MIME-Version: 1.0" -a "Content-Type: text/html; charset=UTF-8")
if [ "$OVERALL_STATUS" = "KRITISCH" ]; then
    MAIL_ARGS+=(-a "X-Priority: 1" -a "Importance: High")
fi

mail "${MAIL_ARGS[@]}" -s "$MAIL_SUBJECT" root < "$MAIL_BODY"

rm "$MAIL_BODY" "$DISK_SECTIONS"
