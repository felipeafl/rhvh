#!/bin/bash
# =============================================================================
# smart_check.sh — Análisis SMART de discos via MegaRAID storcli
# Uso: curl -s https://raw.githubusercontent.com/felipeafl/rhvh/main/smart_check.sh | bash
# =============================================================================

STORCLI="/opt/MegaRAID/storcli/storcli64"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

header() {
    echo -e "\n${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
}
section() { echo -e "\n${BOLD}── $1 ──────────────────────────────────────────────────────${NC}"; }
ok()      { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
crit()    { echo -e "  ${RED}✘${NC}  $1"; }

# Decodifica SMART raw hex — recibe el hex como archivo temporal
decode_smart() {
    local HEXFILE="$1"
    python3 << PYEOF
import struct

attrs = {
    0x09: "hours",
    0xBC: "timeout",
    0x05: "realloc",
    0xC4: "realloc_ev",
    0xC5: "pending",
    0xD3: "rain_fail",
    0xAD: "wear",
    0xCA: "lifetime",
    0xBB: "uncorr",
    0xAE: "powerloss",
}

result = {v: 0 for v in attrs.values()}
result["val_wear"] = 100
result["val_lifetime"] = 0

try:
    with open("$HEXFILE") as f:
        raw = f.read()
    data = bytes(int(x, 16) for x in raw.split())
    i = 0
    while i < len(data) - 11:
        aid = data[i]
        if aid in attrs:
            val  = data[i+3]
            raw6 = data[i+5:i+11]
            rv   = int.from_bytes(raw6, 'little')
            name = attrs[aid]
            if   aid == 0x09: result[name] = rv & 0xFFFFFF
            elif aid == 0xAD: result[name] = rv; result["val_wear"] = val
            elif aid == 0xCA: result[name] = rv; result["val_lifetime"] = 100 - val
            else:             result[name] = rv
        i += 12
except Exception as e:
    pass

print("{hours}|{timeout}|{realloc}|{realloc_ev}|{pending}|{rain_fail}|{val_wear}|{val_lifetime}|{uncorr}|{powerloss}".format(**result))
PYEOF
}

# =============================================================================
header "SMART DISK HEALTH CHECK — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
# =============================================================================

if [ ! -f "$STORCLI" ]; then
    crit "storcli64 no encontrado en $STORCLI"
    exit 1
fi

PD_LIST=$($STORCLI /c0 /eall /sall show 2>/dev/null | awk '/^[0-9]/ && /Onln|Offln|Rbld|UBad/{print $1}')

if [ -z "$PD_LIST" ]; then
    crit "No se encontraron discos físicos"
    exit 1
fi

TOTAL=$(echo "$PD_LIST" | wc -l)
ISSUES=0
TMPFILE=$(mktemp /tmp/smart_XXXXXX.hex)

echo -e "\n  Discos a analizar: ${BOLD}${TOTAL}${NC}"

# =============================================================================
section "RESUMEN DE SALUD"
# =============================================================================
printf "  ${BOLD}%-8s %-30s %-8s %-8s %-8s %-8s %-8s %-8s %-10s %s${NC}\n" \
    "SLOT" "MODELO" "HORAS" "TIMEOUT" "REALLOC" "PENDING" "RAIN" "WEAROUT" "LIFETIME%" "ESTADO"
printf "  %0.s─" {1..110}; echo ""

# Guardar resultados para el detalle posterior
declare -A DISK_VALS

for DISK in $PD_LIST; do
    EID=$(echo "$DISK" | cut -d: -f1)
    SLT=$(echo "$DISK" | cut -d: -f2)

    # Info básica
    INFO=$($STORCLI /c0/e${EID}/s${SLT} show all 2>/dev/null)
    MODEL=$(echo "$INFO"     | awk '/Model Number/{print $NF}' | cut -c1-28)
    MEDIA_ERR=$(echo "$INFO" | awk '/Media Error Count/{print $NF}')
    PRED_FAIL=$(echo "$INFO" | awk '/Predictive Failure Count/{print $NF}')
    OTHER_ERR=$(echo "$INFO" | awk '/Other Error Count/{print $NF}')
    TEMP=$(echo "$INFO"      | awk '/Drive Temperature/{print $3}')
    SN=$(echo "$INFO"        | awk '/^SN/{print $NF}')
    FW=$(echo "$INFO"        | awk '/Firmware Revision/{print $NF}')

    # Guardar SMART hex en archivo temporal para pasarlo a Python sin problemas
    $STORCLI /c0/e${EID}/s${SLT} show smart 2>/dev/null | \
        grep -E "^[0-9a-f]{2} " > "$TMPFILE"

    # Decodificar SMART
    VALS=$(decode_smart "$TMPFILE")

    HOURS=$(echo "$VALS"     | cut -d'|' -f1)
    TIMEOUT=$(echo "$VALS"   | cut -d'|' -f2)
    REALLOC=$(echo "$VALS"   | cut -d'|' -f3)
    REALLOC_EV=$(echo "$VALS"| cut -d'|' -f4)
    PENDING=$(echo "$VALS"   | cut -d'|' -f5)
    RAIN=$(echo "$VALS"      | cut -d'|' -f6)
    WEAR=$(echo "$VALS"      | cut -d'|' -f7)
    LIFETIME=$(echo "$VALS"  | cut -d'|' -f8)
    UNCORR=$(echo "$VALS"    | cut -d'|' -f9)
    PLOSS=$(echo "$VALS"     | cut -d'|' -f10)

    # Guardar para detalle
    DISK_VALS["${EID}:${SLT}"]="${MODEL}|${SN}|${FW}|${TEMP}|${MEDIA_ERR}|${OTHER_ERR}|${PRED_FAIL}|${HOURS}|${TIMEOUT}|${REALLOC}|${REALLOC_EV}|${PENDING}|${RAIN}|${WEAR}|${LIFETIME}|${UNCORR}|${PLOSS}"

    # Determinar estado
    ESTADO="${GREEN}OK${NC}"
    ISSUE=0
    [ "${UNCORR:-0}"    -gt 0  ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${REALLOC:-0}"   -gt 0  ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${PENDING:-0}"   -gt 0  ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${RAIN:-0}"      -gt 5  ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${MEDIA_ERR:-0}" -gt 0  ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${PRED_FAIL:-0}" -gt 0  ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${TIMEOUT:-0}"   -gt 50 ] 2>/dev/null && { [ "$ISSUE" -eq 0 ] && ESTADO="${YELLOW}WARN${NC}"; ISSUE=1; }
    [ "${LIFETIME:-0}"  -gt 80 ] 2>/dev/null && { [ "$ISSUE" -eq 0 ] && ESTADO="${YELLOW}WARN${NC}"; ISSUE=1; }
    [ "${WEAR:-100}"    -lt 20 ] 2>/dev/null && { [ "$ISSUE" -eq 0 ] && ESTADO="${YELLOW}WARN${NC}"; ISSUE=1; }

    [ "$ISSUE" -gt 0 ] && ISSUES=$(( ISSUES + 1 ))

    printf "  %-8s %-30s %-8s %-8s %-8s %-8s %-8s %-8s %-10s " \
        "${EID}:${SLT}" "${MODEL:-Unknown}" \
        "${HOURS}" "${TIMEOUT}" "${REALLOC}" \
        "${PENDING}" "${RAIN}" "${WEAR}%" "${LIFETIME}%"
    echo -e "${ESTADO}"
done

# =============================================================================
# Detalle discos con problemas
# =============================================================================
if [ "$ISSUES" -gt 0 ]; then
    section "DETALLE DE DISCOS CON PROBLEMAS"

    for DISK in $PD_LIST; do
        EID=$(echo "$DISK" | cut -d: -f1)
        SLT=$(echo "$DISK" | cut -d: -f2)
        KEY="${EID}:${SLT}"
        V="${DISK_VALS[$KEY]}"

        MODEL=$(echo "$V"      | cut -d'|' -f1)
        SN=$(echo "$V"         | cut -d'|' -f2)
        FW=$(echo "$V"         | cut -d'|' -f3)
        TEMP=$(echo "$V"       | cut -d'|' -f4)
        MEDIA_ERR=$(echo "$V"  | cut -d'|' -f5)
        OTHER_ERR=$(echo "$V"  | cut -d'|' -f6)
        PRED_FAIL=$(echo "$V"  | cut -d'|' -f7)
        HOURS=$(echo "$V"      | cut -d'|' -f8)
        TIMEOUT=$(echo "$V"    | cut -d'|' -f9)
        REALLOC=$(echo "$V"    | cut -d'|' -f10)
        REALLOC_EV=$(echo "$V" | cut -d'|' -f11)
        PENDING=$(echo "$V"    | cut -d'|' -f12)
        RAIN=$(echo "$V"       | cut -d'|' -f13)
        WEAR=$(echo "$V"       | cut -d'|' -f14)
        LIFETIME=$(echo "$V"   | cut -d'|' -f15)
        UNCORR=$(echo "$V"     | cut -d'|' -f16)
        PLOSS=$(echo "$V"      | cut -d'|' -f17)

        # Solo si tiene problemas
        HAS_ISSUE=0
        [ "${UNCORR:-0}"    -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${REALLOC:-0}"   -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${PENDING:-0}"   -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${RAIN:-0}"      -gt 5  ] 2>/dev/null && HAS_ISSUE=1
        [ "${MEDIA_ERR:-0}" -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${PRED_FAIL:-0}" -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${TIMEOUT:-0}"   -gt 50 ] 2>/dev/null && HAS_ISSUE=1
        [ "${LIFETIME:-0}"  -gt 80 ] 2>/dev/null && HAS_ISSUE=1
        [ "${WEAR:-100}"    -lt 20 ] 2>/dev/null && HAS_ISSUE=1
        [ "$HAS_ISSUE" -eq 0 ] && continue

        echo ""
        echo -e "  ${BOLD}${RED}▶ Slot ${EID}:${SLT} — ${MODEL}${NC}"
        echo -e "    S/N: ${SN}  |  FW: ${FW}  |  Temp: ${TEMP}  |  Uso: ~$(( ${HOURS:-0} / 24 / 365 )) años (${HOURS}h)"
        echo ""
        [ "${MEDIA_ERR:-0}"  -gt 0  ] && crit  "Media Error Count:          ${MEDIA_ERR} — errores directos de lectura/escritura"
        [ "${OTHER_ERR:-0}"  -gt 0  ] && warn  "Other Error Count:          ${OTHER_ERR} — timeouts y resets acumulados"
        [ "${PRED_FAIL:-0}"  -gt 0  ] && crit  "Predictive Failure Count:   ${PRED_FAIL} — el propio disco anticipa fallo"
        [ "${UNCORR:-0}"     -gt 0  ] && crit  "Uncorrectable Errors:       ${UNCORR}   — errores no corregibles"
        [ "${REALLOC:-0}"    -gt 0  ] && crit  "Reallocated Sectors:        ${REALLOC}  — sectores físicos perdidos ⚠ reemplazar"
        [ "${REALLOC_EV:-0}" -gt 0  ] && crit  "Reallocation Events:        ${REALLOC_EV} — eventos de pérdida de sector"
        [ "${PENDING:-0}"    -gt 0  ] && crit  "Pending Sectors:            ${PENDING}  — sectores en espera de reasignación"
        [ "${RAIN:-0}"       -gt 5  ] && crit  "RAIN Recovery Failures:     ${RAIN}     — recuperación interna NAND fallida"
        [ "${TIMEOUT:-0}"    -gt 50 ] && warn  "Command Timeouts:           ${TIMEOUT}  — no responde a tiempo (>50 es crítico)"
        [ "${PLOSS:-0}"      -gt 0  ] && warn  "Unexpected Power Loss:      ${PLOSS}    — apagados inesperados acumulados"
        [ "${LIFETIME:-0}"   -gt 80 ] && warn  "Lifetime Used:              ${LIFETIME}% — vida útil casi agotada"
        [ "${WEAR:-100}"     -lt 20 ] && warn  "Wear Leveling value:        ${WEAR}     — desgaste elevado de celdas NAND"
    done
fi

# =============================================================================
section "CONCLUSION"
# =============================================================================
if [ "$ISSUES" -eq 0 ]; then
    ok "Todos los ${TOTAL} discos están saludables"
else
    crit "${ISSUES} de ${TOTAL} disco(s) con problemas — ver detalle arriba"
    echo ""
    echo "  Guía de acción:"
    echo "  🔴 Reallocated Sectors / RAIN failures / Pending Sectors → reemplazar urgente"
    echo "  ⚠️  Command Timeouts > 50                                → planificar reemplazo"
    echo "  ⚠️  Lifetime > 80% / Wear bajo                          → reemplazo preventivo"
fi

rm -f "$TMPFILE"
echo ""
