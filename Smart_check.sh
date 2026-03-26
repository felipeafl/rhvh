#!/bin/bash
# =============================================================================
# smart_check.sh — Análisis SMART de discos via MegaRAID storcli
# Compatible con RHVH (bash) y ESXi (sh)
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

section() {
    echo -e "\n${BOLD}── $1 ──────────────────────────────────────────────────────${NC}"
}

ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
crit() { echo -e "  ${RED}✘${NC}  $1"; }

# =============================================================================
header "SMART DISK HEALTH CHECK — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
# =============================================================================

if [ ! -f "$STORCLI" ]; then
    crit "storcli64 no encontrado en $STORCLI"
    exit 1
fi

# Obtener lista de discos físicos
PD_LIST=$($STORCLI /c0 /eall /sall show 2>/dev/null | awk '/^[0-9]/ && /Onln|Offln|Rbld|UBad/{print $1}')

if [ -z "$PD_LIST" ]; then
    crit "No se encontraron discos físicos"
    exit 1
fi

TOTAL=$(echo "$PD_LIST" | wc -l)
ISSUES=0

echo -e "\n  Discos a analizar: ${BOLD}${TOTAL}${NC}"

# =============================================================================
# Tabla resumen
# =============================================================================
section "RESUMEN DE SALUD"
printf "  ${BOLD}%-8s %-30s %-8s %-8s %-8s %-8s %-8s %-8s %-10s %s${NC}\n" \
    "SLOT" "MODELO" "HORAS" "TIMEOUT" "REALLOC" "PENDING" "RAIN" "WEAROUT" "LIFETIME%" "ESTADO"
printf "  %0.s─" {1..110}; echo ""

for DISK in $PD_LIST; do
    EID=$(echo "$DISK" | cut -d: -f1)
    SLT=$(echo "$DISK" | cut -d: -f2)

    # Info básica del disco
    INFO=$($STORCLI /c0/e${EID}/s${SLT} show all 2>/dev/null)
    MODEL=$(echo "$INFO" | awk '/Model Number/{print $NF}' | cut -c1-28)
    MEDIA_ERR=$(echo "$INFO" | awk '/Media Error Count/{print $NF}')
    OTHER_ERR=$(echo "$INFO" | awk '/Other Error Count/{print $NF}')
    PRED_FAIL=$(echo "$INFO" | awk '/Predictive Failure Count/{print $NF}')

    # SMART raw
    SMART=$($STORCLI /c0/e${EID}/s${SLT} show smart 2>/dev/null | \
        grep -A1 "Smart Data" | tail -1)
    SMART_HEX=$($STORCLI /c0/e${EID}/s${SLT} show smart 2>/dev/null | \
        awk '/^[0-9a-f][0-9a-f] /{printf "%s", $0}')

    # Decodificar atributos SMART via Python
    SMART_VALS=$(python3 2>/dev/null << PYEOF
import struct, sys

raw = """$($STORCLI /c0/e${EID}/s${SLT} show smart 2>/dev/null | grep -E "^[0-9a-f]{2} ")"""

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
    0xCE: "reserved",
}

result = {k: 0 for k in attrs.values()}
result["val_wear"] = 100
result["val_lifetime"] = 0

try:
    data = bytes(int(x,16) for x in raw.split())
    i = 0
    while i < len(data) - 11:
        aid = data[i]
        if aid in attrs:
            val   = data[i+3]
            raw6  = data[i+5:i+11]
            raw_v = int.from_bytes(raw6, 'little')
            name  = attrs[aid]
            if aid == 0x09:    result[name] = raw_v & 0xFFFFFF
            elif aid == 0xAD:  result[name] = raw_v; result["val_wear"] = val
            elif aid == 0xCA:  result[name] = raw_v; result["val_lifetime"] = 100 - val
            else:               result[name] = raw_v
        i += 12
except:
    pass

print("{hours}|{timeout}|{realloc}|{pending}|{rain_fail}|{val_wear}|{val_lifetime}|{uncorr}|{powerloss}".format(**result))
PYEOF
)

    # Parsear valores
    HOURS=$(echo "$SMART_VALS"    | cut -d'|' -f1)
    TIMEOUT=$(echo "$SMART_VALS"  | cut -d'|' -f2)
    REALLOC=$(echo "$SMART_VALS"  | cut -d'|' -f3)
    PENDING=$(echo "$SMART_VALS"  | cut -d'|' -f4)
    RAIN=$(echo "$SMART_VALS"     | cut -d'|' -f5)
    WEAR=$(echo "$SMART_VALS"     | cut -d'|' -f6)
    LIFETIME=$(echo "$SMART_VALS" | cut -d'|' -f7)
    UNCORR=$(echo "$SMART_VALS"   | cut -d'|' -f8)
    PLOSS=$(echo "$SMART_VALS"    | cut -d'|' -f9)

    # Defaults si Python no está disponible
    HOURS=${HOURS:-"N/A"}
    TIMEOUT=${TIMEOUT:-0}
    REALLOC=${REALLOC:-0}
    PENDING=${PENDING:-0}
    RAIN=${RAIN:-0}
    WEAR=${WEAR:-100}
    LIFETIME=${LIFETIME:-0}

    # Determinar estado
    ESTADO="${GREEN}OK${NC}"
    ISSUE=0

    [ "${UNCORR:-0}" -gt 0 ]  2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${REALLOC:-0}" -gt 0 ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${PENDING:-0}" -gt 0 ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${RAIN:-0}" -gt 5 ]    2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${TIMEOUT:-0}" -gt 50 ] 2>/dev/null && { [ "$ISSUE" -eq 0 ] && ESTADO="${YELLOW}WARN${NC}"; ISSUE=1; }
    [ "${LIFETIME:-0}" -gt 80 ] 2>/dev/null && { [ "$ISSUE" -eq 0 ] && ESTADO="${YELLOW}WARN${NC}"; ISSUE=1; }
    [ "${WEAR:-100}" -lt 20 ] 2>/dev/null && { [ "$ISSUE" -eq 0 ] && ESTADO="${YELLOW}WARN${NC}"; ISSUE=1; }
    [ "${MEDIA_ERR:-0}" -gt 0 ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }
    [ "${PRED_FAIL:-0}" -gt 0 ] 2>/dev/null && { ESTADO="${RED}CRITICO${NC}"; ISSUE=1; }

    [ "$ISSUE" -gt 0 ] && ISSUES=$(( ISSUES + 1 ))

    printf "  %-8s %-30s %-8s %-8s %-8s %-8s %-8s %-8s %-10s " \
        "${EID}:${SLT}" "${MODEL:-Unknown}" \
        "${HOURS}" "${TIMEOUT}" "${REALLOC}" \
        "${PENDING}" "${RAIN}" "${WEAR}%" "${LIFETIME}%"
    echo -e "${ESTADO}"
done

# =============================================================================
# Detalle de discos con problemas
# =============================================================================
if [ "$ISSUES" -gt 0 ]; then
    section "DETALLE DE DISCOS CON PROBLEMAS"

    for DISK in $PD_LIST; do
        EID=$(echo "$DISK" | cut -d: -f1)
        SLT=$(echo "$DISK" | cut -d: -f2)

        INFO=$($STORCLI /c0/e${EID}/s${SLT} show all 2>/dev/null)
        MODEL=$(echo "$INFO"     | awk '/Model Number/{print $NF}')
        SN=$(echo "$INFO"        | awk '/^SN/{print $NF}')
        FW=$(echo "$INFO"        | awk '/Firmware Revision/{print $NF}')
        MEDIA_ERR=$(echo "$INFO" | awk '/Media Error Count/{print $NF}')
        OTHER_ERR=$(echo "$INFO" | awk '/Other Error Count/{print $NF}')
        PRED_FAIL=$(echo "$INFO" | awk '/Predictive Failure Count/{print $NF}')
        TEMP=$(echo "$INFO"      | awk '/Drive Temperature/{print $3}')

        SMART_VALS=$(python3 2>/dev/null << PYEOF
import struct
raw = """$($STORCLI /c0/e${EID}/s${SLT} show smart 2>/dev/null | grep -E "^[0-9a-f]{2} ")"""
attrs = {0x09:"hours",0xBC:"timeout",0x05:"realloc",0xC4:"realloc_ev",
         0xC5:"pending",0xD3:"rain_fail",0xAD:"wear",0xCA:"lifetime",
         0xBB:"uncorr",0xAE:"powerloss"}
result = {v:0 for v in attrs.values()}
result["val_wear"]=100; result["val_lifetime"]=0
try:
    data = bytes(int(x,16) for x in raw.split())
    i=0
    while i < len(data)-11:
        aid=data[i]
        if aid in attrs:
            val=data[i+3]; raw6=data[i+5:i+11]; raw_v=int.from_bytes(raw6,'little')
            name=attrs[aid]
            if aid==0x09: result[name]=raw_v&0xFFFFFF
            elif aid==0xAD: result[name]=raw_v; result["val_wear"]=val
            elif aid==0xCA: result[name]=raw_v; result["val_lifetime"]=100-val
            else: result[name]=raw_v
        i+=12
except: pass
print("{hours}|{timeout}|{realloc}|{realloc_ev}|{pending}|{rain_fail}|{val_wear}|{val_lifetime}|{uncorr}|{powerloss}".format(**result))
PYEOF
)
        HOURS=$(echo "$SMART_VALS"    | cut -d'|' -f1)
        TIMEOUT=$(echo "$SMART_VALS"  | cut -d'|' -f2)
        REALLOC=$(echo "$SMART_VALS"  | cut -d'|' -f3)
        REALLOC_EV=$(echo "$SMART_VALS" | cut -d'|' -f4)
        PENDING=$(echo "$SMART_VALS"  | cut -d'|' -f5)
        RAIN=$(echo "$SMART_VALS"     | cut -d'|' -f6)
        WEAR=$(echo "$SMART_VALS"     | cut -d'|' -f7)
        LIFETIME=$(echo "$SMART_VALS" | cut -d'|' -f8)
        UNCORR=$(echo "$SMART_VALS"   | cut -d'|' -f9)
        PLOSS=$(echo "$SMART_VALS"    | cut -d'|' -f10)

        # Solo mostrar si tiene problemas
        HAS_ISSUE=0
        [ "${UNCORR:-0}"    -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${REALLOC:-0}"   -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${PENDING:-0}"   -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${RAIN:-0}"      -gt 5  ] 2>/dev/null && HAS_ISSUE=1
        [ "${TIMEOUT:-0}"   -gt 50 ] 2>/dev/null && HAS_ISSUE=1
        [ "${LIFETIME:-0}"  -gt 80 ] 2>/dev/null && HAS_ISSUE=1
        [ "${WEAR:-100}"    -lt 20 ] 2>/dev/null && HAS_ISSUE=1
        [ "${MEDIA_ERR:-0}" -gt 0  ] 2>/dev/null && HAS_ISSUE=1
        [ "${PRED_FAIL:-0}" -gt 0  ] 2>/dev/null && HAS_ISSUE=1

        [ "$HAS_ISSUE" -eq 0 ] && continue

        echo ""
        echo -e "  ${BOLD}${RED}Slot ${EID}:${SLT} — ${MODEL}${NC}"
        echo -e "  ${BOLD}S/N:${NC} ${SN}  ${BOLD}FW:${NC} ${FW}  ${BOLD}Temp:${NC} ${TEMP}"
        echo ""

        # Mostrar solo atributos problemáticos
        [ "${MEDIA_ERR:-0}"  -gt 0  ] && crit "Media Error Count:              ${MEDIA_ERR} — errores de lectura/escritura directos"
        [ "${OTHER_ERR:-0}"  -gt 0  ] && warn "Other Error Count:              ${OTHER_ERR} — errores varios (timeouts, resets)"
        [ "${PRED_FAIL:-0}"  -gt 0  ] && crit "Predictive Failure Count:       ${PRED_FAIL} — el disco anticipa fallo"
        [ "${UNCORR:-0}"     -gt 0  ] && crit "Uncorrectable Error Count:      ${UNCORR} — errores no corregibles"
        [ "${REALLOC:-0}"    -gt 0  ] && crit "Reallocated Sector Count:       ${REALLOC} — sectores físicos perdidos"
        [ "${REALLOC_EV:-0}" -gt 0  ] && crit "Reallocation Event Count:       ${REALLOC_EV} — eventos de reasignación"
        [ "${PENDING:-0}"    -gt 0  ] && crit "Current Pending Sectors:        ${PENDING} — sectores pendientes de reasignación"
        [ "${RAIN:-0}"       -gt 5  ] && crit "Unsuccessful RAIN Recovery:     ${RAIN} — recuperación interna de NAND fallida"
        [ "${TIMEOUT:-0}"    -gt 50 ] && warn "Command Timeout Count:          ${TIMEOUT} — timeouts acumulados (>50 es preocupante)"
        [ "${PLOSS:-0}"      -gt 0  ] && warn "Unexpected Power Loss:          ${PLOSS} — apagados inesperados"
        [ "${LIFETIME:-0}"   -gt 80 ] && warn "Lifetime Used:                  ${LIFETIME}% — vida útil casi agotada"
        [ "${WEAR:-100}"     -lt 20 ] && warn "Wear Leveling (valor):          ${WEAR} — desgaste elevado"

        echo ""
        echo -e "  ${BOLD}Horas de uso:${NC} ${HOURS}h (~$(( HOURS / 24 / 365 )) años)"
    done
fi

# =============================================================================
# Resumen final
# =============================================================================
section "CONCLUSION"
if [ "$ISSUES" -eq 0 ]; then
    ok "Todos los ${TOTAL} discos están saludables — sin problemas detectados"
else
    crit "${ISSUES} de ${TOTAL} disco(s) presentan problemas — revisar detalle arriba"
    echo ""
    warn "Recomendaciones:"
    echo "  - Discos con Reallocated Sectors o RAIN failures: reemplazar urgente"
    echo "  - Discos con Command Timeouts > 50: monitorear y planificar reemplazo"
    echo "  - Discos con Lifetime > 80%: planificar reemplazo preventivo"
fi

echo ""
