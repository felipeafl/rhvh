#!/bin/bash
# =============================================================================
# rhvh_healthcheck.sh — KVM Hypervisor + MegaRAID Health Check
# =============================================================================
 
STORCLI="/opt/MegaRAID/storcli/storcli64"
CTRL="/c0"
TOP_VMS=5       # cuántas VMs mostrar en el ranking
IOSTAT_INT=2    # intervalo de iostat en segundos
IOSTAT_COUNT=3  # número de muestras de iostat
 
# Firmware baseline opcional: si se define, compara contra este valor
# Déjalo vacío ("") para solo mostrar versiones sin comparar
EXPECTED_FW=""
 
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
 
SEP="────────────────────────────────────────────────────────────"
 
header() {
    echo -e "\n${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
}
 
section() {
    echo -e "\n${BOLD}── $1 ${SEP:${#1}+4}${NC}"
}
 
ok()   { echo -e "  ${GREEN}✔${NC}  $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $1"; }
crit() { echo -e "  ${RED}✘${NC}  $1"; }
 
# =============================================================================
header "RHVH HEALTH CHECK — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
# =============================================================================
 
# -----------------------------------------------------------------------------
section "CARGA DEL SISTEMA"
# -----------------------------------------------------------------------------
UPTIME=$(uptime)
LOAD1=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
LOAD5=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $2}' | tr -d ' ')
LOAD15=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $3}' | tr -d ' ')
CPUS=$(nproc)
 
echo "  $UPTIME"
echo ""
echo -e "  CPUs disponibles: ${BOLD}$CPUS${NC}"
echo -e "  Load avg: ${BOLD}$LOAD1 / $LOAD5 / $LOAD15${NC} (1m / 5m / 15m)"
 
LOAD_INT=${LOAD1%.*}
if [ "$LOAD_INT" -gt "$CPUS" ]; then
    crit "Load supera el número de CPUs ($CPUS) — sistema bajo presión"
elif [ "$LOAD_INT" -gt $((CPUS / 2)) ]; then
    warn "Load elevado (> 50% de CPUs disponibles)"
else
    ok "Load dentro de rangos normales"
fi
 
# -----------------------------------------------------------------------------
section "MEMORIA"
# -----------------------------------------------------------------------------
free -h
echo ""
MEM_AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
MEM_TOTAL_MB=$(free -m | awk '/^Mem:/ {print $2}')
MEM_PCT=$(( (MEM_TOTAL_MB - MEM_AVAIL_MB) * 100 / MEM_TOTAL_MB ))
SWAP_USED=$(free -m | awk '/^Swap:/ {print $3}')
 
echo -e "  Uso de memoria: ${BOLD}${MEM_PCT}%${NC}"
 
if [ "$SWAP_USED" -gt 0 ]; then
    crit "Swap en uso: ${SWAP_USED}MB — riesgo de degradación severa en VMs"
elif [ "$MEM_PCT" -gt 90 ]; then
    warn "Memoria al ${MEM_PCT}% — margen muy ajustado"
elif [ "$MEM_PCT" -gt 75 ]; then
    warn "Memoria al ${MEM_PCT}% — monitorear"
else
    ok "Memoria OK (${MEM_PCT}% usado)"
fi
 
# -----------------------------------------------------------------------------
section "TOP $TOP_VMS VMs POR CPU"
# -----------------------------------------------------------------------------
echo -e "  ${BOLD}%CPU   %MEM   PID      NOMBRE DE VM${NC}"
echo "  $SEP"
 
ps aux --sort=-%cpu | grep -w qemu-kvm | grep -v grep | head -$TOP_VMS | \
while IFS= read -r line; do
    PID=$(echo "$line" | awk '{print $2}')
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')
    if [ -f /proc/$PID/cmdline ]; then
        VMNAME=$(tr '\0' '\n' < /proc/$PID/cmdline 2>/dev/null | grep "guest=" | sed 's/.*guest=//' | cut -d',' -f1)
        [ -z "$VMNAME" ] && VMNAME="(sin nombre)"
        printf "  %-6s %-6s %-8s %s\n" "$CPU" "$MEM" "$PID" "$VMNAME"
    fi
done
 
# -----------------------------------------------------------------------------
section "TOP $TOP_VMS VMs POR MEMORIA"
# -----------------------------------------------------------------------------
echo -e "  ${BOLD}%MEM   %CPU   PID      NOMBRE DE VM${NC}"
echo "  $SEP"
 
ps aux --sort=-%mem | grep -w qemu-kvm | grep -v grep | head -$TOP_VMS | \
while IFS= read -r line; do
    PID=$(echo "$line" | awk '{print $2}')
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')
    if [ -f /proc/$PID/cmdline ]; then
        VMNAME=$(tr '\0' '\n' < /proc/$PID/cmdline 2>/dev/null | grep "guest=" | sed 's/.*guest=//' | cut -d',' -f1)
        [ -z "$VMNAME" ] && VMNAME="(sin nombre)"
        printf "  %-6s %-6s %-8s %s\n" "$MEM" "$CPU" "$PID" "$VMNAME"
    fi
done
 
# -----------------------------------------------------------------------------
section "I/O DE DISCOS (${IOSTAT_COUNT} muestras)"
# -----------------------------------------------------------------------------
echo -e "  ${YELLOW}Recolectando muestras de iostat (${IOSTAT_INT}s x ${IOSTAT_COUNT})...${NC}"
echo ""
 
iostat -x $IOSTAT_INT $IOSTAT_COUNT | grep -v "^$" | tail -n +4
 
# Alerta si algún disco tiene await alto en la última muestra
HIGH_AWAIT=$(iostat -x $IOSTAT_INT 2 | tail -20 | awk 'NR>1 && /^[a-z]/ {if ($10+0 > 500 || $11+0 > 500) print $1, "r_await="$10, "w_await="$11}')
if [ -n "$HIGH_AWAIT" ]; then
    crit "Latencia alta detectada:"
    echo "$HIGH_AWAIT" | while read l; do echo "     $l"; done
else
    ok "Latencias de I/O dentro de rangos normales"
fi
 
# -----------------------------------------------------------------------------
section "ESTADO DEL CONTROLADOR MEGARAID"
# -----------------------------------------------------------------------------
if [ ! -f "$STORCLI" ]; then
    warn "storcli64 no encontrado en $STORCLI"
else
    # --- Virtual Drives ---
    echo -e "  ${BOLD}Virtual Drives:${NC}"
    VD_OUTPUT=$($STORCLI $CTRL /vall show)
    echo "$VD_OUTPUT" | awk '/^[0-9]/{print "  "$0}'
    echo ""
 
    DEGRADED=$(echo "$VD_OUTPUT" | awk '/^[0-9]/ && /Pdgd|Dgrd|OfLn/')
    if [ -n "$DEGRADED" ]; then
        crit "Hay Virtual Drives degradados o fuera de línea:"
        echo "$DEGRADED" | while read l; do echo "     $l"; done
    else
        ok "Todos los Virtual Drives en estado Optimal"
    fi
 
    # --- Discos físicos (estado) ---
    echo ""
    echo -e "  ${BOLD}Discos físicos:${NC}"
    PD_OUTPUT=$($STORCLI $CTRL /eall /sall show)
    echo "$PD_OUTPUT" | awk '/^[0-9]/{print "  "$0}'
    echo ""
 
    BAD_PD=$(echo "$PD_OUTPUT" | awk '/^[0-9]/ && /Offln|UBad|Failed/')
    RBLD_PD=$(echo "$PD_OUTPUT" | awk '/^[0-9]/ && /Rbld/')
 
    if [ -n "$BAD_PD" ]; then
        crit "Discos físicos en estado crítico:"
        echo "$BAD_PD" | while read l; do echo "     $l"; done
    else
        ok "Todos los discos físicos Online"
    fi
 
    # --- Rebuild en progreso ---
    if [ -n "$RBLD_PD" ]; then
        warn "Disco(s) en proceso de rebuild:"
        echo "$RBLD_PD" | while read l; do echo "     $l"; done
        echo ""
 
        FIRST_RBLD=$(echo "$RBLD_PD" | head -1)
        EID=$(echo "$FIRST_RBLD" | awk '{print $1}' | cut -d: -f1)
        SLT=$(echo "$FIRST_RBLD" | awk '{print $1}' | cut -d: -f2)
 
        if [[ "$EID" =~ ^[0-9]+$ ]] && [[ "$SLT" =~ ^[0-9]+$ ]]; then
            echo -e "  ${BOLD}Progreso rebuild e${EID}/s${SLT}:${NC}"
            $STORCLI ${CTRL}/e${EID}/s${SLT} show rebuild 2>/dev/null | grep -E "Rebuild|Progress|%"
        fi
    fi
 
    # -------------------------------------------------------------------------
    # FIRMWARE DE DISCOS FÍSICOS
    # Extrae por cada disco: EID:Slot, modelo, firmware revision y temperatura.
    # Si EXPECTED_FW está definido, valida que todos coincidan con ese baseline.
    # -------------------------------------------------------------------------
    echo ""
    echo -e "  ${BOLD}Firmware de discos físicos:${NC}"
    printf "  %-10s %-40s %-12s %-8s\n" "EID:Slt" "Modelo" "Firmware" "Temp(C)"
    echo "  $SEP"
 
    # Obtener lista de EID:Slot desde el listado general (solo líneas numéricas)
    DISK_LIST=$(echo "$PD_OUTPUT" | awk '/^[0-9]+:[0-9]+/{print $1}')
 
    FW_MISMATCH=0
    FW_MISSING=0
    declare -A FW_MAP   # acumula firmware por versión para resumen al final
 
    while IFS= read -r DISK; do
        [[ -z "$DISK" ]] && continue
 
        EID_D=$(echo "$DISK" | cut -d: -f1)
        SLT_D=$(echo "$DISK" | cut -d: -f2)
 
        # storcli /c0/eX/sY show all — fuente canónica de FW y modelo
        DETAIL=$($STORCLI ${CTRL}/e${EID_D}/s${SLT_D} show all 2>/dev/null)
 
        # Modelo: campo "Model Number" o "Drive" según versión de storcli
        MODEL=$(echo "$DETAIL" | grep -E "^Model Number|^Drive " | head -1 | \
                awk -F'=' '{print $2}' | sed 's/^ *//')
        [ -z "$MODEL" ] && MODEL=$(echo "$DETAIL" | grep "^Inquiry Data" | \
                awk -F'=' '{print $2}' | awk '{print $1, $2}' | sed 's/^ *//')
        [ -z "$MODEL" ] && MODEL="(desconocido)"
 
        # Firmware Revision
        FW=$(echo "$DETAIL" | grep -E "^Firmware Revision|^FW Version" | \
             head -1 | awk -F'=' '{print $2}' | tr -d ' ')
        [ -z "$FW" ] && FW=$(echo "$DETAIL" | grep "Firmware Level" | \
             head -1 | awk -F'=' '{print $2}' | tr -d ' ')
 
        # Temperatura (Drive Temperature field)
        TEMP=$(echo "$DETAIL" | grep -E "^Drive Temperature" | \
               head -1 | awk -F'=' '{print $2}' | grep -o '[0-9]\+' | head -1)
        [ -z "$TEMP" ] && TEMP="N/A"
 
        if [ -z "$FW" ]; then
            FW="(no disponible)"
            FW_MISSING=$((FW_MISSING + 1))
            printf "  %-10s %-40s ${YELLOW}%-12s${NC} %-8s\n" \
                "$DISK" "${MODEL:0:39}" "$FW" "$TEMP"
        else
            # Acumular versiones para el resumen
            FW_MAP["$FW"]=$((${FW_MAP["$FW"]:-0} + 1))
 
            # Validar contra baseline si está definido
            if [ -n "$EXPECTED_FW" ] && [ "$FW" != "$EXPECTED_FW" ]; then
                FW_MISMATCH=$((FW_MISMATCH + 1))
                printf "  %-10s %-40s ${RED}%-12s${NC} %-8s\n" \
                    "$DISK" "${MODEL:0:39}" "$FW" "$TEMP"
            else
                printf "  %-10s %-40s ${GREEN}%-12s${NC} %-8s\n" \
                    "$DISK" "${MODEL:0:39}" "$FW" "$TEMP"
            fi
        fi
 
    done <<< "$DISK_LIST"
 
    # Resumen de versiones encontradas
    echo ""
    echo -e "  ${BOLD}Resumen de versiones de firmware:${NC}"
    for VER in "${!FW_MAP[@]}"; do
        COUNT=${FW_MAP[$VER]}
        printf "  %-12s → %d disco(s)\n" "$VER" "$COUNT"
    done | sort
 
    # Alertas de firmware
    UNIQUE_FW=$(echo "${!FW_MAP[@]}" | wc -w)
    if [ "$FW_MISSING" -gt 0 ]; then
        warn "$FW_MISSING disco(s) no reportaron firmware — revisar con 'storcli64 /c0/eX/sY show all'"
    fi
    if [ "$UNIQUE_FW" -gt 1 ]; then
        warn "Versiones de firmware mixtas ($UNIQUE_FW versiones distintas) — homogeneizar"
    fi
    if [ -n "$EXPECTED_FW" ] && [ "$FW_MISMATCH" -gt 0 ]; then
        crit "$FW_MISMATCH disco(s) NO coinciden con el firmware baseline ($EXPECTED_FW)"
    elif [ -n "$EXPECTED_FW" ] && [ "$FW_MISMATCH" -eq 0 ]; then
        ok "Todos los discos en firmware baseline ($EXPECTED_FW)"
    fi
    if [ "$UNIQUE_FW" -eq 1 ] && [ "$FW_MISSING" -eq 0 ] && [ -z "$EXPECTED_FW" ]; then
        ok "Firmware homogéneo en todos los discos (${!FW_MAP[*]})"
    fi
 
    # --- BBU ---
    echo ""
    echo -e "  ${BOLD}Estado BBU/CacheVault:${NC}"
    BBU_OUTPUT=$($STORCLI $CTRL show all)
    echo "$BBU_OUTPUT" | grep -E "^BBU Status|^BBU =|^CacheVault Flash|^Write Policy|^Current Size of FW" | head -8
 
    BBU_STATUS=$(echo "$BBU_OUTPUT" | awk '/^BBU Status/{print $NF}')
    if [ "$BBU_STATUS" = "0" ]; then
        ok "BBU OK (Status=0)"
    else
        crit "BBU con problemas (Status=$BBU_STATUS) — verificar política de caché"
    fi
 
    # --- Eventos recientes ---
    echo ""
    echo -e "  ${BOLD}Eventos de warning recientes:${NC}"
    EVENTS=$($STORCLI $CTRL show events type=warning 2>/dev/null | \
        grep "Event Description:" | \
        grep -iE "Command timeout|Unexpected sense|Offline|link speed changed" | \
        tail -10)
    if [ -n "$EVENTS" ]; then
        crit "Eventos de warning detectados:"
        echo "$EVENTS" | while read l; do echo "     $l"; done
    else
        ok "Sin eventos de warning recientes"
    fi
fi
 
# -----------------------------------------------------------------------------
section "ERRORES EN KERNEL (dmesg)"
# -----------------------------------------------------------------------------
DMESG_ERRORS=$(dmesg | grep -iE "I/O error|exception|scsi error|ata.*error|reset.*ata" | tail -10)
if [ -n "$DMESG_ERRORS" ]; then
    crit "Errores de I/O en dmesg:"
    echo "$DMESG_ERRORS" | while read l; do echo "     $l"; done
else
    ok "dmesg sin errores de I/O"
fi
 
# -----------------------------------------------------------------------------
header "FIN DEL DIAGNÓSTICO — $(date '+%H:%M:%S')"
# -----------------------------------------------------------------------------
echo ""
 
