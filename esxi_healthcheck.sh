#!/bin/sh
# =============================================================================
# esxi_healthcheck.sh — ESXi 8.x Host Health Check
# Ejecutar via SSH: ssh root@esxi-host 'sh -s' < esxi_healthcheck.sh
# O desde GitHub: curl -s https://raw.githubusercontent.com/.../esxi_healthcheck.sh | sh
# =============================================================================

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SEP="────────────────────────────────────────────────────────────"

header() {
    echo "\n${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo "${CYAN}${BOLD}  $1${NC}"
    echo "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
}

section() {
    echo "\n${BOLD}── $1 ──────────────────────────────────────────────────────${NC}"
}

ok()   { echo "  ${GREEN}✔${NC}  $1"; }
warn() { echo "  ${YELLOW}⚠${NC}  $1"; }
crit() { echo "  ${RED}✘${NC}  $1"; }

# =============================================================================
header "ESXI HEALTH CHECK — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
# =============================================================================

# -----------------------------------------------------------------------------
section "INFORMACION DEL HOST"
# -----------------------------------------------------------------------------
echo "  $(esxcli system version get | grep -E 'Version|Build|Release')"
echo ""
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
UPTIME_H=$(( UPTIME_SEC / 3600 ))
UPTIME_M=$(( (UPTIME_SEC % 3600) / 60 ))
echo "  Uptime: ${UPTIME_H}h ${UPTIME_M}m"
echo "  UUID: $(esxcli system uuid get 2>/dev/null)"

# -----------------------------------------------------------------------------
section "CPU"
# -----------------------------------------------------------------------------
CPU_INFO=$(esxcli hardware cpu global get 2>/dev/null)
echo "$CPU_INFO" | grep -E "CPU Packages|CPU Cores|CPU Threads|Hz" | awk '{printf "  %s\n", $0}'
echo ""

# Uso de CPU via esxtop en modo batch (1 muestra, 1 segundo)
CPU_USAGE=$(esxtop -b -n 1 -d 1 2>/dev/null | awk -F',' 'NR==1{for(i=1;i<=NF;i++) if($i~/%Used/) col=i} NR==2{printf "%.1f", $col}' 2>/dev/null)
if [ -n "$CPU_USAGE" ]; then
    echo "  Uso CPU total: ${BOLD}${CPU_USAGE}%${NC}"
    CPU_INT=${CPU_USAGE%.*}
    if [ "$CPU_INT" -gt 90 ]; then
        crit "CPU al ${CPU_USAGE}% — critico"
    elif [ "$CPU_INT" -gt 70 ]; then
        warn "CPU al ${CPU_USAGE}% — elevado"
    else
        ok "CPU dentro de rangos normales (${CPU_USAGE}%)"
    fi
else
    # Fallback: via vsish
    esxcli hardware cpu list 2>/dev/null | grep -c "CPU:" | \
        awk '{printf "  CPUs logicas: %s\n", $0}'
    ok "Uso en tiempo real no disponible (usa esxtop interactivo)"
fi

# -----------------------------------------------------------------------------
section "MEMORIA"
# -----------------------------------------------------------------------------
MEM_INFO=$(esxcli hardware memory get 2>/dev/null)
MEM_TOTAL_KB=$(echo "$MEM_INFO" | grep "Physical Memory" | grep -oE '[0-9]+' | head -1)
MEM_TOTAL_GB=$(( MEM_TOTAL_KB / 1024 / 1024 ))

echo "  Memoria fisica total: ${BOLD}${MEM_TOTAL_GB} GB${NC}"
echo ""

# Memoria via memstats
MEM_STATS=$(vsish -e get /memory/comprehensive 2>/dev/null)
if [ -n "$MEM_STATS" ]; then
    echo "$MEM_STATS" | grep -iE "total|free|used|overhead" | head -8 | awk '{printf "  %s\n", $0}'
else
    # Fallback via /proc/meminfo si existe
    if [ -f /proc/meminfo ]; then
        MEM_FREE_KB=$(awk '/MemFree/{print $2}' /proc/meminfo)
        MEM_TOTAL_KB2=$(awk '/MemTotal/{print $2}' /proc/meminfo)
        MEM_USED_KB=$(( MEM_TOTAL_KB2 - MEM_FREE_KB ))
        MEM_PCT=$(( MEM_USED_KB * 100 / MEM_TOTAL_KB2 ))
        printf "  Usado: %d MB / %d MB (%d%%)\n" \
            "$(( MEM_USED_KB/1024 ))" "$(( MEM_TOTAL_KB2/1024 ))" "$MEM_PCT"
        if [ "$MEM_PCT" -gt 90 ]; then
            crit "Memoria al ${MEM_PCT}% — critico"
        elif [ "$MEM_PCT" -gt 80 ]; then
            warn "Memoria al ${MEM_PCT}% — monitorear"
        else
            ok "Memoria OK (${MEM_PCT}% usado)"
        fi
    fi
fi

# -----------------------------------------------------------------------------
section "STORAGE — DISCOS FISICOS"
# -----------------------------------------------------------------------------
echo "  ${BOLD}Dispositivos de almacenamiento:${NC}"
esxcli storage core device list 2>/dev/null | \
    awk '/^[a-zA-Z]/{dev=$0} /Display Name/{name=$0} /Size/{size=$0} /State/{
        printf "  %-40s %s  %s\n", dev, size, $0
    }' | head -30

echo ""

# Estado de salud de discos via SMART
echo "  ${BOLD}Estado SMART de discos:${NC}"
for DEV in $(esxcli storage core device list 2>/dev/null | grep "^[a-z]" | awk '{print $1}'); do
    HEALTH=$(esxcli storage core device smart get -d "$DEV" 2>/dev/null | \
        grep -iE "Health Status|Drive Failure" | head -2)
    if [ -n "$HEALTH" ]; then
        STATUS=$(echo "$HEALTH" | grep -i "Health Status" | awk -F: '{print $2}' | tr -d ' ')
        if echo "$STATUS" | grep -qi "OK\|Healthy\|Normal"; then
            ok "$DEV — $STATUS"
        else
            crit "$DEV — $STATUS"
        fi
    fi
done

# -----------------------------------------------------------------------------
section "STORAGE — DATASTORES"
# -----------------------------------------------------------------------------
echo "  ${BOLD}Datastores:${NC}"
printf "  ${BOLD}%-35s %-12s %-12s %-8s %s${NC}\n" "NOMBRE" "CAPACIDAD" "LIBRE" "USO%" "TIPO"
printf "  %0.s-" {1..80}; echo ""

esxcli storage filesystem list 2>/dev/null | awk 'NR>2 && NF>3 {
    name=$1
    type=$NF
    # capacidad y libre en bytes
    cap=0; free=0
    for(i=1;i<=NF;i++){
        if($i~/^[0-9]+$/ && cap==0) cap=$i
        else if($i~/^[0-9]+$/ && free==0) free=$i
    }
    if(cap>0){
        cap_gb=cap/1024/1024/1024
        free_gb=free/1024/1024/1024
        used_pct=int((cap-free)*100/cap)
        printf "  %-35s %-12.1f %-12.1f %-8s %s\n", name, cap_gb, free_gb, used_pct"%", type
    }
}'

echo ""
# Alertas de espacio
esxcli storage filesystem list 2>/dev/null | awk 'NR>2 && NF>3 {
    name=$1; cap=0; free=0
    for(i=1;i<=NF;i++){
        if($i~/^[0-9]+$/ && cap==0) cap=$i
        else if($i~/^[0-9]+$/ && free==0) free=$i
    }
    if(cap>0){
        used_pct=int((cap-free)*100/cap)
        if(used_pct>=90) print "CRIT|" name "|" used_pct
        else if(used_pct>=75) print "WARN|" name "|" used_pct
    }
}' | while IFS='|' read LEVEL DS PCT; do
    [ "$LEVEL" = "CRIT" ] && crit "Datastore '$DS' al ${PCT}% — espacio critico"
    [ "$LEVEL" = "WARN" ] && warn "Datastore '$DS' al ${PCT}% — monitorear espacio"
done

# -----------------------------------------------------------------------------
section "RED"
# -----------------------------------------------------------------------------
echo "  ${BOLD}Interfaces de red (vmnic):${NC}"
printf "  ${BOLD}%-12s %-12s %-20s %-10s %s${NC}\n" "NOMBRE" "VELOCIDAD" "MAC" "ESTADO" "DRIVER"
printf "  %0.s-" {1..75}; echo ""

esxcli network nic list 2>/dev/null | awk 'NR>2 && NF>0 {
    printf "  %-12s %-12s %-20s %-10s %s\n", $1, $3, $4, $2, $7
}'

echo ""

# NICs con link down
NIC_DOWN=$(esxcli network nic list 2>/dev/null | awk 'NR>2 && /Down/{print $1}')
if [ -n "$NIC_DOWN" ]; then
    warn "NICs sin link:"
    echo "$NIC_DOWN" | while read n; do echo "     $n — Link Down"; done
else
    ok "Todos los NICs activos"
fi

echo ""

# vSwitches
echo "  ${BOLD}vSwitches:${NC}"
esxcli network vswitch standard list 2>/dev/null | \
    grep -E "^[a-zA-Z]|Uplinks|Portgroups|MTU" | \
    awk '/^[a-zA-Z]/{vs=$0} /Uplinks/{ul=$0} /Portgroups/{pg=$0} /MTU/{
        printf "  %-20s  %s  %s  MTU:%s\n", vs, ul, pg, $NF
    }'

# -----------------------------------------------------------------------------
section "HARDWARE — SALUD GENERAL"
# -----------------------------------------------------------------------------
echo "  ${BOLD}Sensores de hardware:${NC}"

# Temperatura
esxcli hardware ipmi sdr list 2>/dev/null | grep -iE "temp|fan" | \
    awk '{printf "  %-35s %s %s\n", $1, $NF, $(NF-1)}' | head -15

echo ""

# IPMI / BMC status
IPMI_STATUS=$(esxcli hardware ipmi bmc get 2>/dev/null)
if [ -n "$IPMI_STATUS" ]; then
    echo "  ${BOLD}BMC/IPMI:${NC}"
    echo "$IPMI_STATUS" | awk '{printf "  %s\n", $0}' | head -5
    ok "BMC accesible"
else
    warn "BMC/IPMI no disponible o no configurado"
fi

# -----------------------------------------------------------------------------
section "VMs — RESUMEN RAPIDO"
# -----------------------------------------------------------------------------
# Solo conteo via vim-cmd, sin iterar por VM (evita lentitud)
VM_LIST=$(vim-cmd vmsvc/getallvms 2>/dev/null | awk 'NR>1 && NF>0')
TOTAL_VMS=$(echo "$VM_LIST" | grep -c "." 2>/dev/null || echo 0)

echo "  Total VMs registradas: ${BOLD}${TOTAL_VMS}${NC}"
echo ""

# Estado de VMs via powerstate (una sola llamada por VM pero solo ID numérico)
POWERED_ON=0; POWERED_OFF=0; SUSPENDED=0
for VMID in $(echo "$VM_LIST" | awk '{print $1}' | grep '^[0-9]'); do
    STATE=$(vim-cmd vmsvc/power.getstate "$VMID" 2>/dev/null | grep -v "^Retrieved" | tr -d ' \n')
    case "$STATE" in
        *poweredon*)  POWERED_ON=$(( POWERED_ON + 1 )) ;;
        *poweredoff*) POWERED_OFF=$(( POWERED_OFF + 1 )) ;;
        *suspended*)  SUSPENDED=$(( SUSPENDED + 1 )) ;;
    esac
done

printf "  %-16s %s\n" "Powered On:"  "$POWERED_ON"
printf "  %-16s %s\n" "Powered Off:" "$POWERED_OFF"
[ "$SUSPENDED" -gt 0 ] && warn "Suspended: $SUSPENDED VM(s)"

echo ""

# VMs con snapshots via find (rápido, no usa virsh)
echo "  ${BOLD}VMs con snapshots (-delta.vmdk detectados):${NC}"
SNAP_COUNT=$(find /vmfs/volumes -name "*-delta.vmdk" 2>/dev/null | wc -l)
if [ "$SNAP_COUNT" -gt 0 ]; then
    warn "$SNAP_COUNT archivo(s) delta encontrado(s) — hay snapshots activos"
    find /vmfs/volumes -name "*-delta.vmdk" 2>/dev/null | \
        awk -F/ '{printf "     %s → %s\n", $4, $NF}' | head -10
else
    ok "No se detectaron snapshots activos"
fi

# -----------------------------------------------------------------------------
section "LOGS RECIENTES DE ERRORES"
# -----------------------------------------------------------------------------
echo "  ${BOLD}Ultimas entradas criticas en vmkernel.log:${NC}"
VMKERNEL_ERRS=$(grep -iE "SCSI error|NMP|timeout|failed|lost redundancy|APD|PDL" \
    /var/log/vmkernel.log 2>/dev/null | tail -10)
if [ -n "$VMKERNEL_ERRS" ]; then
    crit "Errores detectados en vmkernel.log:"
    echo "$VMKERNEL_ERRS" | while read l; do echo "     $l"; done
else
    ok "vmkernel.log sin errores recientes"
fi

echo ""
echo "  ${BOLD}Ultimas entradas criticas en hostd.log:${NC}"
HOSTD_ERRS=$(grep -iE "error|fault|failed|critical" \
    /var/log/hostd.log 2>/dev/null | grep -v "^#" | tail -5)
if [ -n "$HOSTD_ERRS" ]; then
    warn "Entradas de error en hostd.log:"
    echo "$HOSTD_ERRS" | while read l; do echo "     $l"; done
else
    ok "hostd.log sin errores criticos recientes"
fi

# =============================================================================
header "FIN DEL DIAGNOSTICO — $(date '+%H:%M:%S')"
# =============================================================================
echo ""
