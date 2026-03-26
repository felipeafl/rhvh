#!/bin/bash
# =============================================================================
# smart_check.sh — Análisis SMART avanzado para controladores MegaRAID
# Autor: Felipe (Optimizado para RHV/Infraestructura)
# =============================================================================

STORCLI="/opt/MegaRAID/storcli/storcli64"
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

header()  { echo -e "\n${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}\n${CYAN}${BOLD}  $1${NC}\n${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"; }
section() { echo -e "\n${BOLD}── $1 ──────────────────────────────────────────────────────${NC}"; }
ok()      { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
crit()    { echo -e "  ${RED}✘${NC}  $1"; }

# 1. Crear el decodificador Python dinámicamente
PYFILE=$(mktemp /tmp/smart_decode_XXXXXX.py)
cat > "$PYFILE" << 'PYEOF'
import sys

# Mapeo de IDs SMART comunes en entornos Enterprise
attrs_map = {
    0x05: "realloc", 0x09: "hours", 0x0C: "power_cycle",
    0xAA: "res_blocks", 0xAB: "prog_fail", 0xAC: "erase_fail",
    0xAD: "wear", 0xAE: "powerloss", 0xBB: "uncorr",
    0xBC: "timeout", 0xC2: "temp", 0xC4: "realloc_ev",
    0xC5: "pending", 0xC6: "offline_uncorr", 0xC7: "crc_err",
    0xCA: "lifetime", 0xF6: "total_writes"
}

result = {v: 0 for v in attrs_map.values()}
result["val_wear"] = 100 

try:
    if len(sys.argv) < 2: sys.exit(0)
    with open(sys.argv[1], 'r') as f:
        hex_raw = f.read().replace('|', ' ').split()
        data = [int(x, 16) for x in hex_raw if len(x) == 2]

    # Iterar la tabla SMART (bloques de 12 bytes)
    for i in range(0, len(data) - 11, 12):
        aid = data[i]
        if aid in attrs_map:
            name = attrs_map[aid]
            # Extraer el valor 'Normalized' (típicamente byte 3 o 4)
            norm_value = data[i+3]
            # Extraer el valor 'Raw' (6 bytes, little-endian)
            raw_bytes = data[i+5:i+11]
            raw_val = int.from_bytes(raw_bytes, 'little')
            
            result[name] = raw_val
            
            # Lógica especial para desgaste (SSD)
            if aid == 0xAD: result["val_wear"] = norm_value
            if aid == 0xCA: result["val_wear"] = 100 - norm_value

    # Formato de salida para Bash: hours|timeout|realloc|pending|wear|uncorr|powerloss
    out = [result['hours'], result['timeout'], result['realloc'], 
           result['pending'], result['val_wear'], result['uncorr'], result['powerloss']]
    print("|".join(map(str, out)))
except Exception:
    print("0|0|0|0|100|0|0")
PYEOF

# 2. Verificaciones iniciales
header "SMART DISK HEALTH CHECK — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"

if [ ! -f "$STORCLI" ]; then
    crit "storcli64 no encontrado en $STORCLI"
    rm -f "$PYFILE"; exit 1
fi

PD_LIST=$($STORCLI /c0 /eall /sall show 2>/dev/null | \
    awk '/^[0-9]/ && /Onln|Offln|Rbld|UBad|UUnsp/{print $1}')

if [ -z "$PD_LIST" ]; then
    crit "No se encontraron discos físicos en el controlador 0"
    rm -f "$PYFILE"; exit 1
fi

TOTAL=$(echo "$PD_LIST" | wc -l | tr -d ' ')
ISSUES=0
HEXFILE=$(mktemp /tmp/smart_hex_XXXXXX.txt)

echo -e "\n  Discos detectados: ${BOLD}${TOTAL}${NC}"

# 3. Resumen de Salud
section "RESUMEN DE ESTADO"
printf "  ${BOLD}%-8s %-25s %-10s %-8s %-8s %-8s %-10s %s${NC}\n" \
    "SLOT" "MODELO" "HORAS" "REALLOC" "PENDING" "TIMEOUT" "WEAROUT" "ESTADO"
printf "  %0.s─" {1..100}; echo ""

declare -A DISK_VALS

for DISK in $PD_LIST; do
    EID=$(echo "$DISK" | cut -d: -f1)
    SLT=$(echo "$DISK" | cut -d: -f2)

    # Obtener info general del disco
    INFO=$($STORCLI /c0/e${EID}/s${SLT} show all 2>/dev/null)
    MODEL=$(echo "$INFO" | awk '/Model Number/{print $NF}' | cut -c1-24)
    SN=$(echo "$INFO" | awk '/^SN =/{print $NF}')
    PRED_FAIL=$(echo "$INFO" | awk '/Predictive Failure Count/{print $NF}')
    MEDIA_ERR=$(echo "$INFO" | awk '/Media Error Count/{print $NF}')
    TEMP=$(echo "$INFO" | awk '/Drive Temperature/{print $3}')

    # Extraer SMART HEX y limpiar
    $STORCLI /c0/e${EID}/s${SLT} show smart 2>/dev/null | \
        grep -E '^[0-9a-fA-F]{2} ' > "$HEXFILE"

    # Procesar con Python
    VALS=$(python3 "$PYFILE" "$HEXFILE")
    HOURS=$(echo "$VALS"   | cut -d'|' -f1)
    TIMEOUT=$(echo "$VALS" | cut -d'|' -f2)
    REALLOC=$(echo "$VALS" | cut -d'|' -f3)
    PENDING=$(echo "$VALS" | cut -d'|' -f4)
    WEAR=$(echo "$VALS"    | cut -d'|' -f5)
    UNCORR=$(echo "$VALS"  | cut -d'|' -f6)
    PLOSS=$(echo "$VALS"   | cut -d'|' -f7)

    # Guardar datos para el detalle
    DISK_VALS["$EID:$SLT"]="$MODEL|$SN|$HOURS|$REALLOC|$PENDING|$TIMEOUT|$WEAR|$UNCORR|$PLOSS|$MEDIA_ERR|$PRED_FAIL|$TEMP"

    # Lógica de Evaluación
    ESTADO="${GREEN}OK${NC}"
    WARN=0; CRIT=0
    [ "${REALLOC:-0}" -gt 0 ] && CRIT=1
    [ "${PENDING:-0}" -gt 0 ] && CRIT=1
    [ "${UNCORR:-0}" -gt 0 ] && CRIT=1
    [ "${MEDIA_ERR:-0}" -gt 0 ] && CRIT=1
    [ "${PRED_FAIL:-0}" -gt 0 ] && CRIT=1
    [ "${TIMEOUT:-0}" -gt 50 ] && WARN=1
    [ "${WEAR:-100}" -lt 20 ] && WARN=1

    if [ $CRIT -eq 1 ]; then
        ESTADO="${RED}CRITICO${NC}"; ISSUES=$((ISSUES+1))
    elif [ $WARN -eq 1 ]; then
        ESTADO="${YELLOW}ALERTA${NC}"; ISSUES=$((ISSUES+1))
    fi

    printf "  %-8s %-25s %-10s %-8s %-8s %-8s %-10s " \
        "${EID}:${SLT}" "${MODEL:-N/A}" "${HOURS}h" "${REALLOC}" "${PENDING}" "${TIMEOUT}" "${WEAR}%"
    echo -e "$ESTADO"
done

# 4. Detalle de Problemas
if [ "$ISSUES" -gt 0 ]; then
    section "DETALLE DE DISCOS AFECTADOS"
    for KEY in "${!DISK_VALS[@]}"; do
        IFS='|' read -r MOD SN HRS REA PEN TMO WEA UNC PLO MED PRE TMP <<< "${DISK_VALS[$KEY]}"
        
        # Solo mostrar si tiene algo relevante
        if [ "$REA" -gt 0 ] || [ "$PEN" -gt 0 ] || [ "$UNC" -gt 0 ] || [ "$PRE" -gt 0 ] || [ "$WEA" -lt 20 ]; then
            echo -e "\n  ${RED}${BOLD}Slot $KEY ($MOD)${NC} - S/N: $SN"
            echo -e "  Temp: ${TMP}C | Antigüedad: $(( HRS / 8760 )) años"
            [ "$REA" -gt 0 ] && crit "Sectores Reasignados: $REA (Daño físico)"
            [ "$PEN" -gt 0 ] && crit "Sectores Pendientes: $PEN (Falla inminente)"
            [ "$UNC" -gt 0 ] && crit "Errores No Corregibles: $UNC"
            [ "$PRE" -gt 0 ] && crit "Predictive Failure detectado por Firmware!"
            [ "$MED" -gt 0 ] && warn "Errores de Media (OS): $MED"
            [ "$TMO" -gt 50 ] && warn "Timeouts de comandos: $TMO (Latencia alta)"
            [ "$WEA" -lt 20 ] && warn "Desgaste de SSD: Queda solo $WEA% de vida"
        fi
    done
fi

section "CONCLUSION"
if [ "$ISSUES" -eq 0 ]; then
    ok "Todos los discos están operando dentro de los parámetros normales."
else
    crit "Se encontraron $ISSUES discos con anomalías. Revisar reemplazos."
fi

rm -f "$PYFILE" "$HEXFILE"
echo ""
