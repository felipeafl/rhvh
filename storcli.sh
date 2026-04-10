#!/bin/bash

# Colores para la salida
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' 

echo -e "${GREEN}Iniciando instalador de StorCLI + Herramientas de Diagnóstico...${NC}"

# 1. Verificar privilegios de root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Error: Debes ejecutar este script con sudo.${NC}"
  exit 1
fi

# 2. Instalar dependencias y herramientas solicitadas
echo -e "Instalando smartmontools, jq y dependencias de extracción..."
apt update
apt install -y smartmontools jq unzip wget

# 3. Configuración de rutas y descarga
URL="https://docs.broadcom.com/docs-and-downloads/007.2705.0000.0000_storcli_rel.zip"
TMP_DIR="/tmp/storcli_final"

rm -rf $TMP_DIR && mkdir -p $TMP_DIR
cd $TMP_DIR

echo -e "Descargando paquete de Broadcom..."
wget --no-check-certificate $URL -O master.zip

if [ $? -ne 0 ]; then
    echo -e "${RED}Error en la descarga. Verifica la conexión o el enlace.${NC}"
    exit 1
fi

# 4. Descompresión de los niveles de ZIP (Manejo de zips anidados)
echo -e "Extrayendo archivos..."
unzip -q master.zip
INNER_ZIP=$(find . -name "Unified_storcli_all_os.zip")

if [ ! -z "$INNER_ZIP" ]; then
    unzip -q "$INNER_ZIP"
fi

# 5. Localizar e instalar el .deb de Ubuntu
DEB_FILE=$(find . -path "*/Ubuntu/*" -name "*.deb" | head -n 1)

if [ -f "$DEB_FILE" ]; then
    echo -e "Instalando paquete: $DEB_FILE"
    dpkg -i "$DEB_FILE"
else
    echo -e "${RED}No se encontró el instalador .deb en la ruta esperada.${NC}"
    exit 1
fi

# 6. Crear enlace simbólico global
ln -sf /opt/MegaRAID/storcli/storcli64 /usr/local/bin/storcli

# Limpieza
cd /
rm -rf $TMP_DIR

echo -e "\n${GREEN}==============================================="
echo -e "¡TODO INSTALADO CORRECTAMENTE!"
echo -e "===============================================${NC}"
echo -e "Herramientas disponibles:"
echo -e "- ${GREEN}storcli${NC}   (Gestión RAID)"
echo -e "- ${GREEN}smartctl${NC}  (Diagnóstico de discos)"
echo -e "- ${GREEN}jq${NC}        (Procesador de JSON)"
echo -e "-----------------------------------------------"
echo -e "Prueba rápida: ${GREEN}sudo storcli show${NC}\n"
