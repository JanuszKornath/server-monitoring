#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

HOSTNAME=$(hostname)
DATA_DIR="/var/lib/smart-summary"
mkdir -p "$DATA_DIR"

MAIL_BODY=$(mktemp)
DISK_SECTIONS=$(mktemp)
DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

# Wie viele Läufe in der Historie vorgehalten werden. Bei täglichem Cron-Lauf
# entspricht das einem Beobachtungsfenster von einer Woche.
HISTORY_RUNS=7

# Gesamtstatus über alle Platten hinweg: OK < HINWEIS < WARNUNG < KRITISCH
OVERALL_STATUS="OK"
CRITICAL_DISKS=""
WARNING_DISKS=""
PROBLEM_DETAILS=""

# Nicht-numerische Rohwerte (z. B. "1,234" bei NVMe oder "0 0 0" bei manchen
# Command_Timeout-Implementierungen) würden den Zahlenvergleich abbrechen lassen.
to_number() {
    local value="${1//,/}"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
    else
        printf '0'
    fi
}

# Spalten der Historie: 1=Datum 2=Realloc 3=Pending 4=Offline 5=CRC
#                       6=Reported_Uncorrect 7=Command_Timeout
# Ältere Historien-Dateien haben nur 4 Spalten; Zeilen ohne die gefragte Spalte
# werden übersprungen, damit die Migration ohne Sonderbehandlung funktioniert.
history_column() {
    awk -v col="$1" 'NF>=col {print $col}' "$HISTORY_FILE"
}

# Zuwachs gegenüber dem ältesten bekannten Wert im Historien-Fenster.
history_growth() {
    local col="$1" current="$2" oldest
    oldest=$(history_column "$col" | head -n1)
    [ -z "$oldest" ] && { echo 0; return 0; }
    echo $(( current - $(to_number "$oldest") ))
}

# Zuwachs gegenüber dem unmittelbar vorhergehenden Lauf.
history_delta_last() {
    local col="$1" current="$2" previous
    previous=$(history_column "$col" | tail -n 2 | head -n 1)
    [ -z "$previous" ] && { echo 0; return 0; }
    echo $(( current - $(to_number "$previous") ))
}

# War der Wert in den letzten N Läufen durchgehend > 0? Liegen weniger als N
# Läufe vor, gilt das bewusst als "nicht bestätigt".
history_persistent() {
    local col="$1" runs="$2" values count value
    values=$(history_column "$col" | tail -n "$runs")
    [ -z "$values" ] && return 1
    count=$(printf '%s\n' "$values" | grep -c .)
    [ "$count" -lt "$runs" ] && return 1
    while IFS= read -r value; do
        [ "$(to_number "$value")" -gt 0 ] || return 1
    done <<< "$values"
    return 0
}

# Status nur anheben, nie herabstufen.
raise_disk_status() {
    case "$1" in
        KRITISCH) DISK_STATUS="KRITISCH" ;;
        WARNUNG)  [ "$DISK_STATUS" != "KRITISCH" ] && DISK_STATUS="WARNUNG" ;;
        HINWEIS)  [ "$DISK_STATUS" = "OK" ] && DISK_STATUS="HINWEIS" ;;
    esac
    return 0
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
    REPORTED=$(get_val "Reported_Uncorrect")
    CMDTIMEOUT=$(get_val "Command_Timeout")

    # Defaults
    REALLOC=${REALLOC:-0}; PENDING=${PENDING:-0}; OFFLINE=${OFFLINE:-0}; CRC=${CRC:-0}
    REPORTED=${REPORTED:-0}; CMDTIMEOUT=${CMDTIMEOUT:-0}
    MANUFACTURER=${MANUFACTURER:-"Unbekannt"}; MODEL=${MODEL:-"Unbekannt"}

    # --- Historie fortschreiben (vor der Bewertung, damit der aktuelle Lauf
    #     bei Zuwachs- und Persistenz-Regeln mitzählt) ---
    echo "$(date +%F) $(to_number "$REALLOC") $(to_number "$PENDING") $(to_number "$OFFLINE") $(to_number "$CRC") $(to_number "$REPORTED") $(to_number "$CMDTIMEOUT")" >> "$HISTORY_FILE"
    tail -n "$HISTORY_RUNS" "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"

    DISK_STATUS="OK"
    DISK_ISSUES=""

    # --- SMART-Gesamturteil der Platte ---
    # "SMART overall-health self-assessment test result: FAILED!" bzw.
    # "SMART Health Status: FAILURE" ist der deutlichste Hinweis auf einen Defekt.
    HEALTH_LINE=$(echo "$SMART_HEALTH" | grep -Ei "overall-health|SMART Health Status" | head -n1)
    if echo "$HEALTH_LINE" | grep -qEi "FAILED|FAILURE"; then
        raise_disk_status KRITISCH
        DISK_ISSUES="${DISK_ISSUES}<li>SMART-Gesamturteil: <b>FAILED</b></li>"
    fi

    # HTML Output
    echo "<div style='margin-bottom: 30px; border: 1px solid #ccc; padding: 15px; border-radius: 5px;'>" >> "$DISK_SECTIONS"
    echo "<h3 style='margin-top:0; color:#2980b9;'>Disk: $DEVICE</h3>" >> "$DISK_SECTIONS"
    echo "<p><b>Modell:</b> $MANUFACTURER $MODEL<br><b>Laufzeit:</b> $POWER_ON_HOURS Stunden</p>" >> "$DISK_SECTIONS"

    echo "<table border='1' cellspacing='0' cellpadding='4' style='border-collapse:collapse; width:100%; margin-bottom:15px;'>" >> "$DISK_SECTIONS"
    echo "<tr style='background:#eee;'><th>Attribut</th><th>Wert</th><th>Status</th></tr>" >> "$DISK_SECTIONS"

    # Medienfehler-Attribute. Felder:
    #   Name : Rohwert : Historien-Spalte : Grenzwert absolut : Grenzwert Zuwachs : Persistenz-Läufe
    # 0 schaltet die jeweilige Regel ab. Alles über 0 ist mindestens WARNUNG;
    # KRITISCH wird erst durch Höhe, Wachstum oder Dauerhaftigkeit ausgelöst.
    for ITEM in \
        "Reallocated_Sectors:$REALLOC:2:50:10:0" \
        "Current_Pending_Sector:$PENDING:3:10:0:3" \
        "Offline_Uncorrectable:$OFFLINE:4:10:0:3" \
        "Reported_Uncorrect:$REPORTED:6:10:5:0" \
        "Command_Timeout:$CMDTIMEOUT:7:10:5:0"; do
        IFS=":" read -r NAME VALUE COL ABS_CRIT GROWTH_CRIT PERSIST_RUNS <<< "$ITEM"
        NUM=$(to_number "$VALUE")
        COLOR="green"; MSG="OK"; REASON=""

        if [ "$NUM" -gt "$ABS_CRIT" ]; then
            REASON="über Grenzwert $ABS_CRIT"
        elif [ "$GROWTH_CRIT" -gt 0 ]; then
            GROWTH=$(history_growth "$COL" "$NUM")
            if [ "$GROWTH" -ge "$GROWTH_CRIT" ]; then
                REASON="Zuwachs +$GROWTH im Historien-Fenster"
            fi
        fi
        if [ -z "$REASON" ] && [ "$PERSIST_RUNS" -gt 0 ] && history_persistent "$COL" "$PERSIST_RUNS"; then
            REASON="in $PERSIST_RUNS Läufen in Folge > 0"
        fi

        if [ -n "$REASON" ]; then
            COLOR="red"; MSG="KRITISCH"
            raise_disk_status KRITISCH
            DISK_ISSUES="${DISK_ISSUES}<li>$NAME: <b>$VALUE</b> ($REASON)</li>"
        elif [ "$NUM" -ge 1 ]; then
            COLOR="orange"; MSG="WARNUNG"
            raise_disk_status WARNUNG
            DISK_ISSUES="${DISK_ISSUES}<li>$NAME: $VALUE (beobachten)</li>"
        fi
        echo "<tr><td>$NAME</td><td>$VALUE</td><td style='color:$COLOR; font-weight:bold;'>$MSG</td></tr>" >> "$DISK_SECTIONS"
    done

    # UDMA_CRC_Error_Count ist kein Medienfehler, sondern ein Übertragungsfehler
    # auf dem SATA-Bus (Kabel, Stecker, Backplane). Der Zähler wird nie
    # zurückgesetzt, ein alter Wackelkontakt steht also dauerhaft darin. Deshalb
    # löst nur ein Zuwachs eine Warnung aus, und nie ein kritischer Alarm.
    CRC_NUM=$(to_number "$CRC")
    CRC_DELTA=$(history_delta_last 5 "$CRC_NUM")
    CRC_COLOR="green"; CRC_MSG="OK"
    if [ "$CRC_DELTA" -gt 0 ]; then
        CRC_COLOR="orange"; CRC_MSG="WARNUNG"
        raise_disk_status WARNUNG
        DISK_ISSUES="${DISK_ISSUES}<li>UDMA_CRC_Errors: <b>$CRC</b> (+$CRC_DELTA seit dem letzten Lauf) – Kabel/Verbindung prüfen, kein Medienfehler</li>"
    elif [ "$CRC_NUM" -ge 1 ]; then
        CRC_COLOR="#566573"; CRC_MSG="HINWEIS"
        raise_disk_status HINWEIS
        DISK_ISSUES="${DISK_ISSUES}<li>UDMA_CRC_Errors: $CRC (unverändert) – zurückliegender Verbindungsfehler, keine Aktion nötig</li>"
    fi
    echo "<tr><td>UDMA_CRC_Errors</td><td>$CRC</td><td style='color:$CRC_COLOR; font-weight:bold;'>$CRC_MSG</td></tr>" >> "$DISK_SECTIONS"
    echo "</table>" >> "$DISK_SECTIONS"

    # --- Historie-Tabelle ---
    echo "<p><b>Historie (Letzte $HISTORY_RUNS Läufe):</b></p>" >> "$DISK_SECTIONS"
    echo "<pre style='background:#f8f9fa; padding:10px; border-left:4px solid #3498db; font-family: monospace;'>" >> "$DISK_SECTIONS"
    echo "Datum      | Realloc | Pending | Offline |     CRC |  Report |  CmdTO" >> "$DISK_SECTIONS"
    echo "-----------|---------|---------|---------|---------|---------|--------" >> "$DISK_SECTIONS"
    awk '{printf "%s | %7s | %7s | %7s | %7s | %7s | %7s\n", $1, $2, $3, $4, ($5==""?"-":$5), ($6==""?"-":$6), ($7==""?"-":$7)}' "$HISTORY_FILE" >> "$DISK_SECTIONS"
    echo "</pre></div>" >> "$DISK_SECTIONS"

    # --- Gesamtstatus fortschreiben ---
    case "$DISK_STATUS" in
        KRITISCH)
            OVERALL_STATUS="KRITISCH"
            CRITICAL_DISKS="$CRITICAL_DISKS $DEVICE"
            ;;
        WARNUNG)
            [ "$OVERALL_STATUS" != "KRITISCH" ] && OVERALL_STATUS="WARNUNG"
            WARNING_DISKS="$WARNING_DISKS $DEVICE"
            ;;
        HINWEIS)
            [ "$OVERALL_STATUS" = "OK" ] && OVERALL_STATUS="HINWEIS"
            ;;
    esac
    if [ "$DISK_STATUS" != "OK" ]; then
        PROBLEM_DETAILS="${PROBLEM_DETAILS}<div style='margin:5px 0;'><b>$DEVICE</b><ul style='margin:5px 0;'>${DISK_ISSUES}</ul></div>"
    fi
done

# === Betreff & Kopfzeilen abhängig vom Gesamtstatus ===
# Nur KRITISCH und WARNUNG ändern den Betreff. Ein reiner HINWEIS soll die
# tägliche Mail nicht auffällig machen, sonst stumpft die Eskalation ab.
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
    HINWEIS)
        MAIL_SUBJECT="[$HOSTNAME] SMART-Report"
        BANNER_COLOR="#566573"; BANNER_BG="#f4f6f6"
        BANNER_TEXT="Keine akuten Fehler – es liegen lediglich zurückliegende Auffälligkeiten vor."
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
