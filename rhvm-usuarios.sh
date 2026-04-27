#!/bin/bash
# =============================================================================
#  rhvm-usuarios.sh
#  Gestión de usuarios locales en Red Hat Virtualization Manager (RHVM)
#
#  Versión: 1.0
#  Requiere: ovirt-aaa-jdbc-tool (ejecutar en el servidor RHVM como root)
#
#  Uso:
#    ./rhvm-usuarios.sh --crear                  → Crear usuario (interactivo)
#    ./rhvm-usuarios.sh --crear -u juan -g GRP-RHV-Operators   → Crear sin preguntas
#    ./rhvm-usuarios.sh --listar                 → Listar todos los usuarios
#    ./rhvm-usuarios.sh --ver -u juan            → Ver detalle de un usuario
#    ./rhvm-usuarios.sh --password -u juan       → Cambiar contraseña
#    ./rhvm-usuarios.sh --grupo -u juan          → Cambiar grupo de un usuario
#    ./rhvm-usuarios.sh --deshabilitar -u juan   → Deshabilitar acceso
#    ./rhvm-usuarios.sh --habilitar -u juan      → Rehabilitar acceso
#    ./rhvm-usuarios.sh --borrar -u juan         → Eliminar usuario
# =============================================================================

set -euo pipefail

# ─── Grupos disponibles ────────────────────────────────────────────────────────
GRUPOS_DISPONIBLES=(
    "GRP-RHV-ReadOnly"
    "GRP-RHV-Operators"
    "GRP-RHV-PowerUsers"
)

# Fecha de expiración de contraseña por defecto (sin expiración)
PASS_VALID_TO="2099-12-31 00:00:00Z"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERR]${NC}  $*" >&2; }
section() { echo -e "\n${BOLD}${CYAN}──── $* ────${NC}"; }

# ─── Verificaciones ───────────────────────────────────────────────────────────
verificar_herramienta() {
    if ! command -v ovirt-aaa-jdbc-tool &>/dev/null; then
        err "ovirt-aaa-jdbc-tool no encontrado."
        err "Este script debe ejecutarse en el servidor RHVM como root."
        exit 1
    fi
}

usuario_existe() {
    ovirt-aaa-jdbc-tool user show "$1" &>/dev/null 2>&1
}

grupo_existe() {
    ovirt-aaa-jdbc-tool group show "$1" &>/dev/null 2>&1
}

# ─── Seleccionar grupo (menú interactivo) ──────────────────────────────────────
seleccionar_grupo() {
    echo ""
    echo -e "  ${CYAN}Grupos disponibles:${NC}"
    for i in "${!GRUPOS_DISPONIBLES[@]}"; do
        local GRUPO="${GRUPOS_DISPONIBLES[$i]}"
        local DESC=""
        case "$GRUPO" in
            *ReadOnly*)   DESC="Solo lectura — ver VMs, sin ejecutar acciones" ;;
            *Operators*)  DESC="Encender / Apagar / Reiniciar VMs" ;;
            *PowerUsers*) DESC="Gestión completa + Crear VMs" ;;
        esac
        echo -e "  ${BOLD}$((i+1))${NC}. $GRUPO"
        echo -e "     ${YELLOW}→ $DESC${NC}"
    done
    echo ""
    while true; do
        read -rp "  Selecciona el grupo [1-${#GRUPOS_DISPONIBLES[@]}]: " OPCION
        if [[ "$OPCION" =~ ^[0-9]+$ ]] && \
           (( OPCION >= 1 && OPCION <= ${#GRUPOS_DISPONIBLES[@]} )); then
            GRUPO_SELECCIONADO="${GRUPOS_DISPONIBLES[$((OPCION-1))]}"
            break
        fi
        warn "Opción inválida. Ingresa un número entre 1 y ${#GRUPOS_DISPONIBLES[@]}."
    done
}

# ─── CREAR usuario ─────────────────────────────────────────────────────────────
crear_usuario() {
    local USUARIO="${ARG_USUARIO:-}"
    local GRUPO="${ARG_GRUPO:-}"

    section "Crear nuevo usuario"

    # Pedir nombre si no se pasó como argumento
    if [[ -z "$USUARIO" ]]; then
        read -rp "  Nombre de usuario: " USUARIO
    fi
    USUARIO=$(echo "$USUARIO" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')

    if [[ -z "$USUARIO" ]]; then
        err "El nombre de usuario no puede estar vacío."
        exit 1
    fi

    if usuario_existe "$USUARIO"; then
        warn "El usuario '$USUARIO' ya existe."
        read -rp "  ¿Continuar de todas formas y solo asignar grupo? [s/N]: " RESP
        [[ "$RESP" =~ ^[sS]$ ]] || exit 0
    else
        # Crear usuario
        ovirt-aaa-jdbc-tool user add "$USUARIO"
        log "Usuario '$USUARIO' creado."

        # Asignar contraseña
        echo ""
        echo -e "  ${CYAN}Ingresa la contraseña para '$USUARIO':${NC}"
        while true; do
            read -rsp "  Contraseña: " PASS1; echo ""
            read -rsp "  Confirmar : " PASS2; echo ""
            if [[ "$PASS1" == "$PASS2" ]] && [[ -n "$PASS1" ]]; then
                break
            fi
            warn "Las contraseñas no coinciden o están vacías. Intenta de nuevo."
        done

        echo "$PASS1" | ovirt-aaa-jdbc-tool user password-reset "$USUARIO" \
            --password-valid-to "$PASS_VALID_TO" \
            --password=env:OVIRT_PASS 2>/dev/null || \
        ovirt-aaa-jdbc-tool user password-reset "$USUARIO" \
            --password-valid-to "$PASS_VALID_TO" <<< "$PASS1"

        log "Contraseña asignada."
    fi

    # Seleccionar grupo si no se pasó como argumento
    if [[ -z "$GRUPO" ]]; then
        seleccionar_grupo
        GRUPO="$GRUPO_SELECCIONADO"
    fi

    if ! grupo_existe "$GRUPO"; then
        err "El grupo '$GRUPO' no existe en RHVM."
        err "Grupos disponibles: ${GRUPOS_DISPONIBLES[*]}"
        exit 1
    fi

    ovirt-aaa-jdbc-tool group-manage useradd "$GRUPO" --user="$USUARIO"
    log "Usuario '$USUARIO' agregado al grupo '$GRUPO'."

    echo ""
    echo -e "  ${GREEN}${BOLD}Usuario creado exitosamente:${NC}"
    echo -e "  • Usuario : ${BOLD}$USUARIO${NC}"
    echo -e "  • Grupo   : ${BOLD}$GRUPO${NC}"
    echo -e "  • Acceso  : $(descripcion_grupo "$GRUPO")"
    echo ""
}

descripcion_grupo() {
    case "$1" in
        *ReadOnly*)   echo "Solo lectura" ;;
        *Operators*)  echo "Encender / Apagar / Reiniciar VMs" ;;
        *PowerUsers*) echo "Gestión completa + Crear VMs" ;;
        *)            echo "$1" ;;
    esac
}

# ─── LISTAR usuarios ───────────────────────────────────────────────────────────
listar_usuarios() {
    section "Usuarios registrados en RHVM"

    local USUARIOS
    USUARIOS=$(ovirt-aaa-jdbc-tool user list 2>/dev/null | grep "^Name:" | awk '{print $2}' | sort)

    if [[ -z "$USUARIOS" ]]; then
        warn "No se encontraron usuarios."
        return
    fi

    printf "\n  %-20s %-10s %-30s\n" "USUARIO" "ESTADO" "GRUPOS"
    printf "  %-20s %-10s %-30s\n" "-------" "------" "------"

    while IFS= read -r USR; do
        [[ -z "$USR" ]] && continue

        # Estado (habilitado/deshabilitado)
        local INFO FLAGS ESTADO
        INFO=$(ovirt-aaa-jdbc-tool user show "$USR" 2>/dev/null)
        FLAGS=$(echo "$INFO" | grep "^Flags:" | awk '{print $2}')
        if echo "$FLAGS" | grep -q "disabled"; then
            ESTADO="${RED}INACTIVO${NC}"
        else
            ESTADO="${GREEN}ACTIVO${NC}  "
        fi

        # Grupos del usuario
        local GRUPOS=""
        for GRP in "${GRUPOS_DISPONIBLES[@]}"; do
            if ovirt-aaa-jdbc-tool group show "$GRP" 2>/dev/null | grep -q "^  $USR$\|Member.*$USR\|$USR"; then
                GRUPOS+="$GRP "
            fi
        done
        GRUPOS="${GRUPOS:-sin grupo asignado}"

        printf "  %-20s " "$USR"
        echo -ne "$ESTADO"
        printf " %-30s\n" "$GRUPOS"
    done <<< "$USUARIOS"
    echo ""
}

# ─── VER detalle de usuario ────────────────────────────────────────────────────
ver_usuario() {
    local USUARIO="${ARG_USUARIO:-}"
    [[ -z "$USUARIO" ]] && read -rp "  Nombre de usuario: " USUARIO

    if ! usuario_existe "$USUARIO"; then
        err "Usuario '$USUARIO' no existe."
        exit 1
    fi

    section "Detalle del usuario: $USUARIO"
    ovirt-aaa-jdbc-tool user show "$USUARIO"

    echo ""
    echo -e "  ${CYAN}Grupos asignados:${NC}"
    local EN_ALGUN_GRUPO=false
    for GRP in "${GRUPOS_DISPONIBLES[@]}"; do
        local MIEMBROS
        MIEMBROS=$(ovirt-aaa-jdbc-tool group show "$GRP" 2>/dev/null)
        if echo "$MIEMBROS" | grep -qi "$USUARIO"; then
            echo -e "  • $GRP  →  $(descripcion_grupo "$GRP")"
            EN_ALGUN_GRUPO=true
        fi
    done
    $EN_ALGUN_GRUPO || echo -e "  ${YELLOW}Sin grupo asignado${NC}"
    echo ""
}

# ─── CAMBIAR CONTRASEÑA ────────────────────────────────────────────────────────
cambiar_password() {
    local USUARIO="${ARG_USUARIO:-}"
    [[ -z "$USUARIO" ]] && read -rp "  Nombre de usuario: " USUARIO

    if ! usuario_existe "$USUARIO"; then
        err "Usuario '$USUARIO' no existe."
        exit 1
    fi

    section "Cambiar contraseña: $USUARIO"
    while true; do
        read -rsp "  Nueva contraseña : " PASS1; echo ""
        read -rsp "  Confirmar        : " PASS2; echo ""
        [[ "$PASS1" == "$PASS2" ]] && [[ -n "$PASS1" ]] && break
        warn "Las contraseñas no coinciden o están vacías."
    done

    ovirt-aaa-jdbc-tool user password-reset "$USUARIO" \
        --password-valid-to "$PASS_VALID_TO" <<< "$PASS1"
    log "Contraseña actualizada para '$USUARIO'."
}

# ─── CAMBIAR GRUPO ─────────────────────────────────────────────────────────────
cambiar_grupo() {
    local USUARIO="${ARG_USUARIO:-}"
    [[ -z "$USUARIO" ]] && read -rp "  Nombre de usuario: " USUARIO

    if ! usuario_existe "$USUARIO"; then
        err "Usuario '$USUARIO' no existe."
        exit 1
    fi

    section "Cambiar grupo de: $USUARIO"

    # Quitar de grupos actuales
    echo -e "  ${CYAN}Grupos actuales:${NC}"
    local EN_ALGUN_GRUPO=false
    for GRP in "${GRUPOS_DISPONIBLES[@]}"; do
        if ovirt-aaa-jdbc-tool group show "$GRP" 2>/dev/null | grep -qi "$USUARIO"; then
            echo -e "  • $GRP"
            ovirt-aaa-jdbc-tool group-manage userdel "$GRP" --user="$USUARIO" 2>/dev/null || true
            EN_ALGUN_GRUPO=true
        fi
    done
    $EN_ALGUN_GRUPO || echo -e "  ${YELLOW}(ninguno)${NC}"

    # Seleccionar nuevo grupo
    seleccionar_grupo
    ovirt-aaa-jdbc-tool group-manage useradd "$GRUPO_SELECCIONADO" --user="$USUARIO"
    log "Usuario '$USUARIO' movido al grupo '$GRUPO_SELECCIONADO'."
}

# ─── DESHABILITAR usuario ──────────────────────────────────────────────────────
deshabilitar_usuario() {
    local USUARIO="${ARG_USUARIO:-}"
    [[ -z "$USUARIO" ]] && read -rp "  Nombre de usuario a deshabilitar: " USUARIO

    if ! usuario_existe "$USUARIO"; then
        err "Usuario '$USUARIO' no existe."
        exit 1
    fi

    ovirt-aaa-jdbc-tool user edit "$USUARIO" --flag=+disabled
    log "Usuario '$USUARIO' deshabilitado. No podrá iniciar sesión."
}

# ─── HABILITAR usuario ─────────────────────────────────────────────────────────
habilitar_usuario() {
    local USUARIO="${ARG_USUARIO:-}"
    [[ -z "$USUARIO" ]] && read -rp "  Nombre de usuario a habilitar: " USUARIO

    if ! usuario_existe "$USUARIO"; then
        err "Usuario '$USUARIO' no existe."
        exit 1
    fi

    ovirt-aaa-jdbc-tool user edit "$USUARIO" --flag=-disabled
    log "Usuario '$USUARIO' habilitado."
}

# ─── BORRAR usuario ────────────────────────────────────────────────────────────
borrar_usuario() {
    local USUARIO="${ARG_USUARIO:-}"
    [[ -z "$USUARIO" ]] && read -rp "  Nombre de usuario a eliminar: " USUARIO

    if ! usuario_existe "$USUARIO"; then
        err "Usuario '$USUARIO' no existe."
        exit 1
    fi

    echo -e "  ${RED}${BOLD}ADVERTENCIA:${NC} Se eliminará permanentemente el usuario '${BOLD}${USUARIO}${NC}'."
    read -rp "  ¿Confirmar eliminación? [s/N]: " RESP
    [[ "$RESP" =~ ^[sS]$ ]] || { echo "  Operación cancelada."; exit 0; }

    # Remover de todos los grupos primero
    for GRP in "${GRUPOS_DISPONIBLES[@]}"; do
        ovirt-aaa-jdbc-tool group-manage userdel "$GRP" --user="$USUARIO" 2>/dev/null || true
    done

    ovirt-aaa-jdbc-tool user delete "$USUARIO"
    log "Usuario '$USUARIO' eliminado."
}

# ─── AYUDA ────────────────────────────────────────────────────────────────────
mostrar_ayuda() {
    cat <<EOF

  ${BOLD}rhvm-usuarios.sh${NC} — Gestión de usuarios en RHVM (dominio interno)

  ${CYAN}USO:${NC}
    ./rhvm-usuarios.sh OPCIÓN [-u USUARIO] [-g GRUPO]

  ${CYAN}OPCIONES:${NC}
    --crear          Crear un nuevo usuario (modo interactivo)
    --listar         Listar todos los usuarios y sus grupos
    --ver            Ver detalle de un usuario
    --password       Cambiar contraseña de un usuario
    --grupo          Cambiar el grupo de un usuario
    --deshabilitar   Deshabilitar acceso (sin borrar el usuario)
    --habilitar      Rehabilitar un usuario deshabilitado
    --borrar         Eliminar un usuario permanentemente
    --ayuda          Mostrar esta ayuda

  ${CYAN}PARÁMETROS OPCIONALES:${NC}
    -u, --usuario NOMBRE    Especificar usuario sin modo interactivo
    -g, --grupo   NOMBRE    Especificar grupo sin modo interactivo

  ${CYAN}EJEMPLOS:${NC}
    ./rhvm-usuarios.sh --crear
    ./rhvm-usuarios.sh --crear -u jperez -g GRP-RHV-Operators
    ./rhvm-usuarios.sh --listar
    ./rhvm-usuarios.sh --ver -u jperez
    ./rhvm-usuarios.sh --password -u jperez
    ./rhvm-usuarios.sh --grupo -u jperez
    ./rhvm-usuarios.sh --deshabilitar -u jperez
    ./rhvm-usuarios.sh --borrar -u jperez

  ${CYAN}GRUPOS DISPONIBLES:${NC}
    GRP-RHV-ReadOnly    → Solo lectura
    GRP-RHV-Operators   → Encender / Apagar / Reiniciar VMs
    GRP-RHV-PowerUsers  → Gestión completa + Crear VMs

EOF
}

# ─── PARSEAR ARGUMENTOS ────────────────────────────────────────────────────────
ACCION=""
ARG_USUARIO=""
ARG_GRUPO=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --crear)         ACCION="crear" ;;
        --listar)        ACCION="listar" ;;
        --ver)           ACCION="ver" ;;
        --password)      ACCION="password" ;;
        --grupo)         ACCION="grupo" ;;
        --deshabilitar)  ACCION="deshabilitar" ;;
        --habilitar)     ACCION="habilitar" ;;
        --borrar)        ACCION="borrar" ;;
        --ayuda|-h)      ACCION="ayuda" ;;
        -u|--usuario)    shift; ARG_USUARIO="$1" ;;
        -g|--grupo)      shift; ARG_GRUPO="$1" ;;
        *) err "Opción desconocida: $1"; mostrar_ayuda; exit 1 ;;
    esac
    shift
done

# ─── MAIN ─────────────────────────────────────────────────────────────────────
if [[ -z "$ACCION" ]]; then
    mostrar_ayuda
    exit 0
fi

[[ "$ACCION" != "ayuda" ]] && verificar_herramienta

case "$ACCION" in
    crear)        crear_usuario ;;
    listar)       listar_usuarios ;;
    ver)          ver_usuario ;;
    password)     cambiar_password ;;
    grupo)        cambiar_grupo ;;
    deshabilitar) deshabilitar_usuario ;;
    habilitar)    habilitar_usuario ;;
    borrar)       borrar_usuario ;;
    ayuda)        mostrar_ayuda ;;
esac
