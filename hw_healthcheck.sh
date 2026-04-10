#!/bin/bash
# =============================================================================
# hw_healthcheck.sh — Hardware Full Health Check
# Uso: curl -s https://raw.githubusercontent.com/felipeafl/rhvh/main/hw_healthcheck.sh | bash
# =============================================================================

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
section() { echo -e "\n${BOLD}── $1 ${SEP:${#1}+4}${NC}"; }
ok()      { echo -e "  ${GREEN}✔${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; }
crit()    { echo -e "  ${RED}✘${NC}  $1"; }
info()    { echo -e "  ${CYAN}ℹ${NC}  $1"; }

HAVE_IPMI=false
command -v ipmitool &>/dev/null && HAVE_IPMI=true

# =============================================================================
header "HW HEALTH CHECK — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
# =============================================================================

# -----------------------------------------------------------------------------
section "CPU"
# -----------------------------------------------------------------------------
SOCKETS=$(lscpu | awk '/^Socket\(s\)/{print $2}')
CORES=$(lscpu | awk '/^Core\(s\) per socket/{print $4}')
THREADS=$(lscpu | awk '/^Thread\(s\) per core/{print $4}')
TOTAL_CORES=$(lscpu | awk '/^CPU\(s\)/{print $2}' | head -1)
MODEL=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2}')
ARCH=$(lscpu | awk '/^Architecture/{print $2}')
MHZ=$(lscpu | awk '/^CPU MHz/{printf "%.0f", $3}')
MAX_MHZ=$(lscpu | awk '/^CPU max MHz/{printf "%.0f", $4}')
NUMA=$(lscpu | awk '/^NUMA node\(s\)/{print $3}')
VIRT=$(lscpu | awk '/^Virtualization/{print $2}')

printf "  ${BOLD}%-25s %s${NC}\n" "Modelo:" "$MODEL"
printf "  %-25s %s\n" "Arquitectura:" "$ARCH"
printf "  %-25s %s\n" "Sockets:" "$SOCKETS"
printf "  %-25s %s\n" "Núcleos por socket:" "$CORES"
printf "  %-25s %s\n" "Threads por núcleo:" "$THREADS"
printf "  %-25s %s\n" "CPUs lógicas totales:" "$TOTAL_CORES"
printf "  %-25s %s\n" "NUMA nodes:" "$NUMA"
printf "  %-25s %s MHz" "Frecuencia actual:" "$MHZ"
[ -n "$MAX_MHZ" ] && printf " / max: %s MHz" "$MAX_MHZ"
echo ""
[ -n "$VIRT" ] && printf "  %-25s %s\n" "Virtualización:" "$VIRT"

# Estado de los cores
OFFLINE_CPUS=$(cat /sys/devices/system/cpu/offline 2>/dev/null)
if [ -n "$OFFLINE_CPUS" ] && [ "$OFFLINE_CPUS" != "" ]; then
    warn "CPUs offline detectadas: $OFFLINE_CPUS"
else
    ok "Todos los CPUs online"
fi

# Temperatura CPU via IPMI
if $HAVE_IPMI; then
    CPU_TEMPS=$(ipmitool sdr type Temperature 2>/dev/null | grep -iE "^Temp " | grep -v "Disabled\|ns")
    if [ -n "$CPU_TEMPS" ]; then
        echo ""
        echo -e "  ${BOLD}Temperaturas CPU:${NC}"
        echo "$CPU_TEMPS" | while IFS='|' read NAME ID STATUS ADDR VALUE; do
            NAME=$(echo "$NAME" | tr -d ' ')
            VALUE=$(echo "$VALUE" | tr -d ' ')
            TEMP_NUM=$(echo "$VALUE" | grep -oE '[0-9]+' | head -1)
            [ -z "$TEMP_NUM" ] && continue
            if   [ "$TEMP_NUM" -gt 80 ] 2>/dev/null; then crit "$NAME: $VALUE 🔴 CRITICO"
            elif [ "$TEMP_NUM" -gt 70 ] 2>/dev/null; then warn "$NAME: $VALUE ⚠ ELEVADA"
            else ok "$NAME: $VALUE"
            fi
        done
    fi
fi

# -----------------------------------------------------------------------------
section "MEMORIA RAM"
# -----------------------------------------------------------------------------
MEM_TOTAL=$(free -h | awk '/^Mem:/{print $2}')
MEM_USED=$(free -h  | awk '/^Mem:/{print $3}')
MEM_FREE=$(free -h  | awk '/^Mem:/{print $7}')
MEM_PCT=$(free -m   | awk '/^Mem:/{printf "%.0f", $3*100/$2}')

printf "  ${BOLD}%-25s %s${NC}\n" "Capacidad total:" "$MEM_TOTAL"
printf "  %-25s %s\n" "En uso:" "$MEM_USED"
printf "  %-25s %s\n" "Disponible:" "$MEM_FREE"
printf "  %-25s %s%%\n" "Porcentaje de uso:" "$MEM_PCT"

if   [ "$MEM_PCT" -gt 95 ] 2>/dev/null; then crit  "Memoria al ${MEM_PCT}% — crítico"
elif [ "$MEM_PCT" -gt 85 ] 2>/dev/null; then warn  "Memoria al ${MEM_PCT}% — monitorear"
else ok "Memoria OK (${MEM_PCT}% en uso)"
fi

# DIMMs via dmidecode
if command -v dmidecode &>/dev/null; then
    echo ""
    echo -e "  ${BOLD}Módulos DIMM instalados:${NC}"
    printf "  ${BOLD}%-8s %-30s %-12s %-10s %-10s %s${NC}\n" \
        "SLOT" "FABRICANTE/PART" "CAPACIDAD" "VELOCIDAD" "TIPO" "ESTADO"
    printf "  %0.s─" {1..85}; echo ""

    dmidecode -t memory 2>/dev/null | awk '
    /Memory Device$/ { slot=""; mfr=""; part=""; size=""; speed=""; mtype=""; form="" }
    /Locator:/ && !/Bank/ { slot=$2" "$3 }
    /Manufacturer:/ { mfr=$2 }
    /Part Number:/ { part=$3 }
    /Size:/ && /MB|GB/ { size=$2" "$3 }
    /Speed:/ && /MT/ { speed=$2" "$3 }
    /Type:/ && !/Form|Error|Set|Detail/ { mtype=$2 }
    /Form Factor:/ { form=$3 }
    /Size:.*No Module/ { size="Empty" }
    /^$/ {
        if (slot != "" && size != "" && size != "Empty") {
            label=mfr" "part
            printf "  \033[0;32m✔\033[0m  %-8s %-30s %-12s %-10s %-10s %s\n",
                slot, substr(label,1,28), size, speed, mtype, form
        } else if (slot != "" && size == "Empty") {
            printf "  %-3s %-8s %s\n", "   ", slot, "— vacío"
        }
    }' | head -40

    DIMM_COUNT=$(dmidecode -t memory 2>/dev/null | grep -c "Size:.*[0-9]")
    DIMM_EMPTY=$(dmidecode -t memory 2>/dev/null | grep -c "No Module Installed")
    echo ""
    info "DIMMs instalados: $DIMM_COUNT | Slots vacíos: $DIMM_EMPTY"
fi

# Temperatura memoria via IPMI
if $HAVE_IPMI; then
    MEM_TEMPS=$(ipmitool sdr type Temperature 2>/dev/null | grep -iE "mem|dimm" | grep -v "Disabled\|ns")
    if [ -n "$MEM_TEMPS" ]; then
        echo ""
        echo -e "  ${BOLD}Temperatura memoria:${NC}"
        echo "$MEM_TEMPS" | while IFS='|' read NAME ID STATUS ADDR VALUE; do
            NAME=$(echo "$NAME" | tr -d ' ')
            VALUE=$(echo "$VALUE" | tr -d ' ')
            ok "$NAME: $VALUE"
        done
    fi
fi

# -----------------------------------------------------------------------------
section "ALMACENAMIENTO"
# -----------------------------------------------------------------------------
STORCLI="/opt/MegaRAID/storcli/storcli64"

# Detectar dispositivos de bloque
echo -e "  ${BOLD}Dispositivos detectados:${NC}"
printf "  ${BOLD}%-12s %-10s %-8s %-8s %-6s %s${NC}\n" \
    "DISPOSITIVO" "TAMAÑO" "TIPO" "ROTACIONAL" "MODELO" ""
printf "  %0.s─" {1..65}; echo ""

lsblk -d -o NAME,SIZE,TYPE,ROTA,MODEL 2>/dev/null | grep -v "^NAME\|loop\|sr" | \
while read NAME SIZE TYPE ROTA MODEL; do
    if [ "$ROTA" = "0" ]; then
        DISK_TYPE="SSD"
        ICON="${GREEN}✔${NC}"
    else
        DISK_TYPE="HDD"
        ICON="${YELLOW}⚠${NC}"
    fi
    # Detectar NVMe
    echo "$NAME" | grep -q "nvme" && DISK_TYPE="NVMe"
    printf "  ${ICON}  %-12s %-10s %-8s %-8s %s\n" \
        "/dev/$NAME" "$SIZE" "$DISK_TYPE" "$([ $ROTA -eq 0 ] && echo No || echo Si)" "$MODEL"
done

# MegaRAID si disponible
if [ -f "$STORCLI" ]; then
    echo ""
    echo -e "  ${BOLD}RAID — Virtual Drives:${NC}"
    $STORCLI /c0 /vall show 2>/dev/null | awk '/^[0-9]/{
        state=$3
        if (state=="Optl") icon="\033[0;32m✔\033[0m"
        else if (state~/Pdgd|Dgrd/) icon="\033[0;31m✘\033[0m"
        else icon="\033[1;33m⚠\033[0m"
        printf "  %s  %s\n", icon, $0
    }'

    echo ""
    echo -e "  ${BOLD}RAID — Discos físicos:${NC}"
    printf "  ${BOLD}%-10s %-10s %-8s %-8s %-30s %s${NC}\n" \
        "SLOT" "ESTADO" "TAMAÑO" "MEDIO" "MODELO" "ERRORES"
    printf "  %0.s─" {1..80}; echo ""

    $STORCLI /c0 /eall /sall show 2>/dev/null | awk '/^[0-9]/{
        slot=$1; did=$2; state=$3; dg=$4; size=$5" "$6
        intf=$7; med=$8; model=$NF
        if (state=="Onln") icon="\033[0;32m✔\033[0m"
        else if (state=="Rbld") icon="\033[1;33m⚠\033[0m"
        else icon="\033[0;31m✘\033[0m"
        printf "  %s  %-10s %-10s %-8s %-8s %s\n", icon, slot, state, size, med, model
    }'

    # SMART de cada disco via storcli
    echo ""
    echo -e "  ${BOLD}SMART — Estado por disco:${NC}"
    printf "  ${BOLD}%-10s %-8s %-8s %-8s %-8s %-8s %s${NC}\n" \
        "SLOT" "TIMEOUT" "REALLOC" "PENDING" "RAIN" "WEAROUT" "ESTADO"
    printf "  %0.s─" {1..70}; echo ""

    PYFILE=$(mktemp /tmp/smart_hw_XXXXXX.py)
    cat > "$PYFILE" << 'PYEOF'
import sys
attrs = {0x09:"hours",0xBC:"timeout",0x05:"realloc",0xC4:"realloc_ev",
         0xC5:"pending",0xD3:"rain_fail",0xAD:"wear",0xCA:"lifetime",
         0xBB:"uncorr",0xAE:"powerloss"}
result = {v:0 for v in attrs.values()}
result["val_wear"]=100; result["val_lifetime"]=0
try:
    with open(sys.argv[1]) as f: raw=f.read()
    data=bytes(int(x,16) for x in raw.split())
    i=0
    while i<len(data)-11:
        aid=data[i]
        if aid in attrs:
            val=data[i+3]; raw6=data[i+5:i+11]; rv=int.from_bytes(raw6,'little')
            name=attrs[aid]
            if aid==0x09: result[name]=rv&0xFFFFFF
            elif aid==0xAD: result[name]=rv; result["val_wear"]=val
            elif aid==0xCA: result[name]=rv; result["val_lifetime"]=100-val
            else: result[name]=rv
        i+=12
except: pass
print("{timeout}|{realloc}|{pending}|{rain_fail}|{val_wear}|{val_lifetime}|{uncorr}".format(**result))
PYEOF
    HEXFILE=$(mktemp /tmp/smart_hex_XXXXXX.txt)

    $STORCLI /c0 /eall /sall show 2>/dev/null | awk '/^[0-9]/{print $1}' | \
    while read DISK; do
        EID=$(echo "$DISK" | cut -d: -f1)
        SLT=$(echo "$DISK" | cut -d: -f2)
        $STORCLI /c0/e${EID}/s${SLT} show smart 2>/dev/null | \
            awk '/^[0-9a-f][0-9a-f] [0-9a-f][0-9a-f]/{print}' > "$HEXFILE"
        VALS=$(python3 "$PYFILE" "$HEXFILE" 2>/dev/null)
        [ -z "$VALS" ] && continue

        TO=$(echo "$VALS"  | cut -d'|' -f1)
        RL=$(echo "$VALS"  | cut -d'|' -f2)
        PD=$(echo "$VALS"  | cut -d'|' -f3)
        RF=$(echo "$VALS"  | cut -d'|' -f4)
        WR=$(echo "$VALS"  | cut -d'|' -f5)
        LT=$(echo "$VALS"  | cut -d'|' -f6)
        UC=$(echo "$VALS"  | cut -d'|' -f7)

        ISSUE=0
        [ "${UC:-0}" -gt 0  ] 2>/dev/null && ISSUE=2
        [ "${RL:-0}" -gt 0  ] 2>/dev/null && ISSUE=2
        [ "${PD:-0}" -gt 0  ] 2>/dev/null && ISSUE=2
        [ "${RF:-0}" -gt 5  ] 2>/dev/null && ISSUE=2
        [ "${TO:-0}" -gt 50 ] 2>/dev/null && [ "$ISSUE" -lt 1 ] && ISSUE=1
        [ "${LT:-0}" -gt 80 ] 2>/dev/null && [ "$ISSUE" -lt 1 ] && ISSUE=1

        case $ISSUE in
            2) ESTADO="${RED}CRITICO${NC}" ;;
            1) ESTADO="${YELLOW}WARN${NC}" ;;
            *) ESTADO="${GREEN}OK${NC}" ;;
        esac

        printf "  %-10s %-8s %-8s %-8s %-8s %-8s " \
            "$DISK" "${TO}" "${RL}" "${PD}" "${RF}" "${WR}%"
        echo -e "${ESTADO}"
    done

    rm -f "$PYFILE" "$HEXFILE"
fi

# -----------------------------------------------------------------------------
section "INTERFACES DE RED"
# -----------------------------------------------------------------------------
printf "  ${BOLD}%-12s %-20s %-12s %-10s %-8s %s${NC}\n" \
    "INTERFAZ" "MAC" "VELOCIDAD" "DUPLEX" "ESTADO" "IP"
printf "  %0.s─" {1..80}; echo ""

for NIC in $(ls /sys/class/net/ 2>/dev/null | grep -vE "^lo$|^virbr|^vnet|^bond|^ovs|^docker|^br-"); do
    MAC=$(cat /sys/class/net/$NIC/address 2>/dev/null)
    OPERSTATE=$(cat /sys/class/net/$NIC/operstate 2>/dev/null)
    SPEED=$(cat /sys/class/net/$NIC/speed 2>/dev/null 2>&1)
    DUPLEX=$(cat /sys/class/net/$NIC/duplex 2>/dev/null)
    IP=$(ip -4 addr show $NIC 2>/dev/null | awk '/inet /{print $2}' | head -1)
    [ -z "$IP" ] && IP="—"
    [ -z "$SPEED" ] || [ "$SPEED" = "-1" ] 2>/dev/null && SPEED="—"
    [ -n "$SPEED" ] && [ "$SPEED" != "—" ] 2>/dev/null && SPEED="${SPEED}Mb/s"

    if [ "$OPERSTATE" = "up" ]; then
        ICON="${GREEN}✔${NC}"
    elif [ "$OPERSTATE" = "down" ]; then
        ICON="${RED}✘${NC}"
    else
        ICON="${YELLOW}⚠${NC}"
    fi

    printf "  ${ICON}  %-12s %-20s %-12s %-10s %-8s %s\n" \
        "$NIC" "${MAC:-—}" "${SPEED}" "${DUPLEX:-—}" "$OPERSTATE" "$IP"
done

# Bonding / teaming
BONDS=$(ls /sys/class/net/bond* 2>/dev/null | head -5)
[ -n "$BONDS" ] && echo "" && echo -e "  ${BOLD}Bonding interfaces:${NC}" && \
    for B in $BONDS; do
        BNAME=$(basename $B)
        MODE=$(cat /sys/class/net/$BNAME/bonding/mode 2>/dev/null | awk '{print $1}')
        SLAVES=$(cat /sys/class/net/$BNAME/bonding/slaves 2>/dev/null)
        info "$BNAME — modo: $MODE — slaves: $SLAVES"
    done

# -----------------------------------------------------------------------------
section "FUENTES DE ALIMENTACION (PSU)"
# -----------------------------------------------------------------------------
if ! $HAVE_IPMI; then
    warn "ipmitool no disponible — no se puede verificar PSUs"
else
    PSU_OUTPUT=$(ipmitool sdr type "Power Supply" 2>/dev/null)
    PSU_REDUND=$(echo "$PSU_OUTPUT" | grep -i "Redundancy" | awk -F'|' '{print $NF}' | tr -d ' ')
    PWR=$(ipmitool sdr 2>/dev/null | grep -i "Pwr Consumption" | awk -F'|' '{gsub(/ /,"",$2); print $2}')

    printf "  ${BOLD}%-30s %s${NC}\n" "COMPONENTE" "ESTADO"
    printf "  %0.s─" {1..45}; echo ""

    echo "$PSU_OUTPUT" | grep -v "^$" | \
    while IFS='|' read NAME ID STATUS ADDR VALUE; do
        NAME=$(echo "$NAME"   | tr -d ' ')
        STATUS=$(echo "$STATUS" | tr -d ' ')
        VALUE=$(echo "$VALUE"  | tr -d ' ')
        [ -z "$NAME" ] && continue
        DISPLAY="${VALUE:-$STATUS}"
        [ "$STATUS" = "ok" ] && \
            printf "  ${GREEN}✔${NC}  %-30s %s\n" "$NAME" "$DISPLAY" || \
            printf "  ${RED}✘${NC}  %-30s %s\n"   "$NAME" "$DISPLAY"
    done

    echo ""
    if   echo "$PSU_REDUND" | grep -qi "Full"; then ok  "PSU Redundancy: Fully Redundant"
    elif [ -z "$PSU_REDUND" ];                  then warn "PSU Redundancy: no disponible"
    else                                              crit "PSU Redundancy: $PSU_REDUND"
    fi
    [ -n "$PWR" ] && info "Consumo actual del sistema: $PWR"
fi

# -----------------------------------------------------------------------------
section "TEMPERATURA"
# -----------------------------------------------------------------------------
if ! $HAVE_IPMI; then
    warn "ipmitool no disponible"
    # Fallback a lm-sensors
    if command -v sensors &>/dev/null; then
        sensors 2>/dev/null | grep -iE "core|temp|fan" | head -20
    fi
else
    printf "  ${BOLD}%-30s %-15s %s${NC}\n" "SENSOR" "VALOR" "ESTADO"
    printf "  %0.s─" {1..55}; echo ""

    ipmitool sdr type Temperature 2>/dev/null | grep -v "ns\|Disabled\|not readable" | \
    while IFS='|' read NAME ID STATUS ADDR VALUE; do
        NAME=$(echo "$NAME"   | tr -d ' ')
        VALUE=$(echo "$VALUE" | tr -d ' ')
        STATUS=$(echo "$STATUS" | tr -d ' ')
        TEMP_NUM=$(echo "$VALUE" | grep -oE '[0-9]+' | head -1)
        [ -z "$TEMP_NUM" ] && continue
        if   [ "$TEMP_NUM" -gt 80 ] 2>/dev/null; then
            printf "  ${RED}✘${NC}  %-30s %-15s %s\n" "$NAME" "$VALUE" "🔴 CRITICO (>80°C)"
        elif [ "$TEMP_NUM" -gt 70 ] 2>/dev/null; then
            printf "  ${YELLOW}⚠${NC}  %-30s %-15s %s\n" "$NAME" "$VALUE" "⚠ ELEVADA (>70°C)"
        else
            printf "  ${GREEN}✔${NC}  %-30s %s\n" "$NAME" "$VALUE"
        fi
    done

    # Inlet/Exhaust
    echo ""
    INLET=$(ipmitool sdr type Temperature 2>/dev/null | grep -i "Inlet" | \
        awk -F'|' '{print $NF}' | tr -d ' ')
    EXHAUST=$(ipmitool sdr type Temperature 2>/dev/null | grep -i "Exhaust" | \
        awk -F'|' '{print $NF}' | tr -d ' ')
    [ -n "$INLET"   ] && info "Temperatura entrada aire (Inlet):  $INLET"
    [ -n "$EXHAUST" ] && info "Temperatura salida aire (Exhaust): $EXHAUST"
fi

# -----------------------------------------------------------------------------
section "VENTILADORES"
# -----------------------------------------------------------------------------
if ! $HAVE_IPMI; then
    warn "ipmitool no disponible"
else
    FAN_REDUND=$(ipmitool sdr type Fan 2>/dev/null | grep -i "Redundancy" | \
        awk -F'|' '{print $NF}' | tr -d ' ')
    FAN_FAIL=$(ipmitool sdr type Fan 2>/dev/null | \
        grep -iv "ok\|redundancy\|^$" | grep -i "fail\|critical\|nc\|nr")

    printf "  ${BOLD}%-12s %-15s %s${NC}\n" "FAN" "VELOCIDAD" "ESTADO"
    printf "  %0.s─" {1..40}; echo ""

    ipmitool sdr type Fan 2>/dev/null | grep -iv "redundancy" | grep -v "^$" | \
    while IFS='|' read NAME ID STATUS ADDR VALUE; do
        NAME=$(echo "$NAME"   | tr -d ' ')
        VALUE=$(echo "$VALUE" | tr -d ' ')
        STATUS=$(echo "$STATUS" | tr -d ' ')
        [ -z "$NAME" ] && continue
        [ "$STATUS" = "ok" ] && \
            printf "  ${GREEN}✔${NC}  %-12s %s\n" "$NAME" "$VALUE" || \
            printf "  ${RED}✘${NC}  %-12s %-15s %s\n" "$NAME" "$VALUE" "⚠ $STATUS"
    done

    echo ""
    if   echo "$FAN_REDUND" | grep -qi "Full"; then ok   "Fan Redundancy: Fully Redundant"
    elif [ -z "$FAN_REDUND" ];                  then warn "Fan Redundancy: no disponible"
    else                                              crit "Fan Redundancy: $FAN_REDUND"
    fi
    [ -n "$FAN_FAIL" ] && crit "Fans con problemas detectados:" && \
        echo "$FAN_FAIL" | while read l; do echo "     $l"; done
fi

# -----------------------------------------------------------------------------
section "EVENTOS DE HARDWARE (SEL)"
# -----------------------------------------------------------------------------
if ! $HAVE_IPMI; then
    warn "ipmitool no disponible — no se puede consultar SEL"
else
    SEL_ALL=$(ipmitool sel elist 2>/dev/null)
    TOTAL=$(echo "$SEL_ALL" | grep -c "." 2>/dev/null || echo 0)
    info "Total eventos en SEL: $TOTAL"
    echo ""

    # Desconexiones de disco
    DRIVE_DEASSERT=$(echo "$SEL_ALL" | grep -i "Drive.*Deasserted\|Drive Slot.*Deasserted")
    if [ -n "$DRIVE_DEASSERT" ]; then
        crit "Desconexiones de disco detectadas:"
        DRIVE_ASSERT=$(echo "$SEL_ALL" | grep -i "Drive.*Asserted" | grep -iv "Deasserted")
        echo "$DRIVE_DEASSERT" | while read l; do
            echo "     $l"
            SLOT=$(echo "$l" | grep -oE "#0x[0-9a-f]+")
            RECONECT=$(echo "$DRIVE_ASSERT" | grep "$SLOT" | head -1)
            [ -n "$RECONECT" ] && echo -e "     ${GREEN}↳ Reconectado:${NC} $RECONECT"
        done
    else
        ok "Sin desconexiones de disco en el SEL"
    fi

    # Otros eventos críticos
    OTHER=$(echo "$SEL_ALL" | \
        grep -iE "critical|power.*fail|fan.*fail|temp.*assert" | \
        grep -iv "Drive Slot\|OS Boot\|Log area\|Deasserted\|Asserted" | tail -5)
    [ -n "$OTHER" ] && echo "" && warn "Otros eventos críticos:" && \
        echo "$OTHER" | while read l; do echo "     $l"; done

    echo ""
    echo -e "  ${BOLD}Últimos 5 eventos:${NC}"
    echo "$SEL_ALL" | tail -5 | while read l; do echo "     $l"; done
fi

# =============================================================================
header "FIN DEL DIAGNÓSTICO — $(date '+%H:%M:%S')"
# =============================================================================
echo ""
