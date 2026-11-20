#!/bin/bash
set -e

echo "🚀 [1/4] Descargando última versión de EarendelX..."
killall EarendelX 2>/dev/null || true
rm -f /tmp/EarendelX.zip

# Descargar con barra de progreso y reintentos
curl -# -fSL --retry 3 --retry-delay 2 "https://github.com/Diegomm991/earendel-connector/releases/download/v1.0.14/EarendelX-macOS.zip" -o /tmp/EarendelX.zip

# Validar que el archivo zip existe y no está vacío (mínimo 40MB)
if [ ! -s /tmp/EarendelX.zip ]; then
  echo "❌ Error: No se pudo descargar el archivo de actualización."
  exit 1
fi

ZIP_SIZE=$(stat -f%z /tmp/EarendelX.zip 2>/dev/null || stat -c%s /tmp/EarendelX.zip 2>/dev/null || echo 0)
if [ "$ZIP_SIZE" -lt 40000000 ]; then
  echo "❌ Error: El archivo descargado está incompleto ($ZIP_SIZE bytes)."
  exit 1
fi

echo "📦 [2/4] Descomprimiendo e instalando..."
TARGET_DIR="/Applications"
if [ ! -w "$TARGET_DIR" ] || ([ -e "$TARGET_DIR/EarendelX.app" ] && [ ! -w "$TARGET_DIR/EarendelX.app" ]); then
  TARGET_DIR="$HOME/Applications"
  mkdir -p "$TARGET_DIR"
fi

rm -rf "$TARGET_DIR/EarendelX.app"
ditto -x -k /tmp/EarendelX.zip "$TARGET_DIR"
rm -f /tmp/EarendelX.zip

echo "🛡️ [3/4] Quitando atributos de cuarentena..."
xattr -cr "$TARGET_DIR/EarendelX.app" 2>/dev/null || true

echo "✅ [4/4] ¡EarendelX actualizado con éxito! Abriendo aplicación..."
open "$TARGET_DIR/EarendelX.app"
