#!/bin/bash

# Colores para la salida
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Iniciando instalador automático de StorCLI para Ubuntu...${NC}"

# 1. Verificar si se ejecuta como root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}Por favor, ejecuta el script como root (sudo ./nombre_script.sh)${NC}"
  exit
fi

# 2. Instalar dependencias
echo -e "Instalando dependencias necesarias (unzip, wget)..."
apt update && apt install unzip wget -y

# 3. Definir variables (Versión actual a fecha de hoy)
URL="https://docs.broadcom.com/docs-and-downloads/raid-controllers/raid-controllers-common-files/007.2613.0000.0000_Unified_StorCLI.zip"
ZIP_NAME="storcli_package.zip"
TMP_DIR="/tmp/storcli_install"

# 4. Limpieza de instalaciones previas en /tmp
rm -rf $TMP_DIR
mkdir -p $TMP_DIR
cd $TMP_DIR

# 5. Descarga
echo -e "Descargando paquete desde Broadcom..."
wget $URL -O $ZIP_NAME

if [ $? -ne 0 ]; then
    echo -e "${RED}Error al descargar. El enlace podría haber caducado.${NC}"
    exit 1
fi

# 6. Descomprimir
echo -e "Descomprimiendo archivos..."
unzip $ZIP_NAME -d .
# Buscamos la carpeta de Ubuntu dinámicamente
DEB_PATH=$(find . -name "storcli_*.deb" | grep "Ubuntu" | head -n 1)

# 7. Instalación
if [ -f "$DEB_PATH" ]; then
    echo -e "Instalando paquete .deb..."
    dpkg -i "$DEB_PATH"
else
    echo -e "${RED}No se encontró el archivo .deb para Ubuntu en el paquete descargado.${NC}"
    exit 1
fi

# 8. Crear enlace simbólico para uso global
echo -e "Configurando acceso directo en /usr/local/bin/storcli..."
if [ -f "/opt/MegaRAID/storcli/storcli64" ]; then
    ln -sf /opt/MegaRAID/storcli/storcli64 /usr/local/bin/storcli
    echo -e "${GREEN}¡Instalación completada con éxito!${NC}"
    echo -e "Puedes usar el comando: ${GREEN}sudo storcli show${NC}"
else
    echo -e "${RED}La instalación falló o el binario no está en la ruta esperada.${NC}"
fi

# Limpieza final
rm -rf $TMP_DIR
