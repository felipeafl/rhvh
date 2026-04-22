#!/usr/bin/env bash
# =============================================================================
#  DIAGNÓSTICO COMPLETO — ZABBIX PROXY
#  Versión: 2.0 | Autor: Infraestructura TI
#  Detecta causas de caídas, lentitud y mal funcionamiento del proxy Zabbix
# =============================================================================

# ── COLORES Y FORMATOS ────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
SEP="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── UMBRALES CONFIGURABLES ────────────────────────────────────────────────────
UMBRAL_CPU=80            # % CPU general
UMBRAL_MEM=85            # % Memoria usada
UMBRAL_SWAP_MB=100       # MB de swap en uso (cualquier uso es señal de problema)
UMBRAL_DISK=85           # % disco usado en partición de datos
UMBRAL_IOWAIT=10         # % iowait (indica cuello de botella en disco)
UMBRAL_LATENCIA_MS=200   # ms máximos al Zabbix Server
UMBRAL_LOAD_FACTOR=2     # load/CPUs — sobre este valor hay sobrecarga
UMBRAL_QUEUE=100         # items en queue del proxy (buffer problemático)
UMBRAL_CONN_ERR=10       # conexiones en estado ERROR/CLOSE_WAIT

# ── REPORTE ───────────────────────────────────────────────────────────────────
REPORTE="/tmp/zabbix_proxy_diag_$(date +%Y%m%d_%H%M%S).txt"
PROBLEMAS=()

ok()   { echo -e "  ${GREEN}[OK]${NC}    $1"; echo "  [OK]    $1" >> "$REPORTE"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $1"; echo "  [WARN]  $1" >> "$REPORTE"; PROBLEMAS+=("⚠ WARN: $1"); }
crit() { echo -e "  ${RED}[CRIT]${NC}  $1"; echo "  [CRIT]  $1" >> "$REPORTE"; PROBLEMAS+=("🔴 CRIT: $1"); }
info() { echo -e "  ${CYAN}[INFO]${NC}  $1"; echo "  [INFO]  $1" >> "$REPORTE"; }
section() {
    echo ""
    echo -e "${BOLD}${CYAN}▶ $1${NC}"
    echo ""
    echo "" >> "$REPORTE"
    echo "▶ $1" >> "$REPORTE"
    echo "" >> "$REPORTE"
}

# ── CABECERA ──────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
echo "  ╔══════════════════════════════════════════════════════════════════════╗"
echo "  ║        DIAGNÓSTICO COMPLETO — ZABBIX PROXY                         ║"
echo "  ║        $(date '+%Y-%m-%d %H:%M:%S')   Host: $(hostname)$(printf '%*s' $((30-${#HOSTNAME})) '')║"
echo "  ╚══════════════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

{
echo "============================================================"
echo "  DIAGNÓSTICO ZABBIX PROXY — $(date)"
echo "  Host: $(hostname)"
echo "============================================================"
} > "$REPORTE"

# ── 1. DETECTAR CONFIGURACIÓN DEL PROXY ──────────────────────────────────────
section "1. CONFIGURACIÓN DEL PROXY"

# Buscar binario y config
PROXY_BIN=$(which zabbix_proxy 2>/dev/null || find /usr/sbin /usr/local/sbin -name "zabbix_proxy" 2>/dev/null | head -1)
PROXY_CONF=$(find /etc/zabbix /usr/local/etc -name "zabbix_proxy.conf" 2>/dev/null | head -1)

if [ -z "$PROXY_BIN" ]; then
    crit "Binario zabbix_proxy NO encontrado en el sistema"
else
    info "Binario: $PROXY_BIN"
    PROXY_VER=$($PROXY_BIN --version 2>/dev/null | head -1)
    info "Versión: $PROXY_VER"
fi

if [ -z "$PROXY_CONF" ]; then
    crit "Archivo de configuración NO encontrado — rutas buscadas: /etc/zabbix, /usr/local/etc"
    PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"  # fallback
else
    info "Config: $PROXY_CONF"
fi

# Extraer parámetros clave de configuración
get_conf() {
    grep -i "^$1" "$PROXY_CONF" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d ' '
}

ZBX_SERVER=$(get_conf "Server")
ZBX_PORT=$(get_conf "ServerPort"); ZBX_PORT=${ZBX_PORT:-10051}
ZBX_HOSTNAME=$(get_conf "Hostname")
ZBX_DBNAME=$(get_conf "DBName")
ZBX_DBHOST=$(get_conf "DBHost"); ZBX_DBHOST=${ZBX_DBHOST:-localhost}
ZBX_DBPORT=$(get_conf "DBPort"); ZBX_DBPORT=${ZBX_DBPORT:-3306}
ZBX_POLLERS=$(get_conf "StartPollers"); ZBX_POLLERS=${ZBX_POLLERS:-5}
ZBX_TRAPPERS=$(get_conf "StartTrappers"); ZBX_TRAPPERS=${ZBX_TRAPPERS:-5}
ZBX_DISCOVERERS=$(get_conf "StartDiscoverers"); ZBX_DISCOVERERS=${ZBX_DISCOVERERS:-1}
ZBX_PINGERS=$(get_conf "StartPingers"); ZBX_PINGERS=${ZBX_PINGERS:-1}
ZBX_LOGFILE=$(get_conf "LogFile"); ZBX_LOGFILE=${ZBX_LOGFILE:-/var/log/zabbix/zabbix_proxy.log}
ZBX_LOGLEVEL=$(get_conf "DebugLevel"); ZBX_LOGLEVEL=${ZBX_LOGLEVEL:-3}
ZBX_TIMEOUT=$(get_conf "Timeout"); ZBX_TIMEOUT=${ZBX_TIMEOUT:-3}
ZBX_PROXYLOCALBUF=$(get_conf "ProxyLocalBuffer"); ZBX_PROXYLOCALBUF=${ZBX_PROXYLOCALBUF:-0}
ZBX_PROXYOFFLINEBUF=$(get_conf "ProxyOfflineBuffer"); ZBX_PROXYOFFLINEBUF=${ZBX_PROXYOFFLINEBUF:-1}
ZBX_HEARTBEAT=$(get_conf "HeartbeatFrequency"); ZBX_HEARTBEAT=${ZBX_HEARTBEAT:-60}
ZBX_DATAFREQ=$(get_conf "DataSenderFrequency"); ZBX_DATAFREQ=${ZBX_DATAFREQ:-1}

info "Zabbix Server destino : ${ZBX_SERVER:-NO DEFINIDO} : ${ZBX_PORT}"
info "Hostname del proxy    : ${ZBX_HOSTNAME:-NO DEFINIDO}"
info "Base de datos         : ${ZBX_DBHOST}:${ZBX_DBPORT} / ${ZBX_DBNAME}"
info "Pollers               : $ZBX_POLLERS | Trappers: $ZBX_TRAPPERS"
info "ProxyLocalBuffer      : ${ZBX_PROXYLOCALBUF}h | OfflineBuffer: ${ZBX_PROXYOFFLINEBUF}h"
info "HeartbeatFrequency    : ${ZBX_HEARTBEAT}s | DataSenderFreq: ${ZBX_DATAFREQ}s"
info "Log: $ZBX_LOGFILE (DebugLevel=$ZBX_LOGLEVEL)"

[ -z "$ZBX_SERVER" ] && crit "Server no configurado en $PROXY_CONF"
[ -z "$ZBX_HOSTNAME" ] && crit "Hostname no configurado en $PROXY_CONF"
[ -z "$ZBX_DBNAME" ] && warn "DBName no configurado — puede fallar la BD"

# ── 2. ESTADO DEL PROCESO Y SERVICIO ─────────────────────────────────────────
section "2. ESTADO DEL PROCESO ZABBIX PROXY"

# Verificar systemd
if systemctl is-active --quiet zabbix-proxy 2>/dev/null; then
    ok "Servicio zabbix-proxy ACTIVO (systemd)"
    ZBX_UPTIME=$(systemctl show zabbix-proxy --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
    info "Activo desde: $ZBX_UPTIME"
    ZBX_RESTARTS=$(systemctl show zabbix-proxy --property=NRestarts 2>/dev/null | cut -d= -f2)
    [ "$ZBX_RESTARTS" -gt 0 ] 2>/dev/null && warn "El servicio ha reiniciado ${ZBX_RESTARTS} veces desde el último boot"
    [ "$ZBX_RESTARTS" -gt 5 ] 2>/dev/null && crit "MUCHOS reinicios ($ZBX_RESTARTS) — proceso inestable, revisar logs"
else
    if systemctl list-units --type=service 2>/dev/null | grep -q zabbix; then
        crit "Servicio zabbix-proxy está INACTIVO (stopped/failed)"
        systemctl status zabbix-proxy 2>/dev/null | head -20
    else
        info "No se detectó servicio systemd — verificando proceso directo"
    fi
fi

# Verificar proceso
ZBX_PID=$(pgrep -f "zabbix_proxy" | head -1)
if [ -n "$ZBX_PID" ]; then
    ok "Proceso encontrado — PID principal: $ZBX_PID"
    ZBX_PROC_COUNT=$(pgrep -c -f "zabbix_proxy")
    info "Total procesos hijos: $ZBX_PROC_COUNT"
    # CPU y memoria del proceso principal
    ZBX_CPU=$(ps -p "$ZBX_PID" -o %cpu --no-headers 2>/dev/null | tr -d ' ')
    ZBX_MEM=$(ps -p "$ZBX_PID" -o %mem --no-headers 2>/dev/null | tr -d ' ')
    ZBX_RSS=$(ps -p "$ZBX_PID" -o rss --no-headers 2>/dev/null | tr -d ' ')
    ZBX_RSS_MB=$(( ${ZBX_RSS:-0} / 1024 ))
    info "CPU: ${ZBX_CPU}% | Memoria: ${ZBX_MEM}% (${ZBX_RSS_MB} MB RSS)"
    [ "${ZBX_CPU%.*}" -gt 50 ] 2>/dev/null && warn "El proceso zabbix_proxy consume ${ZBX_CPU}% CPU — revisar cantidad de pollers"
else
    crit "Proceso zabbix_proxy NO está corriendo"
fi

# Verificar cantidad de workers activos vs configurados
WORKERS_ESPERADOS=$(( ZBX_POLLERS + ZBX_TRAPPERS + ZBX_DISCOVERERS + ZBX_PINGERS + 10 ))
if [ "$ZBX_PROC_COUNT" -lt "$WORKERS_ESPERADOS" ] 2>/dev/null; then
    warn "Procesos activos ($ZBX_PROC_COUNT) menores a los esperados (~$WORKERS_ESPERADOS) — posible crash parcial"
fi

# ── 3. RECURSOS DEL SISTEMA ───────────────────────────────────────────────────
section "3. RECURSOS DEL SISTEMA"

CPUS=$(nproc)
LOAD=$(awk '{print $1}' /proc/loadavg)
LOAD_INT=$(echo "$LOAD" | cut -d. -f1)
LOAD_RATIO=$(awk "BEGIN {printf \"%.1f\", $LOAD / $CPUS}")

echo -e "  CPUs: ${BOLD}$CPUS${NC} | Load Average (1min): ${BOLD}$LOAD${NC} | Ratio load/CPUs: ${BOLD}$LOAD_RATIO${NC}"

if awk "BEGIN {exit !($LOAD > $CPUS * $UMBRAL_LOAD_FACTOR)}"; then
    crit "Sistema SOBRECARGADO — Load $LOAD supera ${CPUS}x${UMBRAL_LOAD_FACTOR} CPUs — el proxy acumula timeouts"
elif awk "BEGIN {exit !($LOAD > $CPUS)}"; then
    warn "Load supera el número de CPUs ($CPUS) — degradación de rendimiento"
else
    ok "Load dentro de rango normal (ratio $LOAD_RATIO)"
fi

# CPU iowait
IOWAIT=$(top -bn1 | grep "Cpu(s)" | awk '{for(i=1;i<=NF;i++) if($i~/wa,/) {gsub(",wa,","",$i); print $i}}' 2>/dev/null)
IOWAIT=${IOWAIT:-0}
IOWAIT_INT=$(echo "$IOWAIT" | cut -d. -f1)
info "CPU iowait: ${IOWAIT}%"
[ "$IOWAIT_INT" -gt "$UMBRAL_IOWAIT" ] 2>/dev/null && crit "iowait ALTO (${IOWAIT}%) — disco lento está causando que el proxy espere E/S, generando timeouts en checks" || ok "iowait OK (${IOWAIT}%)"

# Memoria
MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
MEM_AVAIL=$(free -m | awk '/^Mem:/ {print $7}')
MEM_USED=$(( MEM_TOTAL - MEM_AVAIL ))
MEM_PCT=$(( MEM_USED * 100 / MEM_TOTAL ))
SWAP_USED=$(free -m | awk '/^Swap:/ {print $3}')

echo ""
free -h
echo ""
info "Uso de memoria: ${MEM_PCT}% (${MEM_USED}/${MEM_TOTAL} MB)"

if [ "$MEM_PCT" -gt "$UMBRAL_MEM" ]; then
    crit "Memoria al ${MEM_PCT}% — el proxy puede ser terminado por OOM killer"
elif [ "$MEM_PCT" -gt 75 ]; then
    warn "Memoria elevada (${MEM_PCT}%) — monitorear"
else
    ok "Memoria OK (${MEM_PCT}%)"
fi

if [ "${SWAP_USED:-0}" -gt "$UMBRAL_SWAP_MB" ]; then
    crit "Swap en uso: ${SWAP_USED}MB — el sistema está usando disco como RAM, degradación severa de rendimiento del proxy"
else
    ok "Sin uso de swap"
fi

# Disco
section "3.1 ESPACIO EN DISCO"
df -h | grep -v tmpfs | grep -v udev | grep -v loop

# Detectar partición donde vive la BD o logs de Zabbix
for PART in /var/lib/mysql /var/lib/postgresql /var/lib/zabbix /var/log/zabbix /tmp /; do
    if [ -d "$PART" ]; then
        DISK_PCT=$(df "$PART" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
        DISK_MOUNT=$(df "$PART" 2>/dev/null | tail -1 | awk '{print $6}')
        if [ "$DISK_PCT" -gt "$UMBRAL_DISK" ] 2>/dev/null; then
            crit "Disco al ${DISK_PCT}% en $DISK_MOUNT ($PART) — la BD del proxy puede fallar al crecer"
        elif [ "$DISK_PCT" -gt 70 ] 2>/dev/null; then
            warn "Disco al ${DISK_PCT}% en $DISK_MOUNT ($PART)"
        fi
    fi
done

# I/O del disco
section "3.2 RENDIMIENTO I/O (iostat)"
if command -v iostat &>/dev/null; then
    iostat -x 1 3 2>/dev/null | tail -20
    # Buscar latencia alta en cualquier disco
    iostat -x 1 1 2>/dev/null | awk 'NR>3 && /[a-z]/ {
        if ($10+0 > 50 || $11+0 > 50)
            print "  [CRIT]  Latencia alta en " $1 ": r_await=" $10 "ms w_await=" $11 "ms — disco lento afecta BD del proxy"
        else if ($10+0 > 10 || $11+0 > 10)
            print "  [WARN]  Latencia moderada en " $1 ": r_await=" $10 "ms w_await=" $11 "ms"
    }'
else
    warn "iostat no disponible — instalar: yum install sysstat / apt install sysstat"
fi

# ── 4. BASE DE DATOS DEL PROXY ────────────────────────────────────────────────
section "4. BASE DE DATOS DEL PROXY"

# Detectar tipo de BD
DB_TYPE="desconocido"
if command -v mysql &>/dev/null; then DB_TYPE="mysql"; fi
if command -v psql &>/dev/null; then DB_TYPE="postgresql"; fi
if [ -f /var/lib/zabbix/zabbix_proxy.db ] || find /var/lib/zabbix -name "*.db" &>/dev/null 2>&1; then DB_TYPE="sqlite"; fi

info "Tipo de BD detectado: $DB_TYPE"

case "$DB_TYPE" in
    mysql)
        info "Verificando MySQL/MariaDB..."
        if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
            ok "Servicio MySQL/MariaDB activo"
        else
            crit "Servicio MySQL/MariaDB INACTIVO — el proxy no puede escribir/leer datos"
        fi

        # Tamaño de la BD del proxy
        DB_SIZE=$(mysql -u"${ZBX_DBUSER:-zabbix}" -e "SELECT ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS 'Size_MB' FROM information_schema.tables WHERE table_schema='${ZBX_DBNAME:-zabbix_proxy}'" 2>/dev/null | tail -1)
        [ -n "$DB_SIZE" ] && info "Tamaño BD proxy: ${DB_SIZE} MB"

        # Tablas más grandes (historia acumulada)
        echo ""
        mysql -u"${ZBX_DBUSER:-zabbix}" -e "
            SELECT table_name, ROUND((data_length+index_length)/1024/1024,1) AS MB
            FROM information_schema.tables
            WHERE table_schema='${ZBX_DBNAME:-zabbix_proxy}'
            ORDER BY (data_length+index_length) DESC LIMIT 10;
        " 2>/dev/null && info "Las tablas más grandes arriba — 'history*' o 'proxy_history' muy grandes indica que el proxy no está enviando datos al servidor"

        # Conexiones activas
        CONN_ACTIVE=$(mysql -u"${ZBX_DBUSER:-zabbix}" -e "SHOW STATUS LIKE 'Threads_connected'" 2>/dev/null | tail -1 | awk '{print $2}')
        CONN_MAX=$(mysql -u"${ZBX_DBUSER:-zabbix}" -e "SHOW VARIABLES LIKE 'max_connections'" 2>/dev/null | tail -1 | awk '{print $2}')
        [ -n "$CONN_ACTIVE" ] && info "Conexiones DB: $CONN_ACTIVE / $CONN_MAX"
        [ "${CONN_ACTIVE:-0}" -gt $(( ${CONN_MAX:-150} * 80 / 100 )) ] 2>/dev/null && warn "Conexiones DB al ${CONN_ACTIVE}/${CONN_MAX} — riesgo de saturación"

        # Slow queries
        SLOW_Q=$(mysql -u"${ZBX_DBUSER:-zabbix}" -e "SHOW STATUS LIKE 'Slow_queries'" 2>/dev/null | tail -1 | awk '{print $2}')
        [ "${SLOW_Q:-0}" -gt 100 ] 2>/dev/null && warn "Hay ${SLOW_Q} slow queries acumuladas — la BD está respondiendo lento al proxy"
        ;;

    postgresql)
        if pg_isready -q 2>/dev/null; then
            ok "PostgreSQL disponible"
        else
            crit "PostgreSQL NO disponible — el proxy no puede acceder a la BD"
        fi
        ;;

    sqlite)
        SQLITE_FILE=$(find /var/lib/zabbix -name "*.db" 2>/dev/null | head -1)
        [ -n "$SQLITE_FILE" ] && info "SQLite: $SQLITE_FILE ($(du -sh "$SQLITE_FILE" 2>/dev/null | cut -f1))"
        SQLITE_MB=$(du -m "$SQLITE_FILE" 2>/dev/null | cut -f1)
        [ "${SQLITE_MB:-0}" -gt 1024 ] 2>/dev/null && warn "BD SQLite supera 1 GB — puede causar lentitud en el proxy"
        [ "${SQLITE_MB:-0}" -gt 5120 ] 2>/dev/null && crit "BD SQLite supera 5 GB — rendimiento muy degradado, considerar limpieza o cambiar a MySQL"
        ;;
esac

# ── 5. CONECTIVIDAD AL ZABBIX SERVER ─────────────────────────────────────────
section "5. CONECTIVIDAD AL ZABBIX SERVER"

if [ -z "$ZBX_SERVER" ]; then
    crit "No se puede verificar conectividad — Server no configurado"
else
    # Ping básico
    PING_MS=$(ping -c 4 -W 2 "$ZBX_SERVER" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    PING_LOSS=$(ping -c 4 -W 2 "$ZBX_SERVER" 2>/dev/null | grep -oP '\d+(?=% packet loss)')

    if [ -n "$PING_MS" ]; then
        PING_INT=$(echo "$PING_MS" | cut -d. -f1)
        info "Ping a $ZBX_SERVER: ${PING_MS}ms (pérdida: ${PING_LOSS:-0}%)"
        if [ "$PING_INT" -gt "$UMBRAL_LATENCIA_MS" ] 2>/dev/null; then
            crit "Latencia ALTA al Zabbix Server (${PING_MS}ms > ${UMBRAL_LATENCIA_MS}ms) — datos llegarán tarde o se perderán"
        elif [ "$PING_INT" -gt 50 ] 2>/dev/null; then
            warn "Latencia elevada al Zabbix Server (${PING_MS}ms)"
        else
            ok "Latencia OK al Zabbix Server (${PING_MS}ms)"
        fi
        [ "${PING_LOSS:-0}" -gt 0 ] && warn "Pérdida de paquetes al Zabbix Server: ${PING_LOSS}% — conexión inestable"
        [ "${PING_LOSS:-0}" -gt 5 ] && crit "Pérdida de paquetes crítica: ${PING_LOSS}% — el proxy pierde comunicación con el server"
    else
        warn "No se puede hacer ping a $ZBX_SERVER (firewall ICMP?) — verificando TCP..."
    fi

    # Verificar TCP al puerto Zabbix
    if command -v nc &>/dev/null; then
        NC_START=$(date +%s%3N)
        if nc -z -w 5 "$ZBX_SERVER" "$ZBX_PORT" 2>/dev/null; then
            NC_END=$(date +%s%3N)
            NC_MS=$(( NC_END - NC_START ))
            ok "Puerto TCP $ZBX_PORT alcanzable en ${NC_MS}ms"
            [ "$NC_MS" -gt 500 ] && warn "Conexión TCP lenta al Server (${NC_MS}ms)"
        else
            crit "Puerto TCP $ZBX_PORT NO accesible en $ZBX_SERVER — el proxy no puede enviar datos"
        fi
    elif command -v timeout &>/dev/null; then
        if timeout 5 bash -c "echo > /dev/tcp/$ZBX_SERVER/$ZBX_PORT" 2>/dev/null; then
            ok "Puerto TCP $ZBX_PORT accesible"
        else
            crit "Puerto TCP $ZBX_PORT NO accesible — proxy sin comunicación con el server"
        fi
    fi

    # Traceroute para detectar rutas problemáticas
    if command -v traceroute &>/dev/null; then
        info "Trazando ruta a $ZBX_SERVER (primeros 10 saltos)..."
        traceroute -m 10 -w 2 "$ZBX_SERVER" 2>/dev/null | while read -r line; do
            echo "    $line"
            echo "    $line" >> "$REPORTE"
            # Detectar saltos con alta latencia
            HOP_MS=$(echo "$line" | grep -oP '\d+\.\d+ ms' | head -1 | awk '{print $1}' | cut -d. -f1)
            [ "${HOP_MS:-0}" -gt 200 ] 2>/dev/null && echo -e "    ${YELLOW}^ Salto con alta latencia${NC}"
        done
    fi
fi

# ── 6. ESTADO DE CONEXIONES DE RED ───────────────────────────────────────────
section "6. ESTADO DE CONEXIONES DE RED"

if command -v ss &>/dev/null; then
    echo -e "  ${BOLD}Conexiones al Zabbix Server ($ZBX_SERVER):${NC}"
    ss -tn dst "$ZBX_SERVER" 2>/dev/null | head -20

    # Conexiones en estado problemático
    CLOSE_WAIT=$(ss -tn 2>/dev/null | grep -c "CLOSE-WAIT")
    TIME_WAIT=$(ss -tn 2>/dev/null | grep -c "TIME-WAIT")
    FIN_WAIT=$(ss -tn 2>/dev/null | grep -c "FIN-WAIT")

    info "Conexiones CLOSE-WAIT: $CLOSE_WAIT | TIME-WAIT: $TIME_WAIT | FIN-WAIT: $FIN_WAIT"
    [ "$CLOSE_WAIT" -gt "$UMBRAL_CONN_ERR" ] && warn "Muchas conexiones CLOSE-WAIT ($CLOSE_WAIT) — indica sesiones TCP colgadas con el Server"
    [ "$TIME_WAIT" -gt 100 ] && warn "Muchas conexiones TIME-WAIT ($TIME_WAIT) — alta rotación de conexiones"

    # Puerto 10051 (Zabbix activo)
    CONN_10051=$(ss -tn 2>/dev/null | grep ":$ZBX_PORT" | wc -l)
    info "Conexiones activas al puerto $ZBX_PORT: $CONN_10051"
elif command -v netstat &>/dev/null; then
    netstat -tn 2>/dev/null | grep "$ZBX_SERVER" | head -20
fi

# ── 7. FIREWALL Y REGLAS ──────────────────────────────────────────────────────
section "7. FIREWALL"

if command -v iptables &>/dev/null; then
    # Verificar si hay DROP/REJECT hacia el Server
    DROPS=$(iptables -L OUTPUT -n 2>/dev/null | grep -E "DROP|REJECT" | grep -v "^#" | wc -l)
    [ "$DROPS" -gt 0 ] && warn "Hay reglas DROP/REJECT en OUTPUT — puede bloquear comunicación con el Zabbix Server"
    ok "Reglas iptables verificadas (${DROPS} DROP/REJECT en OUTPUT)"
fi

if command -v firewall-cmd &>/dev/null; then
    if firewall-cmd --state 2>/dev/null | grep -q "running"; then
        info "firewalld activo"
        ZONES=$(firewall-cmd --get-active-zones 2>/dev/null)
        info "Zonas activas: $ZONES"
    fi
fi

# ── 8. ANÁLISIS DE LOGS ───────────────────────────────────────────────────────
section "8. ANÁLISIS DE LOGS DEL PROXY"

if [ -f "$ZBX_LOGFILE" ]; then
    LOG_SIZE=$(du -sh "$ZBX_LOGFILE" 2>/dev/null | cut -f1)
    info "Archivo de log: $ZBX_LOGFILE (${LOG_SIZE})"

    # Últimas líneas del log
    echo ""
    echo -e "  ${BOLD}--- Últimas 20 líneas del log ---${NC}"
    tail -20 "$ZBX_LOGFILE" 2>/dev/null | while read -r line; do
        if echo "$line" | grep -qiE "error|failed|cannot|refused|timeout|critical"; then
            echo -e "  ${RED}$line${NC}"
        elif echo "$line" | grep -qiE "warn|slow|high"; then
            echo -e "  ${YELLOW}$line${NC}"
        else
            echo "  $line"
        fi
        echo "  $line" >> "$REPORTE"
    done

    echo ""
    echo -e "  ${BOLD}--- Resumen de errores (últimas 2000 líneas) ---${NC}"

    # Contar tipos de errores
    LOG_SAMPLE=$(tail -2000 "$ZBX_LOGFILE" 2>/dev/null)

    COUNT_TIMEOUT=$(echo "$LOG_SAMPLE" | grep -ci "timeout")
    COUNT_CONN=$(echo "$LOG_SAMPLE" | grep -ci "connection refused\|connection reset\|cannot connect")
    COUNT_DB=$(echo "$LOG_SAMPLE" | grep -ci "database\|db error\|query failed\|deadlock")
    COUNT_MEM=$(echo "$LOG_SAMPLE" | grep -ci "out of memory\|cannot allocate\|malloc")
    COUNT_NODATA=$(echo "$LOG_SAMPLE" | grep -ci "no data\|item is not supported")
    COUNT_AGENT=$(echo "$LOG_SAMPLE" | grep -ci "get value from agent\|ZBX_TCP_WRITE\|connection timed out")
    COUNT_DNS=$(echo "$LOG_SAMPLE" | grep -ci "cannot resolve\|host not found\|DNS")
    COUNT_TLS=$(echo "$LOG_SAMPLE" | grep -ci "SSL\|TLS\|PSK\|certificate")

    echo ""
    printf "  %-35s %s\n" "Tipo de error" "Ocurrencias (últimas 2000 líneas)"
    echo "  $SEP"
    printf "  %-35s %s\n" "Timeouts de checks"         "$COUNT_TIMEOUT"
    printf "  %-35s %s\n" "Errores de conexión"        "$COUNT_CONN"
    printf "  %-35s %s\n" "Errores de base de datos"   "$COUNT_DB"
    printf "  %-35s %s\n" "Errores de memoria"         "$COUNT_MEM"
    printf "  %-35s %s\n" "Ítems sin datos/no soportados" "$COUNT_NODATA"
    printf "  %-35s %s\n" "Timeouts a agentes"         "$COUNT_AGENT"
    printf "  %-35s %s\n" "Errores DNS"                "$COUNT_DNS"
    printf "  %-35s %s\n" "Errores SSL/TLS/PSK"        "$COUNT_TLS"
    echo ""

    [ "$COUNT_TIMEOUT" -gt 50 ]  && crit "Muchos timeouts en logs ($COUNT_TIMEOUT) — red lenta o agentes no responden"
    [ "$COUNT_CONN" -gt 20 ]     && crit "Errores de conexión frecuentes ($COUNT_CONN) — problema de red o servidor destino caído"
    [ "$COUNT_DB" -gt 10 ]       && crit "Errores de BD ($COUNT_DB) — la BD del proxy está fallando, datos se perderán"
    [ "$COUNT_MEM" -gt 0 ]       && crit "Errores de memoria detectados ($COUNT_MEM) — el proxy puede reiniciarse"
    [ "$COUNT_DNS" -gt 20 ]      && warn "Problemas de resolución DNS ($COUNT_DNS) — hosts monitoreados no resuelven"
    [ "$COUNT_TLS" -gt 10 ]      && warn "Errores TLS/PSK ($COUNT_TLS) — problema de cifrado con el server o agentes"

    # Buscar texto de desconexión del Server
    LAST_DISCONNECT=$(echo "$LOG_SAMPLE" | grep -i "disconnect\|lost connection\|server unavailable" | tail -5)
    if [ -n "$LAST_DISCONNECT" ]; then
        warn "Desconexiones del Server detectadas en logs:"
        echo "$LAST_DISCONNECT" | while read -r line; do echo "    $line"; done
    fi

    # Mostrar errores únicos recientes
    echo ""
    echo -e "  ${BOLD}--- Tipos de errores únicos recientes ---${NC}"
    tail -1000 "$ZBX_LOGFILE" 2>/dev/null | grep -iE "error|failed|cannot" | grep -oP '(?<=: ).*' | sort | uniq -c | sort -rn | head -15 | while read -r cnt msg; do
        printf "  %-5s %s\n" "$cnt" "$msg"
    done
else
    warn "Log no encontrado en $ZBX_LOGFILE"
    # Buscar alternativas
    FOUND_LOG=$(find /var/log /tmp -name "*zabbix*proxy*" 2>/dev/null | head -3)
    [ -n "$FOUND_LOG" ] && info "Logs alternativos encontrados: $FOUND_LOG"
fi

# ── 9. COLA Y BUFFER DEL PROXY ────────────────────────────────────────────────
section "9. COLA Y BUFFER DEL PROXY (proxy_history)"

# Verificar tabla proxy_history en la BD
case "$DB_TYPE" in
    mysql)
        QUEUE_COUNT=$(mysql -u"${ZBX_DBUSER:-zabbix}" -e "SELECT COUNT(*) FROM ${ZBX_DBNAME:-zabbix_proxy}.proxy_history" 2>/dev/null | tail -1)
        if [ -n "$QUEUE_COUNT" ]; then
            info "Registros en proxy_history (pendientes de enviar): $QUEUE_COUNT"
            if [ "$QUEUE_COUNT" -gt 100000 ] 2>/dev/null; then
                crit "Cola CRÍTICA: $QUEUE_COUNT registros — el proxy está acumulando datos sin enviar al Server"
            elif [ "$QUEUE_COUNT" -gt 10000 ] 2>/dev/null; then
                warn "Cola alta: $QUEUE_COUNT registros — el proxy tiene retraso en el envío"
            else
                ok "Cola normal: $QUEUE_COUNT registros"
            fi

            # Verificar el dato más antiguo en la cola
            OLDEST=$(mysql -u"${ZBX_DBUSER:-zabbix}" -e "SELECT FROM_UNIXTIME(MIN(clock)) FROM ${ZBX_DBNAME:-zabbix_proxy}.proxy_history" 2>/dev/null | tail -1)
            [ -n "$OLDEST" ] && [ "$OLDEST" != "NULL" ] && info "Dato más antiguo en cola: $OLDEST"
        fi
        ;;
    sqlite)
        SQLITE_DB=$(find /var/lib/zabbix -name "*.db" 2>/dev/null | head -1)
        if [ -n "$SQLITE_DB" ] && command -v sqlite3 &>/dev/null; then
            QUEUE_COUNT=$(sqlite3 "$SQLITE_DB" "SELECT COUNT(*) FROM proxy_history" 2>/dev/null)
            [ -n "$QUEUE_COUNT" ] && info "Registros en proxy_history: $QUEUE_COUNT"
        fi
        ;;
esac

# ── 10. DNS Y RESOLUCIÓN DE NOMBRES ──────────────────────────────────────────
section "10. RESOLUCIÓN DNS"

# Verificar DNS del Server
if [ -n "$ZBX_SERVER" ]; then
    DNS_RESULT=$(dig +short "$ZBX_SERVER" 2>/dev/null || nslookup "$ZBX_SERVER" 2>/dev/null | grep "Address" | tail -1)
    if echo "$ZBX_SERVER" | grep -qP '^\d+\.\d+\.\d+\.\d+$'; then
        info "Server configurado como IP — sin resolución DNS necesaria"
    elif [ -n "$DNS_RESULT" ]; then
        ok "DNS resuelve '$ZBX_SERVER' → $DNS_RESULT"
    else
        crit "No se puede resolver '$ZBX_SERVER' — el proxy no encontrará el Server"
    fi
fi

# DNS servers configurados
info "Servidores DNS configurados:"
cat /etc/resolv.conf 2>/dev/null | grep "^nameserver" | while read -r ns; do echo "    $ns"; done

# Tiempo de resolución DNS
DNS_START=$(date +%s%3N)
dig +short google.com &>/dev/null
DNS_END=$(date +%s%3N)
DNS_MS=$(( DNS_END - DNS_START ))
info "Tiempo de resolución DNS (google.com): ${DNS_MS}ms"
[ "$DNS_MS" -gt 500 ] && warn "DNS lento (${DNS_MS}ms) — la resolución de nombres de hosts monitoreados puede causar timeouts"

# ── 11. NTP / SINCRONIZACIÓN DE TIEMPO ───────────────────────────────────────
section "11. SINCRONIZACIÓN DE TIEMPO (NTP)"

if command -v chronyc &>/dev/null; then
    CHRONY_OFFSET=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4, $5}')
    info "Offset chrony: $CHRONY_OFFSET"
    CHRONY_OFFSET_S=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}')
    CHRONY_OFFSET_ABS=$(echo "$CHRONY_OFFSET_S" | awk '{if($1<0) print -$1; else print $1}')
    if awk "BEGIN {exit !($CHRONY_OFFSET_ABS > 1.0)}" 2>/dev/null; then
        crit "Desfase de tiempo > 1 segundo ($CHRONY_OFFSET_S s) — Zabbix rechazará datos con timestamps incorrectos"
    else
        ok "Tiempo sincronizado (offset: $CHRONY_OFFSET_S s)"
    fi
elif command -v timedatectl &>/dev/null; then
    timedatectl status 2>/dev/null | grep -E "synchronized|NTP|Local time"
    NTP_SYNC=$(timedatectl status 2>/dev/null | grep "synchronized" | grep -c "yes")
    [ "$NTP_SYNC" -eq 0 ] && warn "NTP NO sincronizado — puede causar problemas de timestamps en datos del proxy"
else
    warn "chronyc/timedatectl no disponibles — verificar NTP manualmente"
fi

# ── 12. LÍMITES DEL SISTEMA (ulimits) ────────────────────────────────────────
section "12. LÍMITES DEL SISTEMA (ulimits)"

if [ -n "$ZBX_PID" ]; then
    FD_OPEN=$(ls /proc/$ZBX_PID/fd 2>/dev/null | wc -l)
    FD_LIMIT=$(cat /proc/$ZBX_PID/limits 2>/dev/null | grep "open files" | awk '{print $4}')
    info "File descriptors abiertos por proxy: $FD_OPEN / ${FD_LIMIT:-?}"
    FD_PCT=$(awk "BEGIN {if(${FD_LIMIT:-0}>0) printf \"%.0f\", ${FD_OPEN}*100/${FD_LIMIT:-1}; else print 0}")
    [ "$FD_PCT" -gt 80 ] 2>/dev/null && crit "File descriptors al ${FD_PCT}% — el proxy puede fallar al abrir nuevas conexiones"
    [ "$FD_PCT" -gt 60 ] 2>/dev/null && warn "File descriptors al ${FD_PCT}%"
fi

# Límites globales del sistema
ULIMIT_N=$(ulimit -n 2>/dev/null)
info "Límite global de file descriptors: $ULIMIT_N"
[ "${ULIMIT_N:-0}" -lt 65535 ] 2>/dev/null && warn "Límite de file descriptors bajo ($ULIMIT_N) — aumentar en /etc/security/limits.conf"

# ── 13. VERIFICACIÓN DE AGENTES ───────────────────────────────────────────────
section "13. VERIFICACIÓN DE AGENTES MONITOREADOS"

info "Verificando conectividad a agentes (prueba TCP puerto 10050)..."

# Obtener lista de agentes desde la BD si es posible
AGENTS=()
case "$DB_TYPE" in
    mysql)
        AGENT_LIST=$(mysql -u"${ZBX_DBUSER:-zabbix}" -e "
            SELECT DISTINCT ip FROM ${ZBX_DBNAME:-zabbix_proxy}.interface
            WHERE type=1 AND ip NOT IN ('','127.0.0.1') LIMIT 20
        " 2>/dev/null | tail -n +2)
        while IFS= read -r agent; do
            [ -n "$agent" ] && AGENTS+=("$agent")
        done <<< "$AGENT_LIST"
        ;;
esac

if [ "${#AGENTS[@]}" -eq 0 ]; then
    info "No se pudo obtener lista de agentes desde la BD (se necesitan credenciales)"
    info "Para revisar manualmente: zabbix_get -s <IP_AGENTE> -k agent.ping"
else
    info "Probando ${#AGENTS[@]} agentes..."
    AGENT_OK=0; AGENT_FAIL=0
    for AGENT_IP in "${AGENTS[@]}"; do
        if command -v nc &>/dev/null; then
            if nc -z -w 3 "$AGENT_IP" 10050 2>/dev/null; then
                (( AGENT_OK++ ))
            else
                (( AGENT_FAIL++ ))
                warn "Agente NO alcanzable: $AGENT_IP:10050"
            fi
        fi
    done
    info "Agentes OK: $AGENT_OK | Agentes fallando: $AGENT_FAIL"
    [ "$AGENT_FAIL" -gt 0 ] && warn "$AGENT_FAIL agente(s) no responden — generarán timeouts y datos faltantes"
fi

# ── 14. VERIFICACIÓN PSK/TLS ──────────────────────────────────────────────────
section "14. CIFRADO (TLS/PSK)"

TLS_CONNECT=$(get_conf "TLSConnect")
TLS_ACCEPT=$(get_conf "TLSAccept")
PSK_FILE=$(get_conf "TLSPSKFile")

info "TLSConnect: ${TLS_CONNECT:-unencrypted} | TLSAccept: ${TLS_ACCEPT:-unencrypted}"

if [ -n "$PSK_FILE" ]; then
    info "PSK configurado: $PSK_FILE"
    if [ -f "$PSK_FILE" ]; then
        ok "Archivo PSK existe"
        PSK_PERMS=$(stat -c "%a" "$PSK_FILE" 2>/dev/null)
        [ "$PSK_PERMS" != "600" ] && warn "Permisos del PSK: $PSK_PERMS (deberían ser 600)"
    else
        crit "Archivo PSK NO encontrado: $PSK_FILE — el proxy no puede autenticarse con el Server"
    fi
fi

# ── 15. JOURNAL / DMESG ───────────────────────────────────────────────────────
section "15. EVENTOS DEL SISTEMA (últimas 24h)"

# OOM killer
OOM_EVENTS=$(dmesg --since "24 hours ago" 2>/dev/null | grep -i "oom\|killed process" | grep -i zabbix)
if [ -n "$OOM_EVENTS" ]; then
    crit "OOM Killer terminó procesos zabbix en las últimas 24h:"
    echo "$OOM_EVENTS" | while read -r line; do echo "    $line"; done
else
    ok "Sin eventos OOM para zabbix en las últimas 24h"
fi

# Errores de kernel relevantes
KERNEL_ERRS=$(dmesg --since "24 hours ago" 2>/dev/null | grep -iE "error|panic|fault" | grep -v "^audit" | tail -10)
[ -n "$KERNEL_ERRS" ] && { warn "Errores de kernel recientes:"; echo "$KERNEL_ERRS" | head -10 | while read -r l; do echo "    $l"; done; }

# Journal del servicio
if command -v journalctl &>/dev/null; then
    echo ""
    echo -e "  ${BOLD}--- Journal zabbix-proxy (últimas 50 líneas con errores) ---${NC}"
    journalctl -u zabbix-proxy --since "24 hours ago" --no-pager 2>/dev/null | grep -iE "error|failed|warn|start|stop" | tail -30 | while read -r line; do
        echo "  $line"
        echo "  $line" >> "$REPORTE"
    done
fi

# ── RESUMEN FINAL ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}${SEP}${NC}"
echo -e "${BOLD}${CYAN}  RESUMEN DE DIAGNÓSTICO — $(date '+%H:%M:%S')${NC}"
echo -e "${BOLD}${CYAN}${SEP}${NC}"
echo ""

{
echo ""
echo "============================================================"
echo "  RESUMEN FINAL"
echo "============================================================"
} >> "$REPORTE"

if [ "${#PROBLEMAS[@]}" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}✅ No se detectaron problemas críticos ni advertencias.${NC}"
    echo "  El proxy Zabbix parece estar funcionando correctamente."
    echo "  ✅ Sin problemas detectados." >> "$REPORTE"
else
    echo -e "  ${BOLD}Se encontraron ${#PROBLEMAS[@]} problema(s):${NC}"
    echo ""
    for p in "${PROBLEMAS[@]}"; do
        echo -e "  $p"
        echo "  $p" >> "$REPORTE"
    done

    echo ""
    echo -e "  ${BOLD}${CYAN}━━━ POSIBLES CAUSAS DE CAÍDAS O LENTITUD ━━━${NC}"
    echo ""

    # Análisis automático de causas
    for p in "${PROBLEMAS[@]}"; do
        case "$p" in
            *"iowait"*)         echo -e "  ${YELLOW}→${NC} Disco lento → BD del proxy tarda en escribir → acumulación de datos → lentitud general" ;;
            *"timeout"*)        echo -e "  ${YELLOW}→${NC} Timeouts altos → pollers esperan respuesta de agentes → cola crece → proxy reporta retraso" ;;
            *"proxy_history"*)  echo -e "  ${YELLOW}→${NC} Buffer lleno → el proxy no puede enviar datos → el Server marca al proxy como no disponible" ;;
            *"OOM"*)            echo -e "  ${YELLOW}→${NC} OOM killer → proceso zabbix eliminado → caída del servicio" ;;
            *"TCP"*|*"accesible"*) echo -e "  ${YELLOW}→${NC} Red bloqueada → proxy sin comunicación con Server → datos perdidos" ;;
            *"MySQL"*|*"BD"*)   echo -e "  ${YELLOW}→${NC} BD inaccesible → proxy no puede leer configuración ni guardar datos → caída" ;;
            *"PSK"*|*"TLS"*)    echo -e "  ${YELLOW}→${NC} Error de cifrado → Server rechaza la conexión del proxy" ;;
            *"NTP"*|*"tiempo"*) echo -e "  ${YELLOW}→${NC} Tiempo desincronizado → Server descarta datos por timestamp inválido" ;;
            *"swap"*)           echo -e "  ${YELLOW}→${NC} Swap activo → accesos a disco como RAM → latencias altas → proxy extremadamente lento" ;;
            *"DNS"*)            echo -e "  ${YELLOW}→${NC} DNS lento → checks contra nombres de host tardan → timeouts masivos" ;;
        esac
    done
fi

echo ""
echo -e "  ${BOLD}Reporte guardado en:${NC} $REPORTE"
echo -e "  ${BOLD}Log del proxy:${NC}       $ZBX_LOGFILE"
echo ""
echo -e "  ${BOLD}${CYAN}Comandos útiles para seguimiento:${NC}"
echo "    tail -f $ZBX_LOGFILE"
echo "    watch -n 2 'ss -tn dst $ZBX_SERVER'"
echo "    watch -n 5 'pgrep -c zabbix_proxy'"
[ "$DB_TYPE" = "mysql" ] && echo "    mysql -u zabbix -e 'SELECT COUNT(*) FROM ${ZBX_DBNAME:-zabbix_proxy}.proxy_history'"
echo ""
