#!/bin/bash
set -e

echo "🚀 Actualizando EarendelX a la última versión..."
killall EarendelX 2>/dev/null || true
rm -rf /Applications/EarendelX.app /tmp/EarendelX.zip

curl -fSL "https://github.com/Diegomm991/earendel-connector/releases/download/v1.0.11/EarendelX-macOS.zip" -o /tmp/EarendelX.zip

ditto -x -k /tmp/EarendelX.zip /Applications
xattr -cr /Applications/EarendelX.app
rm -f /tmp/EarendelX.zip

echo "✅ ¡EarendelX actualizado con éxito! Abriendo aplicación..."
open /Applications/EarendelX.app
