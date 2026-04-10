#!/bin/bash

# Colores para la salida
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' 

echo -e "${GREEN}Iniciando instalador de StorCLI para Ubuntu 22.04...${NC}"

# 1. Verificar privilegios de root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Error: Debes ejecutar este script con sudo.${NC}"
  exit 1
fi

# 2. Instalar dependencias
apt update && apt install unzip wget -y

# 3. Nueva URL funcional (Versión 007.2705)
URL="https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip"
TMP_DIR="/tmp/storcli_install"

# Limpiar carpeta temporal
rm -rf $TMP_DIR
mkdir -p $TMP_DIR
cd $TMP_DIR

# 4. Descarga con validación
echo -e "Descargando paquete desde Broadcom..."
wget --no-check-certificate $URL -O storcli.zip

if [ $? -ne 0 ]; then
    echo -e "${RED}Error: El enlace ha vuelto a cambiar. Broadcom bloquea descargas directas a veces.${NC}"
    echo -e "Intenta descargar el archivo manualmente desde broadcom.com y ponlo en esta carpeta.${NC}"
    exit 1
fi

# 5. Descomprimir e instalar
echo -e "Descomprimiendo archivos..."
unzip -q storcli.zip

# Buscar el archivo .deb dentro de la estructura (normalmente en Unified_storcli_all_os/Ubuntu)
DEB_FILE=$(find . -name "storcli_*_all.deb" | head -n 1)

if [ -z "$DEB_FILE" ]; then
    # Intento alternativo buscando cualquier .deb si el nombre cambió
    DEB_FILE=$(find . -name "*.deb" | grep -i "storcli" | head -n 1)
fi

if [ -f "$DEB_FILE" ]; then
    echo -e "Instalando: $DEB_FILE"
    dpkg -i "$DEB_FILE"
else
    echo -e "${RED}Error: No se encontró el instalador .deb dentro del ZIP.${NC}"
    exit 1
fi

# 6. Crear enlace simbólico para que el comando 'storcli' funcione globalmente
# Nota: La ruta de instalación por defecto suele ser /opt/MegaRAID/storcli/storcli64
if [ -f "/opt/MegaRAID/storcli/storcli64" ]; then
    ln -sf /opt/MegaRAID/storcli/storcli64 /usr/local/bin/storcli
    echo -e "${GREEN}¡Instalación exitosa!${NC}"
    echo -e "Comando para probar: ${GREEN}sudo storcli show${NC}"
else
    echo -e "${RED}El binario no se encontró en /opt/MegaRAID/. Revisa la instalación.${NC}"
fi

# Limpieza
cd /
rm -rf $TMP_DIR
