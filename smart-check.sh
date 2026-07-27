#!/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

HOSTNAME=$(hostname)
DATA_DIR="/var/lib/smart-summary"
mkdir -p "$DATA_DIR"

# Wie viele Läufe in der Historie vorgehalten werden. Bei täglichem Cron-Lauf
# entspricht das einem Beobachtungsfenster von einer Woche.
HISTORY_RUNS=7

# Wie viele aufeinanderfolgende saubere Läufe einen gesetzten Kritisch-Marker
# automatisch aufheben.
CLEAR_RUNS=3

DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk"{print $1}')

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

# Die Seriennummer ist die einzige stabile Identität einer Platte: Kernel-Namen
# wie sda können sich nach einem Reboot vertauschen, und beim Plattentausch
# bliebe der Name gleich. Historie und Marker hängen deshalb an der Serie.
disk_serial() {
    smartctl -i "$1" 2>/dev/null | awk -F': +' '/Serial Number/ {print $2; exit}' | tr -d '[:space:]'
}

# Dateibasis für Historie und Marker. Ohne lesbare Seriennummer bleibt nur der
# Kernel-Name als Notbehelf — dann ist ein Plattentausch nicht erkennbar und
# muss mit --clear quittiert werden.
state_key() {
    local serial
    serial=$(disk_serial "$1")
    if [ -n "$serial" ]; then
        printf '%s' "${serial//[^A-Za-z0-9._-]/_}"
    else
        printf '%s' "$(basename "$1")"
    fi
}

state_get() {
    [ -f "$1" ] || return 0
    awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/, ""); print; exit}' "$1"
}

# ==============================================================================
# Kommandozeile: Marker anzeigen und quittieren
# ==============================================================================

print_status() {
    printf '%-12s %-24s %-10s %-12s %s\n' "PLATTE" "SERIENNUMMER" "MARKER" "SEIT" "GRUND"
    for disk in $DISKS; do
        local device="/dev/$disk" key state serial latched since reason
        device="/dev/$disk"
        key=$(state_key "$device")
        state="$DATA_DIR/$key.state"
        serial=$(disk_serial "$device"); serial=${serial:-unbekannt}
        latched=$(state_get "$state" LATCHED)
        since=$(state_get "$state" LATCHED_SINCE)
        reason=$(state_get "$state" LATCH_REASON)
        if [ "$latched" = "1" ]; then
            printf '%-12s %-24s %-10s %-12s %s\n' "$device" "$serial" "gesetzt" "${since:--}" "${reason:--}"
        else
            printf '%-12s %-24s %-10s %-12s %s\n' "$device" "$serial" "-" "-" "-"
        fi
    done
}

# Argument darf ein Gerät (/dev/sda, sda) oder direkt eine Seriennummer sein.
# Nach einem Tausch existiert der Geräteknoten der alten Platte nicht mehr,
# deshalb werden mehrere Deutungen des Arguments durchprobiert statt einer.
clear_latch() {
    local target="$1" candidates=() key state serial
    case "$target" in
        /dev/*) [ -e "$target" ] && candidates+=("$(state_key "$target")") ;;
        *)      [ -e "/dev/$target" ] && candidates+=("$(state_key "/dev/$target")") ;;
    esac
    # Argument direkt als Seriennummer deuten
    candidates+=("${target//[^A-Za-z0-9._-]/_}")
    # Und in den abgelegten Zuständen nach der Seriennummer suchen, damit auch
    # eine bereits ausgebaute Platte quittiert werden kann.
    for state in "$DATA_DIR"/*.state; do
        [ -f "$state" ] || continue
        serial=$(state_get "$state" SERIAL)
        if [ -n "$serial" ] && [ "$serial" = "$target" ]; then
            candidates+=("$(basename "$state" .state)")
        fi
    done

    for key in "${candidates[@]}"; do
        state="$DATA_DIR/$key.state"
        if [ -f "$state" ] && [ "$(state_get "$state" LATCHED)" = "1" ]; then
            rm -f "$state"
            echo "Marker für '$target' (Schlüssel: $key) aufgehoben."
            return 0
        fi
    done
    echo "Für '$target' ist kein Marker gesetzt." >&2
    return 1
}

case "${1:-}" in
    --status)
        print_status
        exit 0
        ;;
    --clear)
        if [ -z "${2:-}" ]; then
            echo "Verwendung: $0 --clear <gerät|seriennummer>" >&2
            exit 2
        fi
        clear_latch "$2"
        exit $?
        ;;
    --clear-all)
        rm -f "$DATA_DIR"/*.state
        echo "Alle Marker aufgehoben."
        exit 0
        ;;
    --help|-h)
        cat <<EOF
Verwendung: $0 [OPTION]

Ohne Option: SMART-Prüfung aller Platten und Versand des Reports an root.

  --status                     gesetzte Kritisch-Marker anzeigen
  --clear <gerät|seriennr>     Marker nach Tausch oder Reparatur quittieren
  --clear-all                  alle Marker aufheben
  --help                       diese Hilfe

Ein Kritisch-Marker wird gesetzt, sobald eine Platte als KRITISCH bewertet
wird, und bleibt danach bestehen, auch wenn die auslösende Regel nicht mehr
greift. Er verschwindet von selbst, wenn die Platte getauscht wurde (neue
Seriennummer) oder wenn alle auslösenden Attribute über $CLEAR_RUNS Läufe
wieder auf 0 stehen. Attribute wie Reallocated_Sector_Ct gehen nie auf 0
zurück — solche Marker müssen nach einer Reparatur mit --clear quittiert
werden.
EOF
        exit 0
        ;;
    "")
        ;;
    *)
        echo "Unbekannte Option: $1 (siehe $0 --help)" >&2
        exit 2
        ;;
esac

# ==============================================================================
# Normaler Prüflauf
# ==============================================================================

MAIL_BODY=$(mktemp)
DISK_SECTIONS=$(mktemp)

# Gesamtstatus über alle Platten hinweg: OK < HINWEIS < WARNUNG < KRITISCH
OVERALL_STATUS="OK"
CRITICAL_DISKS=""
WARNING_DISKS=""
PROBLEM_DETAILS=""

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

# Aktueller Rohwert eines Attributs, für die Prüfung ob ein gemerkter Befund
# wieder abgeklungen ist. Monotone Zähler wie Reallocated_Sector_Ct erreichen
# die 0 nie wieder — ihr Marker läuft daher bewusst nicht von selbst aus.
attr_value() {
    case "$1" in
        Reallocated_Sectors)    to_number "$REALLOC" ;;
        Current_Pending_Sector) to_number "$PENDING" ;;
        Offline_Uncorrectable)  to_number "$OFFLINE" ;;
        Reported_Uncorrect)     to_number "$REPORTED" ;;
        Command_Timeout)        to_number "$CMDTIMEOUT" ;;
        SMART-Gesamturteil)     [ "$HEALTH_FAILED" = "1" ] && echo 1 || echo 0 ;;
        *)                      echo 0 ;;
    esac
}

for DISK in $DISKS; do
    DEVICE="/dev/$DISK"
    SERIAL=$(disk_serial "$DEVICE")
    STATE_KEY=$(state_key "$DEVICE")
    HISTORY_FILE="$DATA_DIR/$STATE_KEY.history"
    STATE_FILE="$DATA_DIR/$STATE_KEY.state"

    # Migration: frühere Versionen haben die Historie unter dem Kernel-Namen
    # abgelegt. Beim ersten Lauf unter dem Serien-Schlüssel wird sie übernommen.
    if [ ! -f "$HISTORY_FILE" ] && [ -f "$DATA_DIR/$DISK.history" ] && [ "$STATE_KEY" != "$DISK" ]; then
        mv "$DATA_DIR/$DISK.history" "$HISTORY_FILE"
    fi

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
    CRITICAL_ATTRS=""
    CRITICAL_REASONS=""

    # --- SMART-Gesamturteil der Platte ---
    # "SMART overall-health self-assessment test result: FAILED!" bzw.
    # "SMART Health Status: FAILURE" ist der deutlichste Hinweis auf einen Defekt.
    HEALTH_FAILED=0
    HEALTH_LINE=$(echo "$SMART_HEALTH" | grep -Ei "overall-health|SMART Health Status" | head -n1)
    if echo "$HEALTH_LINE" | grep -qEi "FAILED|FAILURE"; then
        HEALTH_FAILED=1
        raise_disk_status KRITISCH
        DISK_ISSUES="${DISK_ISSUES}<li>SMART-Gesamturteil: <b>FAILED</b></li>"
        CRITICAL_ATTRS="SMART-Gesamturteil"
        CRITICAL_REASONS="SMART-Gesamturteil: FAILED"
    fi

    # HTML Output
    echo "<div style='margin-bottom: 30px; border: 1px solid #ccc; padding: 15px; border-radius: 5px;'>" >> "$DISK_SECTIONS"
    echo "<h3 style='margin-top:0; color:#2980b9;'>Disk: $DEVICE</h3>" >> "$DISK_SECTIONS"
    echo "<p><b>Modell:</b> $MANUFACTURER $MODEL<br><b>Seriennummer:</b> ${SERIAL:-unbekannt}<br><b>Laufzeit:</b> $POWER_ON_HOURS Stunden</p>" >> "$DISK_SECTIONS"

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
            CRITICAL_ATTRS="${CRITICAL_ATTRS:+$CRITICAL_ATTRS,}$NAME"
            CRITICAL_REASONS="${CRITICAL_REASONS:+$CRITICAL_REASONS; }$NAME: $VALUE ($REASON)"
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

    # ==========================================================================
    # Kritisch-Marker
    #
    # Ein einmal kritischer Befund bleibt kritisch, bis er nachweislich erledigt
    # ist. Sonst würde eine Platte allein dadurch wieder unauffällig, dass der
    # auslösende Zuwachs aus dem Historien-Fenster rutscht.
    #
    # Aufgehoben wird der Marker auf drei Wegen:
    #   1. Plattentausch  – neue Seriennummer, damit ein anderer Zustandsschlüssel
    #      und automatisch kein Marker. Die zusätzliche Prüfung unten greift für
    #      den Fall, dass mangels lesbarer Seriennummer über den Kernel-Namen
    #      geschlüsselt wurde.
    #   2. Wert wieder in Ordnung – alle auslösenden Attribute stehen über
    #      CLEAR_RUNS Läufe wieder auf 0.
    #   3. Reparatur/Quittung – manuell über --clear.
    # ==========================================================================
    PREV_SERIAL=$(state_get "$STATE_FILE" SERIAL)
    LATCHED=$(state_get "$STATE_FILE" LATCHED)
    LATCHED_SINCE=$(state_get "$STATE_FILE" LATCHED_SINCE)
    LATCH_ATTRS=$(state_get "$STATE_FILE" LATCH_ATTRS)
    LATCH_REASON=$(state_get "$STATE_FILE" LATCH_REASON)
    CLEAN_RUNS=$(to_number "$(state_get "$STATE_FILE" CLEAN_RUNS)")
    LATCH_NOTE=""

    # 1. Plattentausch bei Schlüsselung über den Kernel-Namen
    if [ "$LATCHED" = "1" ] && [ -n "$PREV_SERIAL" ] && [ -n "$SERIAL" ] && [ "$PREV_SERIAL" != "$SERIAL" ]; then
        rm -f "$STATE_FILE"
        LATCHED=""; LATCH_ATTRS=""; LATCH_REASON=""; CLEAN_RUNS=0
        LATCH_NOTE="Marker aufgehoben: Platte wurde getauscht (Seriennummer $PREV_SERIAL → $SERIAL)."
    fi

    if [ "$DISK_STATUS" = "KRITISCH" ]; then
        # Befund aktuell kritisch: Marker setzen bzw. auffrischen
        if [ "$LATCHED" != "1" ]; then
            LATCHED_SINCE=$(date +%F)
        fi
        LATCHED=1
        LATCH_ATTRS="$CRITICAL_ATTRS"
        LATCH_REASON="$CRITICAL_REASONS"
        CLEAN_RUNS=0
    elif [ "$LATCHED" = "1" ]; then
        # Kein akuter Befund, aber gemerkter: prüfen ob alle auslösenden
        # Attribute wieder auf 0 stehen.
        ALL_CLEAN=1
        IFS=',' read -r -a LATCH_ATTR_LIST <<< "$LATCH_ATTRS"
        for ATTR in "${LATCH_ATTR_LIST[@]}"; do
            [ -z "$ATTR" ] && continue
            if [ "$(attr_value "$ATTR")" -ne 0 ]; then ALL_CLEAN=0; break; fi
        done

        if [ "$ALL_CLEAN" -eq 1 ]; then
            CLEAN_RUNS=$(( CLEAN_RUNS + 1 ))
            if [ "$CLEAN_RUNS" -ge "$CLEAR_RUNS" ]; then
                rm -f "$STATE_FILE"
                LATCHED=""
                LATCH_NOTE="Marker aufgehoben: auslösende Attribute stehen seit $CLEAR_RUNS Läufen wieder auf 0."
            else
                LATCH_NOTE="Gemerkter Befund seit $LATCHED_SINCE – aktuell unauffällig ($CLEAN_RUNS von $CLEAR_RUNS sauberen Läufen), Marker wird danach automatisch aufgehoben."
            fi
        else
            CLEAN_RUNS=0
            LATCH_NOTE="Gemerkter Befund seit $LATCHED_SINCE: $LATCH_REASON. Die auslösenden Werte gehen nicht mehr auf 0 zurück – nach Tausch oder Reparatur mit <code>$0 --clear $DEVICE</code> quittieren."
        fi

        # Solange der Marker steht, bleibt die Platte kritisch.
        if [ "$LATCHED" = "1" ]; then
            DISK_STATUS="KRITISCH"
            DISK_ISSUES="${DISK_ISSUES}<li>Kritisch-Marker gesetzt (seit $LATCHED_SINCE)</li>"
        fi
    fi

    if [ -n "$LATCH_NOTE" ]; then
        DISK_ISSUES="${DISK_ISSUES}<li>$LATCH_NOTE</li>"
    fi

    # Zustand fortschreiben
    if [ "$LATCHED" = "1" ]; then
        cat > "$STATE_FILE" <<EOF
SERIAL=$SERIAL
LATCHED=1
LATCHED_SINCE=$LATCHED_SINCE
LATCH_ATTRS=$LATCH_ATTRS
LATCH_REASON=$LATCH_REASON
CLEAN_RUNS=$CLEAN_RUNS
EOF
    fi

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
    if [ "$DISK_STATUS" != "OK" ] || [ -n "$LATCH_NOTE" ]; then
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
