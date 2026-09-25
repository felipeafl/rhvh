#!/usr/bin/env bash
#
# upgrade_zabbix_proxy_74.sh — Actualiza un Zabbix proxy 7.x a 7.4 en CentOS Stream 9 / EL9.
#
# Se ejecuta como root EN el proxy. Pasos:
#   1. Verificaciones previas (SO, paquetes, configuración, espacio, acceso al repositorio)
#   2. Respaldo en /root/pre74_proxy_<fecha>/ (configuración, repos, lista de RPM, base SQLite)
#   3. Cambio de repositorio a 7.4 y descarga anticipada de paquetes (el proxy sigue corriendo)
#   4. Parada corta: stop -> dnf upgrade -> start
#   5. Verificación: versión 7.4, servicio activo, sin errores y configuración recibida del servidor
#
# Uso:
#   ./upgrade_zabbix_proxy_74.sh --check            Solo verifica y muestra la transacción dnf (no cambia nada)
#   ./upgrade_zabbix_proxy_74.sh                    Actualiza (pide confirmación)
#   ./upgrade_zabbix_proxy_74.sh --yes              Actualiza sin preguntar (para correr por lotes)
#   ./upgrade_zabbix_proxy_74.sh --with-agent       Actualiza también zabbix-agent / zabbix-agent2 si están instalados
#   ./upgrade_zabbix_proxy_74.sh --rollback DIR     Vuelve a la versión anterior usando el respaldo DIR
#
# Configuración:
#   - Se conserva tal cual: zabbix_proxy.conf (Server, Hostname, ProxyMode, TLS, Start*, buffers, etc.),
#     los archivos de Include=, los PSK/certificados TLS (aunque estén fuera de /etc/zabbix) y los
#     overrides de systemd. El RPM ya los protege (%config(noreplace) -> la plantilla nueva queda como
#     .rpmnew), y además el script compara hash, permisos y dueño antes/después: si algo cambió,
#     restaura el respaldo automáticamente y no arranca el proxy si no logra dejarlo idéntico.
#   - La 7.4 no elimina parámetros respecto de la 7.2 (solo agrega TLSListen, opcional).
#
# Importante:
#   - Con SQLite, el proxy 7.4 borra y recrea su base al arrancar (documentación oficial de Zabbix).
#     Se pierden los datos que tenga en buffer sin enviar. La parada se hace lo más corta posible.
#   - Mientras el proxy siga en 7.2 contra un servidor 7.4 queda "outdated": envía datos pero no recibe
#     cambios de configuración. Al terminar este script debe quedar "current".
#
# Códigos de salida: 0 OK · 1 error en verificaciones previas (sin cambios) · 2 error durante/después
# de la actualización (revisar y, si hace falta, usar --rollback) · 3 cancelado por el usuario.

set -Eeuo pipefail

TARGET_MAJOR="7.4"
RELEASE_RPM_URL="https://repo.zabbix.com/zabbix/${TARGET_MAJOR}/release/centos/9/noarch/zabbix-release-latest-${TARGET_MAJOR}.el9.noarch.rpm"
REPO_CHECK_URL="https://repo.zabbix.com/zabbix/${TARGET_MAJOR}/stable/centos/9/x86_64/"
CONF="/etc/zabbix/zabbix_proxy.conf"
MIN_FREE_MB=1024
WAIT_START_SECS=90       # espera para que el servicio arranque y migre la base
WAIT_CONFIG_SECS=180     # espera para recibir configuración del servidor (modo activo)

MODE="upgrade"
ASSUME_YES=0
WITH_AGENT=0
ROLLBACK_DIR=""

TS="$(date +%Y%m%d_%H%M%S)"
RUN_LOG="/var/log/zabbix_proxy_upgrade_${TS}.log"

# ---------------------------------------------------------------------------- utilidades

log()  { printf '%s [INFO]  %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUN_LOG"; }
warn() { printf '%s [WARN]  %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUN_LOG" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" | tee -a "$RUN_LOG" >&2; }
die_pre()  { err "$*"; err "No se hizo ningún cambio en el sistema."; exit 1; }
die_post() { err "$*"; err "Revisar el log: $RUN_LOG"; [[ -n "${BACKUP_DIR:-}" ]] && err "Rollback: $0 --rollback $BACKUP_DIR"; exit 2; }

usage() { sed -n '2,/^set -E/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0; }

include_files() {  # archivos referenciados por Include= (admite directorios y comodines)
    local inc f
    while read -r inc; do
        [[ -z "$inc" ]] && continue
        [[ -d "$inc" ]] && inc="${inc%/}/*"
        # shellcheck disable=SC2086  # expansión de comodines intencional
        for f in $inc; do [[ -f "$f" ]] && echo "$f"; done
    done < <(grep -E '^[[:space:]]*Include[[:space:]]*=' "$CONF" 2>/dev/null | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
}

effective_conf() {  # configuración efectiva: archivo principal + incluidos, sin comentarios ni líneas vacías
    local files
    mapfile -t files < <(include_files)
    cat "$CONF" "${files[@]}" 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' || true
}

conf_get() {  # conf_get Clave [valor_por_defecto] — último valor efectivo (incluye archivos de Include=)
    local v
    v="$(effective_conf | grep -E "^[[:space:]]*$1[[:space:]]*=" | tail -1 | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || true
    printf '%s' "${v:-${2:-}}"
}

config_files() {  # todo lo que define el comportamiento del proxy y debe quedar intacto
    local k f
    echo "$CONF"
    include_files
    for k in TLSPSKFile TLSCAFile TLSCRLFile TLSCertFile TLSKeyFile; do
        f="$(conf_get "$k")"; [[ -n "$f" && -f "$f" ]] && echo "$f"
    done
    for f in /etc/systemd/system/zabbix-proxy.service.d/*.conf /etc/sysconfig/zabbix-proxy; do
        [[ -f "$f" ]] && echo "$f"
    done
    return 0
}

config_snapshot() {  # config_snapshot <archivo_salida> — hash + permisos + dueño de cada archivo de configuración
    local f
    while read -r f; do
        printf '%s %s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$(stat -c '%a %U:%G' "$f")" "$f"
    done < <(config_files | sort -u) > "$1"
}

proxy_version() { zabbix_proxy -V 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "desconocida"; }

confirm() {
    (( ASSUME_YES )) && return 0
    read -r -p "$1 [si/NO]: " ans
    [[ "${ans,,}" == "si" || "${ans,,}" == "s" || "${ans,,}" == "yes" || "${ans,,}" == "y" ]] || { warn "Cancelado por el usuario."; exit 3; }
}

# Líneas del log del proxy escritas desde la marca $1 (número de línea) — soporta LogType=file y system
proxy_log_since() {
    if [[ "$LOG_TYPE" == "file" && -f "$LOG_FILE" ]]; then
        tail -n +"$(( $1 + 1 ))" "$LOG_FILE"
    else
        journalctl -u zabbix-proxy --since "@$START_EPOCH" --no-pager 2>/dev/null
    fi
}
proxy_log_mark() { if [[ "$LOG_TYPE" == "file" && -f "$LOG_FILE" ]]; then wc -l < "$LOG_FILE"; else echo 0; fi; }

# ---------------------------------------------------------------------------- argumentos

while (( $# )); do
    case "$1" in
        --check)      MODE="check" ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --with-agent) WITH_AGENT=1 ;;
        --rollback)   MODE="rollback"; ROLLBACK_DIR="${2:-}"; shift ;;
        -h|--help)    usage ;;
        *) echo "Opción desconocida: $1" >&2; exit 1 ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] || { echo "Debe ejecutarse como root." >&2; exit 1; }
touch "$RUN_LOG"; chmod 600 "$RUN_LOG"

# ---------------------------------------------------------------------------- rollback

if [[ "$MODE" == "rollback" ]]; then
    [[ -d "$ROLLBACK_DIR" && -f "$ROLLBACK_DIR/rpms.before" ]] || die_pre "Directorio de respaldo inválido: '$ROLLBACK_DIR'"
    PREV_RELEASE="$(grep -E '^zabbix-release-' "$ROLLBACK_DIR/rpms.before" | head -1 | sed -E 's/^zabbix-release-([0-9]+\.[0-9]+).*/\1/')"
    [[ -n "$PREV_RELEASE" ]] || die_pre "No se encontró zabbix-release en $ROLLBACK_DIR/rpms.before"
    log "ROLLBACK a la versión $PREV_RELEASE usando $ROLLBACK_DIR"
    confirm "Se detendrá zabbix-proxy y se volverá a $PREV_RELEASE. ¿Continuar?"

    mapfile -t PKGS < <(grep -E '^zabbix-' "$ROLLBACK_DIR/rpms.before" | grep -v '^zabbix-release-' | sed -E 's/\.(x86_64|noarch)$//')
    systemctl stop zabbix-proxy || true
    rpm -Uvh --oldpackage "https://repo.zabbix.com/zabbix/${PREV_RELEASE}/release/centos/9/noarch/zabbix-release-latest-${PREV_RELEASE}.el9.noarch.rpm" 2>&1 | tee -a "$RUN_LOG" \
        || rpm -Uvh --oldpackage "https://repo.zabbix.com/zabbix/${PREV_RELEASE}/release/centos/9/noarch/zabbix-release-${PREV_RELEASE}-1.el9.noarch.rpm" 2>&1 | tee -a "$RUN_LOG"
    dnf clean all -q
    dnf -y downgrade "${PKGS[@]}" 2>&1 | tee -a "$RUN_LOG" || die_post "Falló dnf downgrade."

    log "Restaurando configuración de /etc/zabbix"
    tar xzpf "$ROLLBACK_DIR/etc_zabbix.tgz" -C / 2>&1 | tee -a "$RUN_LOG"
    if [[ -f "$ROLLBACK_DIR/config_files.tgz" ]]; then
        log "Restaurando archivos de configuración fuera de /etc/zabbix (PSK, certificados, overrides)"
        tar xzpf "$ROLLBACK_DIR/config_files.tgz" -C / 2>&1 | tee -a "$RUN_LOG"
    fi

    DB_NAME="$(conf_get DBName)"
    if [[ -f "$ROLLBACK_DIR/sqlite.db" && "$DB_NAME" == /* ]]; then
        log "Restaurando base SQLite $DB_NAME"
        cp -a "$ROLLBACK_DIR/sqlite.db" "$DB_NAME"
    fi
    systemctl start zabbix-proxy
    sleep 5
    systemctl is-active --quiet zabbix-proxy || die_post "zabbix-proxy no arrancó después del rollback."
    log "Rollback terminado. Versión actual: $(proxy_version)"
    exit 0
fi

# ---------------------------------------------------------------------------- 1. verificaciones previas

log "=== Zabbix proxy -> ${TARGET_MAJOR} | host $(hostname) | modo ${MODE} | log $RUN_LOG"

. /etc/os-release
[[ "${ID:-}" =~ ^(centos|rhel|rocky|almalinux|ol)$ && "${VERSION_ID%%.*}" == "9" ]] \
    || die_pre "SO no soportado por este script: ${PRETTY_NAME:-desconocido} (se espera EL9)."
log "SO: $PRETTY_NAME"

mapfile -t PROXY_PKGS < <(rpm -qa --qf '%{NAME}\n' 'zabbix-proxy-*' | sort -u)
(( ${#PROXY_PKGS[@]} )) || die_pre "No hay paquetes zabbix-proxy-* instalados (¿proxy en Docker o compilado?)."
DB_FLAVOR="$(printf '%s\n' "${PROXY_PKGS[@]}" | grep -oE 'sqlite3|mysql|pgsql' | head -1 || true)"
log "Paquetes del proxy: ${PROXY_PKGS[*]} (base: ${DB_FLAVOR:-desconocida})"

CURRENT="$(proxy_version)"
log "Versión actual: $CURRENT"
if [[ "$CURRENT" == ${TARGET_MAJOR}.* ]]; then
    log "El proxy ya está en ${TARGET_MAJOR}. Nada que hacer."
    exit 0
fi
[[ "$CURRENT" =~ ^(7\.[02]|6\.[024])\. ]] || warn "Versión de origen $CURRENT poco habitual; revisar notas de upgrade antes de seguir."

[[ -f "$CONF" ]] || die_pre "No existe $CONF"
PROXY_HOSTNAME="$(conf_get Hostname "$(hostname)")"
PROXY_MODE="$(conf_get ProxyMode 0)"
SERVER="$(conf_get Server)"
DB_NAME="$(conf_get DBName)"
LOG_TYPE="$(conf_get LogType file)"
LOG_FILE="$(conf_get LogFile /var/log/zabbix/zabbix_proxy.log)"
log "Hostname=$PROXY_HOSTNAME | ProxyMode=$PROXY_MODE ($([[ $PROXY_MODE == 0 ]] && echo activo || echo pasivo)) | Server=$SERVER | DBName=$DB_NAME"
log "ProxyOfflineBuffer=$(conf_get ProxyOfflineBuffer '1 (por defecto)') h | ProxyBufferMode=$(conf_get ProxyBufferMode 'disk (por defecto)')"
log "TLSConnect=$(conf_get TLSConnect unencrypted) | TLSAccept=$(conf_get TLSAccept unencrypted) | TLSPSKIdentity=$(conf_get TLSPSKIdentity '-')"

[[ -n "$SERVER" ]] || die_pre "Server= está vacío en la configuración: el proxy no sabría a qué servidor conectarse."
mapfile -t CFG_FILES < <(config_files | sort -u)
log "Configuración que se preserva (${#CFG_FILES[@]} archivos): ${CFG_FILES[*]}"
for k in TLSPSKFile TLSCAFile TLSCRLFile TLSCertFile TLSKeyFile; do
    f="$(conf_get "$k")"
    [[ -z "$f" ]] && continue
    [[ -f "$f" ]] || die_pre "$k=$f no existe: el proxy no podría conectarse cifrado. Corregir antes de actualizar."
    runuser -u zabbix -- test -r "$f" 2>/dev/null || warn "$k=$f no es legible por el usuario zabbix (revisar permisos)."
done

if [[ -n "$(conf_get DBPort)" && -n "$(conf_get DBSocket)" ]]; then
    die_pre "DBPort y DBSocket están definidos a la vez: en 7.4 son excluyentes. Dejar solo uno antes de actualizar."
fi

systemctl is-active --quiet zabbix-proxy && log "zabbix-proxy: activo" || warn "zabbix-proxy no está activo antes de actualizar."

for d in / /var; do
    free_mb=$(df -Pm "$d" | awk 'NR==2{print $4}')
    (( free_mb >= MIN_FREE_MB )) || die_pre "Espacio insuficiente en $d: ${free_mb} MB (mínimo ${MIN_FREE_MB} MB)."
done
log "Espacio en disco: OK"

curl -sfI --max-time 20 "$REPO_CHECK_URL" >/dev/null || die_pre "Sin acceso al repositorio $REPO_CHECK_URL"
log "Acceso al repositorio de Zabbix: OK"

# Paquetes a actualizar: los del proxy + utilidades de Zabbix instaladas (+ agentes si se pidió)
UPGRADE_PKGS=("${PROXY_PKGS[@]}")
for p in zabbix-selinux-policy zabbix-get zabbix-sender zabbix-js; do
    rpm -q "$p" >/dev/null 2>&1 && UPGRADE_PKGS+=("$p")
done
if (( WITH_AGENT )); then
    while read -r p; do [[ -n "$p" ]] && UPGRADE_PKGS+=("$p"); done < <(rpm -qa --qf '%{NAME}\n' 'zabbix-agent*' | sort -u)
fi
AGENT_SVCS=()
if (( WITH_AGENT )); then
    for s in zabbix-agent zabbix-agent2; do systemctl list-unit-files "$s.service" >/dev/null 2>&1 && systemctl is-enabled --quiet "$s" 2>/dev/null && AGENT_SVCS+=("$s"); done
fi
log "Paquetes a actualizar: ${UPGRADE_PKGS[*]}"

# ---------------------------------------------------------------------------- modo --check

if [[ "$MODE" == "check" ]]; then
    log "Transacción que se aplicaría (usando un repositorio 7.4 temporal, sin cambiar el sistema):"
    dnf upgrade --assumeno --disablerepo='zabbix*' \
        --repofrompath="zbx74,https://repo.zabbix.com/zabbix/${TARGET_MAJOR}/stable/centos/9/\$basearch/" \
        --setopt=zbx74.gpgcheck=0 "${UPGRADE_PKGS[@]}" 2>&1 | sed -n '/^=====/,$p' | tee -a "$RUN_LOG" || true
    log "Verificación terminada. Sin cambios."
    exit 0
fi

confirm "Se actualizará '$PROXY_HOSTNAME' de $CURRENT a ${TARGET_MAJOR}. ¿Continuar?"

# ---------------------------------------------------------------------------- 2. respaldo (con el proxy corriendo)

BACKUP_DIR="/root/pre74_proxy_${TS}"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
tar czf "$BACKUP_DIR/etc_zabbix.tgz" -C / etc/zabbix 2>>"$RUN_LOG"
printf '%s\n' "${CFG_FILES[@]}" | sed 's|^/||' > "$BACKUP_DIR/config_files.list"
tar czpf "$BACKUP_DIR/config_files.tgz" -C / --files-from="$BACKUP_DIR/config_files.list" 2>>"$RUN_LOG" \
    || die_post "No se pudo respaldar la configuración (no se tocó el proxy)."
config_snapshot "$BACKUP_DIR/config.before"
effective_conf > "$BACKUP_DIR/effective.before"
cp -a /etc/yum.repos.d/zabbix*.repo "$BACKUP_DIR/" 2>/dev/null || true
rpm -qa 'zabbix*' | sort > "$BACKUP_DIR/rpms.before"
cp "$0" "$BACKUP_DIR/" 2>/dev/null || true
log "Respaldo en $BACKUP_DIR (/etc/zabbix + ${#CFG_FILES[@]} archivos de configuración con su huella)"

# ---------------------------------------------------------------------------- 3. repositorio y descarga anticipada

log "Cambiando repositorio a ${TARGET_MAJOR}"
rpm -Uvh "$RELEASE_RPM_URL" 2>&1 | tee -a "$RUN_LOG" || rpm -q "zabbix-release" | grep -q "${TARGET_MAJOR}" \
    || die_post "No se pudo instalar zabbix-release ${TARGET_MAJOR} (no se tocó el proxy; el repositorio puede haber quedado a medias)."
dnf clean all -q
log "Descargando paquetes (el proxy sigue funcionando)"
dnf -y --downloadonly upgrade "${UPGRADE_PKGS[@]}" 2>&1 | tail -3 | tee -a "$RUN_LOG" \
    || die_post "Falló la descarga de paquetes. El proxy sigue en $CURRENT y funcionando."

# ---------------------------------------------------------------------------- 4. parada corta y actualización

STOP_EPOCH=$(date +%s)
log "Deteniendo zabbix-proxy ${AGENT_SVCS[*]:-}"
systemctl stop zabbix-proxy "${AGENT_SVCS[@]}"

if [[ "$DB_FLAVOR" == "sqlite3" && "$DB_NAME" == /* && -f "$DB_NAME" ]]; then
    cp -a --sparse=always "$DB_NAME" "$BACKUP_DIR/sqlite.db"
    log "Copia de la base SQLite: $BACKUP_DIR/sqlite.db ($(du -h "$BACKUP_DIR/sqlite.db" | cut -f1)). La 7.4 la recreará vacía al arrancar."
fi

log "Actualizando paquetes"
if ! dnf -y upgrade "${UPGRADE_PKGS[@]}" 2>&1 | tee -a "$RUN_LOG" | grep -E '^(Upgraded|Upgrading|Complete|Error)' ; then
    warn "Revisar la salida de dnf en $RUN_LOG"
fi
rpm -qa 'zabbix*' | sort > "$BACKUP_DIR/rpms.after"
NEW="$(proxy_version)"
[[ "$NEW" == ${TARGET_MAJOR}.* ]] || { systemctl start zabbix-proxy || true; die_post "Tras dnf, la versión es $NEW (se esperaba ${TARGET_MAJOR}.x). Se volvió a arrancar el proxy."; }
log "Binario actualizado: $NEW"

mapfile -t RPMNEW < <(find /etc/zabbix /etc/logrotate.d -name '*.rpmnew' -newer "$BACKUP_DIR/rpms.before" 2>/dev/null)
(( ${#RPMNEW[@]} )) && log "Plantillas nuevas de configuración (no se aplican, la configuración actual se mantiene): ${RPMNEW[*]}"

# La configuración (Server, Hostname, TLS, parámetros, incluidos, PSK/certificados) debe seguir idéntica.
config_snapshot "$BACKUP_DIR/config.after"
if ! diff -q "$BACKUP_DIR/config.before" "$BACKUP_DIR/config.after" >/dev/null; then
    warn "La configuración cambió durante la actualización. Diferencias (hash permisos dueño archivo):"
    diff "$BACKUP_DIR/config.before" "$BACKUP_DIR/config.after" | tee -a "$RUN_LOG" >&2 || true
    warn "Restaurando la configuración original desde el respaldo."
    tar xzpf "$BACKUP_DIR/config_files.tgz" -C / 2>>"$RUN_LOG"
    config_snapshot "$BACKUP_DIR/config.after"
    diff -q "$BACKUP_DIR/config.before" "$BACKUP_DIR/config.after" >/dev/null \
        || die_post "No se pudo restaurar la configuración original. El proxy NO se arrancó."
    log "Configuración original restaurada."
fi
effective_conf > "$BACKUP_DIR/effective.after"
diff -q "$BACKUP_DIR/effective.before" "$BACKUP_DIR/effective.after" >/dev/null \
    || die_post "La configuración efectiva difiere del respaldo (ver $BACKUP_DIR/effective.*). El proxy NO se arrancó."
log "Configuración preservada: ${#CFG_FILES[@]} archivos idénticos (contenido, permisos y dueño). Server=$SERVER Hostname=$PROXY_HOSTNAME"

if zabbix_proxy --help 2>&1 | grep -q -- '--test-config'; then
    zabbix_proxy -T -c "$CONF" >>"$RUN_LOG" 2>&1 && log "Validación de configuración (-T): OK" \
        || { warn "zabbix_proxy -T reporta problemas en la configuración:"; tail -5 "$RUN_LOG" >&2; }
fi

MARK=$(proxy_log_mark)
START_EPOCH=$(date +%s)
log "Arrancando zabbix-proxy ${AGENT_SVCS[*]:-}"
systemctl start zabbix-proxy "${AGENT_SVCS[@]}" || die_post "systemctl start zabbix-proxy falló."
log "Tiempo con el proxy detenido: $(( START_EPOCH - STOP_EPOCH )) s"

# ---------------------------------------------------------------------------- 5. verificación

started=0
for (( i=0; i<WAIT_START_SECS; i+=5 )); do
    sleep 5
    systemctl is-active --quiet zabbix-proxy || die_post "zabbix-proxy se detuvo después de arrancar. Últimas líneas: $(proxy_log_since "$MARK" | tail -5)"
    if proxy_log_since "$MARK" | grep -qE "(proxy #0 started|started \[main process\])"; then started=1; break; fi
done
(( started )) || warn "No se vio 'main process started' en ${WAIT_START_SECS}s (el servicio sigue activo)."
proxy_log_since "$MARK" | grep -E "Starting Zabbix Proxy|database upgrade|creating database|cannot|failed|rror" | grep -vE 'item "|became not supported' | head -20 | tee -a "$RUN_LOG" || true

if proxy_log_since "$MARK" | grep -qiE "database upgrade failed|cannot open database|cannot connect to the database"; then
    die_post "Problema con la base del proxy (ver arriba)."
fi

if [[ "$PROXY_MODE" == "0" ]]; then
    log "Esperando configuración del servidor (hasta ${WAIT_CONFIG_SECS}s). Solo la reciben los proxies 'current'."
    got_conf=0
    for (( i=0; i<WAIT_CONFIG_SECS; i+=5 )); do
        if proxy_log_since "$MARK" | grep -qiE "received configuration data from server|configuration syncer.*synced"; then got_conf=1; break; fi
        if proxy_log_since "$MARK" | grep -qiE "cannot (send|obtain) .*server|connection to server.*(failed|refused)|proxy \"[^\"]+\" not found"; then
            warn "El proxy reporta problemas para hablar con el servidor:"
            proxy_log_since "$MARK" | grep -iE "cannot (send|obtain)|connection to server|not found" | tail -3 | tee -a "$RUN_LOG" >&2
        fi
        sleep 5
    done
    if (( got_conf )); then
        log "Configuración recibida del servidor: el proxy quedó 'current'."
    else
        warn "No se vio la recepción de configuración en ${WAIT_CONFIG_SECS}s. Verificar en el frontend (Administración > Proxies) que figure 7.4 y 'current'."
    fi
else
    log "Proxy pasivo: el servidor lo contactará. Verificar en el frontend que figure 7.4 y 'current'."
fi

log "=== OK: '$PROXY_HOSTNAME' actualizado de $CURRENT a $NEW | respaldo $BACKUP_DIR | log $RUN_LOG"
exit 0
