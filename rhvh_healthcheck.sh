#!/bin/bash
# =============================================================================
# rhvh_healthcheck.sh — KVM Hypervisor + MegaRAID Health Check
# =============================================================================

STORCLI="/opt/MegaRAID/storcli/storcli64"
CTRL="/c0"
TOP_VMS=5       # cuántas VMs mostrar en el ranking
IOSTAT_INT=2    # intervalo de iostat en segundos
IOSTAT_COUNT=3  # número de muestras de iostat

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

while IFS= read -r line; do
    PID=$(echo "$line" | awk '{print $2}')
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')
    if [ -f /proc/$PID/cmdline ]; then
        VMNAME=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' '\n' | grep "guest=" | sed 's/.*guest=//' | cut -d',' -f1)
        [ -z "$VMNAME" ] && VMNAME="(sin nombre)"
        printf "  %-6s %-6s %-8s %s\n" "$CPU" "$MEM" "$PID" "$VMNAME"
    fi
done < <(ps aux --sort=-%cpu | grep qemu-kvm | grep -v grep | head -$TOP_VMS)

# -----------------------------------------------------------------------------
section "TOP $TOP_VMS VMs POR MEMORIA"
# -----------------------------------------------------------------------------
echo -e "  ${BOLD}%MEM   %CPU   PID      NOMBRE DE VM${NC}"
echo "  $SEP"

while IFS= read -r line; do
    PID=$(echo "$line" | awk '{print $2}')
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')
    if [ -f /proc/$PID/cmdline ]; then
        VMNAME=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' '\n' | grep "guest=" | sed 's/.*guest=//' | cut -d',' -f1)
        [ -z "$VMNAME" ] && VMNAME="(sin nombre)"
        printf "  %-6s %-6s %-8s %s\n" "$MEM" "$CPU" "$PID" "$VMNAME"
    fi
done < <(ps aux --sort=-%mem | grep qemu-kvm | grep -v grep | head -$TOP_VMS)

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
    # VDs
    echo -e "  ${BOLD}Virtual Drives:${NC}"
    $STORCLI $CTRL /vall show | grep -E "DG/VD|RAID|Optl|Pdgd|Dgrd|OfLn" | grep -v "^$"
    echo ""

    # Revisar estado de VDs
    DEGRADED=$($STORCLI $CTRL /vall show | grep -E "Pdgd|Dgrd|OfLn" | grep -v "^#")
    if [ -n "$DEGRADED" ]; then
        crit "Hay Virtual Drives degradados o fuera de línea:"
        echo "$DEGRADED" | while read l; do echo "     $l"; done
    else
        ok "Todos los Virtual Drives en estado Optimal"
    fi

    # Discos físicos
    echo ""
    echo -e "  ${BOLD}Discos físicos:${NC}"
    $STORCLI $CTRL /eall /sall show | grep -E "^[0-9]"
    echo ""

    # Discos con estado problemático
    BAD_PD=$($STORCLI $CTRL /eall /sall show | grep -E "Offln|UBad|Failed" | grep -v "^#")
    RBLD_PD=$($STORCLI $CTRL /eall /sall show | grep "Rbld")

    if [ -n "$BAD_PD" ]; then
        crit "Discos físicos en estado crítico:"
        echo "$BAD_PD" | while read l; do echo "     $l"; done
    else
        ok "Todos los discos físicos Online"
    fi

    if [ -n "$RBLD_PD" ]; then
        warn "Disco(s) en proceso de rebuild:"
        echo "$RBLD_PD" | while read l; do echo "     $l"; done
        echo ""

        # Progreso del rebuild
        RBLD_SLOT=$(echo "$RBLD_PD" | awk '{print $1}' | head -1 | sed 's/:/\/e/' | sed 's/\//\/e/' )
        EID=$(echo "$RBLD_PD" | awk '{print $1}' | head -1 | cut -d: -f1)
        SLT=$(echo "$RBLD_PD" | awk '{print $1}' | head -1 | cut -d: -f2)
        echo -e "  ${BOLD}Progreso rebuild e${EID}/s${SLT}:${NC}"
        $STORCLI $CTRL/e${EID}/s${SLT} show rebuild 2>/dev/null || \
            $STORCLI $CTRL/e${EID}/s${SLT} show all | grep -iE "rebuild|progress"
    fi

    # BBU
    echo ""
    echo -e "  ${BOLD}Estado BBU/CacheVault:${NC}"
    $STORCLI $CTRL show all | grep -E "BBU Status|BBU =|CacheVault|Write Policy|FW Cache" | grep -v "^#" | head -8

    BBU_STATUS=$($STORCLI $CTRL show all | grep "BBU Status" | awk '{print $NF}')
    if [ "$BBU_STATUS" = "0" ]; then
        ok "BBU OK (Status=0)"
    else
        crit "BBU con problemas (Status=$BBU_STATUS) — verificar política de caché"
    fi

    # Eventos recientes
    echo ""
    echo -e "  ${BOLD}Eventos de warning recientes:${NC}"
    EVENTS=$($STORCLI $CTRL show events type=warning 2>/dev/null | grep -E "Command timeout|reset|Unexpected sense|Offline" | tail -10)
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
