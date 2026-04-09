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
    # FIX 1: solo líneas que empiezan con dígito (evita capturar el glosario)
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

    # --- Discos físicos ---
    # FIX 2: solo líneas que empiezan con dígito (evita capturar el glosario)
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

        # FIX 3: extraer EID y Slot correctamente y validar que son números
        FIRST_RBLD=$(echo "$RBLD_PD" | head -1)
        EID=$(echo "$FIRST_RBLD" | awk '{print $1}' | cut -d: -f1)
        SLT=$(echo "$FIRST_RBLD" | awk '{print $1}' | cut -d: -f2)

        if [[ "$EID" =~ ^[0-9]+$ ]] && [[ "$SLT" =~ ^[0-9]+$ ]]; then
            echo -e "  ${BOLD}Progreso rebuild e${EID}/s${SLT}:${NC}"
            $STORCLI ${CTRL}/e${EID}/s${SLT} show rebuild 2>/dev/null | grep -E "Rebuild|Progress|%"
        fi
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
    # FIX 4: filtrar solo líneas "Event Description:" para evitar capturar texto de ayuda
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
section "HARDWARE — SALUD DEL CHASSIS"
# -----------------------------------------------------------------------------
if ! command -v ipmitool &>/dev/null; then
    warn "ipmitool no disponible — omitiendo checks de hardware"
else
    # --- Chassis ---
    echo -e "  ${BOLD}Estado del Chassis:${NC}"
    CHASSIS=$(ipmitool chassis status 2>/dev/null)
    PWR_FAULT=$(echo "$CHASSIS"   | awk '/Power Overload/{print $NF}')
    MAIN_FAULT=$(echo "$CHASSIS"  | awk '/Main Power Fault/{print $NF}')
    COOL_FAULT=$(echo "$CHASSIS"  | awk '/Cooling.*Fault/{print $NF}')
    DRIVE_FAULT=$(echo "$CHASSIS" | awk '/Drive Fault/{print $NF}')

    [ "$PWR_FAULT"   = "false" ] && ok   "Power Overload:    false" || crit "Power Overload:    $PWR_FAULT"
    [ "$MAIN_FAULT"  = "false" ] && ok   "Main Power Fault:  false" || crit "Main Power Fault:  $MAIN_FAULT"
    [ "$COOL_FAULT"  = "false" ] && ok   "Cooling/Fan Fault: false" || crit "Cooling/Fan Fault: $COOL_FAULT"
    [ "$DRIVE_FAULT" = "false" ] && ok   "Drive Fault:       false" || crit "Drive Fault:       $DRIVE_FAULT"

    # --- Temperaturas ---
    echo ""
    echo -e "  ${BOLD}Temperaturas:${NC}"
    ipmitool sdr type Temperature 2>/dev/null | grep -v "ns\|Disabled" | \
        awk '{printf "  %-20s %s\n", $1, $0}' | \
        awk -F'|' '{printf "  %-25s %s\n", $1, $3}' | grep -v "^  $"

    # Alerta si alguna temperatura supera 70°C
    HIGH_TEMP=$(ipmitool sdr type Temperature 2>/dev/null | \
        awk -F'|' '/degrees/{gsub(/ /,"",$3); split($3,a," "); if(a[1]+0 > 70) print $1" → "a[1]"°C"}')
    [ -n "$HIGH_TEMP" ] && crit "Temperatura crítica detectada: $HIGH_TEMP" || ok "Todas las temperaturas dentro del rango normal"

    # --- Fans ---
    echo ""
    echo -e "  ${BOLD}Ventiladores:${NC}"
    FAN_REDUND=$(ipmitool sdr type Fan 2>/dev/null | grep -i "Redundancy" | awk -F'|' '{print $3}' | tr -d ' ')
    FAN_FAIL=$(ipmitool sdr type Fan 2>/dev/null | grep -iv "ok\|redundancy\|^$")

    ipmitool sdr type Fan 2>/dev/null | grep -iv "redundancy" | \
        awk -F'|' 'NF>2{printf "  %-12s %s\n", $1, $3}'

    echo ""
    if echo "$FAN_REDUND" | grep -qi "Full"; then
        ok "Fan Redundancy: Fully Redundant"
    else
        warn "Fan Redundancy: $FAN_REDUND"
    fi
    [ -n "$FAN_FAIL" ] && crit "Fans con problemas detectados" || ok "Todos los fans operando correctamente"

    # --- Fuentes de alimentación ---
    echo ""
    echo -e "  ${BOLD}Fuentes de alimentación (PSU):${NC}"
    PSU_OUTPUT=$(ipmitool sdr type "Power Supply" 2>/dev/null)
    PSU_REDUND=$(echo "$PSU_OUTPUT" | grep -i "Redundancy" | awk -F'|' '{print $3}' | tr -d ' ')
    echo "$PSU_OUTPUT" | awk -F'|' 'NF>2{printf "  %-25s %s\n", $1, $3}'
    echo ""
    if echo "$PSU_REDUND" | grep -qi "Full"; then
        ok "PSU Redundancy: Fully Redundant"
    else
        crit "PSU Redundancy: $PSU_REDUND — revisar fuentes de alimentación"
    fi

    # --- Voltajes críticos ---
    echo ""
    echo -e "  ${BOLD}Voltajes de línea:${NC}"
    ipmitool sdr type Voltage 2>/dev/null | grep -iE "^Voltage [0-9]" | \
        awk -F'|' '{printf "  %-20s %s\n", $1, $3}'

    VOLT_FAIL=$(ipmitool sdr type Voltage 2>/dev/null | grep -iv "ok\|deasserted\|^$" | grep -v "ns")
    [ -n "$VOLT_FAIL" ] && crit "Problema de voltaje detectado:" && \
        echo "$VOLT_FAIL" | while read l; do echo "     $l"; done || ok "Voltajes dentro de rango normal"

    # --- Eventos críticos del SEL ---
    echo ""
    echo -e "  ${BOLD}Eventos críticos del hardware (SEL):${NC}"
    SEL_EVENTS=$(ipmitool sel elist 2>/dev/null | \
        grep -iE "critical|fail|error|assert|deassert" | tail -10)

    # Alertas específicas de discos desconectándose
    DRIVE_EVENTS=$(ipmitool sel elist 2>/dev/null | \
        grep -i "Drive Slot\|Drive Present.*Deasserted" | tail -10)

    if [ -n "$DRIVE_EVENTS" ]; then
        crit "Eventos de desconexión de discos detectados:"
        echo "$DRIVE_EVENTS" | while read l; do echo "     $l"; done
    else
        ok "Sin eventos de desconexión de discos"
    fi

    if [ -n "$SEL_EVENTS" ]; then
        echo ""
        warn "Últimos eventos en el SEL:"
        echo "$SEL_EVENTS" | while read l; do echo "     $l"; done
    else
        ok "SEL sin eventos críticos recientes"
    fi

    # --- Consumo de energía ---
    echo ""
    PWR_CONSUMPTION=$(ipmitool sdr 2>/dev/null | grep -i "Pwr Consumption" | awk -F'|' '{print $2}' | tr -d ' ')
    [ -n "$PWR_CONSUMPTION" ] && echo -e "  Consumo actual: ${BOLD}${PWR_CONSUMPTION}${NC}"
fi

# -----------------------------------------------------------------------------
header "FIN DEL DIAGNÓSTICO — $(date '+%H:%M:%S')"
# -----------------------------------------------------------------------------
echo ""
