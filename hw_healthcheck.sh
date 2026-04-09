#!/bin/bash
# =============================================================================
# hw_healthcheck.sh — Hardware Health Check via IPMI
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

# =============================================================================
header "HW HEALTH CHECK — $(hostname) — $(date '+%Y-%m-%d %H:%M:%S')"
# =============================================================================

if ! command -v ipmitool &>/dev/null; then
    crit "ipmitool no disponible — instalar con: yum install ipmitool"
    exit 1
fi

# -----------------------------------------------------------------------------
section "CHASSIS"
# -----------------------------------------------------------------------------
CHASSIS=$(ipmitool chassis status 2>/dev/null)
echo "$CHASSIS" | grep -E "System Power|Power Overload|Main Power Fault|Cooling|Drive Fault" | \
    while read line; do
        KEY=$(echo "$line" | cut -d: -f1 | tr -d ' ')
        VAL=$(echo "$line" | cut -d: -f2 | tr -d ' ')
        case "$KEY" in
            SystemPower)        echo -e "  Sistema encendido:    ${BOLD}${VAL}${NC}" ;;
            PowerOverload)      [ "$VAL" = "false" ] && ok "Power Overload: false" || crit "Power Overload: $VAL" ;;
            MainPowerFault)     [ "$VAL" = "false" ] && ok "Main Power Fault: false" || crit "Main Power Fault: $VAL" ;;
            Cooling/FanFault)   [ "$VAL" = "false" ] && ok "Cooling/Fan Fault: false" || crit "Cooling/Fan Fault: $VAL" ;;
            DriveFault)         [ "$VAL" = "false" ] && ok "Drive Fault: false" || crit "Drive Fault: $VAL" ;;
        esac
    done

PWR=$(ipmitool sdr 2>/dev/null | grep -i "Pwr Consumption" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
[ -n "$PWR" ] && echo -e "\n  Consumo actual: ${BOLD}${PWR}${NC}"

# -----------------------------------------------------------------------------
section "TEMPERATURAS"
# -----------------------------------------------------------------------------
printf "  ${BOLD}%-25s %-12s %s${NC}\n" "SENSOR" "TEMP" "ESTADO"
printf "  %0.s─" {1..55}; echo ""

ipmitool sdr type Temperature 2>/dev/null | grep -v "ns\|Disabled\|not readable" | \
while IFS='|' read NAME ID STATUS ADDR VALUE; do
    NAME=$(echo "$NAME" | tr -d ' ')
    VALUE=$(echo "$VALUE" | tr -d ' ')
    STATUS=$(echo "$STATUS" | tr -d ' ')
    TEMP_NUM=$(echo "$VALUE" | grep -oE '[0-9]+' | head -1)

    [ -z "$TEMP_NUM" ] && continue

    if [ "$TEMP_NUM" -gt 80 ] 2>/dev/null; then
        ICON="${RED}✘${NC}"
        ALERT="🔴 CRITICO"
    elif [ "$TEMP_NUM" -gt 70 ] 2>/dev/null; then
        ICON="${YELLOW}⚠${NC}"
        ALERT="⚠ ELEVADA"
    else
        ICON="${GREEN}✔${NC}"
        ALERT=""
    fi

    printf "  ${ICON}  %-23s %-12s %s\n" "$NAME" "$VALUE" "$ALERT"
done

# -----------------------------------------------------------------------------
section "VENTILADORES"
# -----------------------------------------------------------------------------
# FIX: verificar redundancia correctamente — buscar "Fully" en el valor
FAN_REDUND=$(ipmitool sdr type Fan 2>/dev/null | grep -i "Redundancy" | awk -F'|' '{print $NF}' | tr -d ' ')
FAN_FAIL=$(ipmitool sdr type Fan 2>/dev/null | grep -iv "ok\|redundancy\|^$" | grep -i "fail\|critical\|nc\|nr")

printf "  ${BOLD}%-12s %-15s %s${NC}\n" "FAN" "RPM" "ESTADO"
printf "  %0.s─" {1..40}; echo ""

ipmitool sdr type Fan 2>/dev/null | grep -iv "redundancy" | grep -v "^$" | \
while IFS='|' read NAME ID STATUS ADDR VALUE; do
    NAME=$(echo "$NAME" | tr -d ' ')
    VALUE=$(echo "$VALUE" | tr -d ' ')
    STATUS=$(echo "$STATUS" | tr -d ' ')
    [ -z "$NAME" ] && continue
    if [ "$STATUS" = "ok" ]; then
        printf "  ${GREEN}✔${NC}  %-12s %s\n" "$NAME" "$VALUE"
    else
        printf "  ${RED}✘${NC}  %-12s %-15s %s\n" "$NAME" "$VALUE" "⚠ $STATUS"
    fi
done

echo ""
# FIX: comparar el valor real de redundancia
if echo "$FAN_REDUND" | grep -qi "Full"; then
    ok "Fan Redundancy: Fully Redundant"
elif [ -z "$FAN_REDUND" ]; then
    warn "Fan Redundancy: no disponible"
else
    crit "Fan Redundancy: $FAN_REDUND"
fi

[ -n "$FAN_FAIL" ] && crit "Fans con problemas:" && \
    echo "$FAN_FAIL" | while read l; do echo "     $l"; done

# -----------------------------------------------------------------------------
section "FUENTES DE ALIMENTACION (PSU)"
# -----------------------------------------------------------------------------
PSU_OUTPUT=$(ipmitool sdr type "Power Supply" 2>/dev/null)

# FIX: extraer el valor de redundancia correctamente
PSU_REDUND=$(echo "$PSU_OUTPUT" | grep -i "Redundancy" | awk -F'|' '{print $NF}' | tr -d ' ')

printf "  ${BOLD}%-25s %s${NC}\n" "COMPONENTE" "ESTADO"
printf "  %0.s─" {1..40}; echo ""

echo "$PSU_OUTPUT" | grep -v "^$" | \
while IFS='|' read NAME ID STATUS ADDR VALUE; do
    NAME=$(echo "$NAME" | tr -d ' ')
    STATUS=$(echo "$STATUS" | tr -d ' ')
    VALUE=$(echo "$VALUE" | tr -d ' ')
    [ -z "$NAME" ] && continue
    DISPLAY="$VALUE"
    [ -z "$DISPLAY" ] && DISPLAY="$STATUS"
    if [ "$STATUS" = "ok" ]; then
        printf "  ${GREEN}✔${NC}  %-25s %s\n" "$NAME" "$DISPLAY"
    else
        printf "  ${RED}✘${NC}  %-25s %s\n" "$NAME" "$DISPLAY"
    fi
done

echo ""
# FIX: verificar si contiene "Full" para determinar redundancia
if echo "$PSU_REDUND" | grep -qi "Full"; then
    ok "PSU Redundancy: Fully Redundant"
elif [ -z "$PSU_REDUND" ]; then
    warn "PSU Redundancy: no disponible"
else
    crit "PSU Redundancy: $PSU_REDUND — verificar fuentes"
fi

# -----------------------------------------------------------------------------
section "VOLTAJES"
# -----------------------------------------------------------------------------
printf "  ${BOLD}%-20s %s${NC}\n" "LINEA" "VOLTAJE"
printf "  %0.s─" {1..35}; echo ""

# Solo mostrar voltajes de línea principales (no los PG internos)
ipmitool sdr type Voltage 2>/dev/null | grep -iE "^Voltage [0-9]" | \
while IFS='|' read NAME ID STATUS ADDR VALUE; do
    NAME=$(echo "$NAME" | tr -d ' ')
    VALUE=$(echo "$VALUE" | tr -d ' ')
    STATUS=$(echo "$STATUS" | tr -d ' ')
    if [ "$STATUS" = "ok" ]; then
        printf "  ${GREEN}✔${NC}  %-20s %s\n" "$NAME" "$VALUE"
    else
        printf "  ${RED}✘${NC}  %-20s %-15s %s\n" "$NAME" "$VALUE" "⚠ $STATUS"
    fi
done

# Verificar Power Good signals — si alguno no está deasserted es problema
VOLT_ASSERT=$(ipmitool sdr type Voltage 2>/dev/null | \
    grep -i "Asserted" | grep -iv "Deasserted")
[ -n "$VOLT_ASSERT" ] && crit "Señal de voltaje en fallo: $VOLT_ASSERT" || \
    ok "Todos los Power Good signals en estado normal"

# -----------------------------------------------------------------------------
section "EVENTOS DE HARDWARE (SEL)"
# -----------------------------------------------------------------------------
SEL_ALL=$(ipmitool sel elist 2>/dev/null)
TOTAL_EVENTS=$(echo "$SEL_ALL" | grep -c "." 2>/dev/null || echo 0)
echo -e "  Total eventos en SEL: ${BOLD}${TOTAL_EVENTS}${NC}"
echo ""

# FIX: detectar desconexiones de disco separando Deasserted de Asserted
DRIVE_DEASSERT=$(echo "$SEL_ALL" | grep -i "Drive.*Deasserted\|Drive Slot.*Deasserted")
DRIVE_ASSERT=$(echo "$SEL_ALL"   | grep -i "Drive.*Asserted" | grep -iv "Deasserted")

if [ -n "$DRIVE_DEASSERT" ]; then
    crit "Desconexiones de disco detectadas en el SEL:"
    echo "$DRIVE_DEASSERT" | while read l; do
        echo "     $l"
        # Buscar si hay reconexión correspondiente
        SLOT=$(echo "$l" | grep -oE "#0x[0-9a-f]+")
        RECONECT=$(echo "$DRIVE_ASSERT" | grep "$SLOT" | head -1)
        [ -n "$RECONECT" ] && echo "     ${GREEN}↳ Reconectado:${NC} $RECONECT"
    done
else
    ok "Sin desconexiones de disco en el SEL"
fi

echo ""

# Otros eventos críticos (excluyendo los de disco ya mostrados)
OTHER_CRIT=$(echo "$SEL_ALL" | \
    grep -iE "critical|power.*fail|fan.*fail|temp.*assert" | \
    grep -iv "Drive Slot\|OS Boot\|Log area\|Deasserted\|Asserted" | tail -5)

if [ -n "$OTHER_CRIT" ]; then
    warn "Otros eventos críticos en SEL:"
    echo "$OTHER_CRIT" | while read l; do echo "     $l"; done
else
    ok "Sin otros eventos críticos en SEL"
fi

echo ""
echo -e "  ${BOLD}Últimos 5 eventos:${NC}"
echo "$SEL_ALL" | tail -5 | while read l; do echo "     $l"; done

# =============================================================================
header "FIN DEL DIAGNÓSTICO — $(date '+%H:%M:%S')"
# =============================================================================
echo ""
